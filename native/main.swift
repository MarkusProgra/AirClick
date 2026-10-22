// AirClick for macOS — hand-tracking mouse control.
//
// One file, no dependencies beyond the system frameworks:
//   AVCaptureSession (front camera) → Vision hand pose (21 joints) →
//   the same gesture logic as the AirClick web app → CGEvent posts that
//   move the REAL system pointer and send real left/right clicks.
//
// Requires Accessibility (System Settings → Privacy & Security → Accessibility)
// so CGEvents are trusted; the camera prompt appears on first launch.

import AppKit
import AVFoundation
import Vision
import ApplicationServices
import QuartzCore
import CoreGraphics
import CoreVideo
import CoreMedia

// MARK: - Gesture math (ported from src/control/{calibration,cursor}.ts)

private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
  hypot(a.x - b.x, a.y - b.y)
}

/// Vision returns normalized points with the origin at the bottom-left and y
/// growing upward. Convert to screen-style coords (origin top-left, y down,
/// x mirrored to match the mirrored preview).
private func screenPoint(_ p: CGPoint) -> CGPoint {
  CGPoint(x: 1 - p.x, y: 1 - p.y)
}

private let CALIB_X0: CGFloat = 0.24
private let CALIB_X1: CGFloat = 0.76
private let CALIB_Y0: CGFloat = 0.14
private let CALIB_Y1: CGFloat = 0.78

// Dev-only diagnostics: append state changes to /tmp/airclick.log when that file
// exists. Normal users (and normal runs) produce no output at all.
private let probeLock = NSLock()
private func probe(_ s: @autoclosure () -> String) {
  guard FileManager.default.fileExists(atPath: "/tmp/airclick.log") else { return }
  let line = "[\(Int(CACurrentMediaTime()))] \(s())\n"
  if let fh = FileHandle(forWritingAtPath: "/tmp/airclick.log") {
    probeLock.lock()
    defer { probeLock.unlock() }
    _ = try? fh.seekToEnd()
    fh.write(Data(line.utf8))
    try? fh.close()
  }
}

final class GestureEngine: NSObject {
  enum Phase: String { case calibrating, active, stopped }

  // Live state, read by the HUD on the main queue.
  private(set) var phase: Phase = .calibrating
  private(set) var checks = (hand: false, centered: false, spread: false)
  private(set) var progress: CGFloat = 0
  private(set) var handVisible = false
  private(set) var trusted = false
  private(set) var note: String? = nil
  private(set) var bones: [(CGPoint, CGPoint)] = []
  private(set) var dots: [CGPoint] = []
  private(set) var indexTip: CGPoint? = nil
  /// Pointer position: the midpoint of thumb tip and index tip — the pinch
  /// point. Pinching pulls both tips together, so the midpoint barely moves
  /// and clicks don't drag the cursor.
  private(set) var cursorPoint: CGPoint? = nil

  /// Fired on the main queue after every processed frame.
  var onFrame: (() -> Void)?
  /// Fired on the main queue when calibration completes — takeover begins.
  var onConnected: (() -> Void)?

  private var okAcc: Double = 0
  private var failAcc: Double = 0
  private let holdMs: Double = 1400

  private var smoothX: CGFloat?
  private var smoothY: CGFloat?
  private var lDown = false
  private var rDown = false
  private var lastClick: Double = 0
  private var lastRight: Double = 0
  private var lastSeen: Double = 0
  private var lastBeat: Double = 0
  private var moveCount = 0

  // Pointer feel, mouse-style (relative): each frame the hand's movement is
  // scaled by a speed-dependent gain and added to wherever the pointer is.
  // Slow hand → tiny precise steps; fast hand → sweeps; pausing just holds
  // the pointer still. There is no anchor, so nothing can get pulled or
  // snapped anywhere, and a gain transition can never jump the pointer.
  private let gainLow: CGFloat = 0.36
  private let gainHigh: CGFloat = 3.5
  private let gainV0: CGFloat = 0.15 // hand speed in normalized screen units/s
  private let gainV1: CGFloat = 0.8  // max gain reached sooner: full screen from a small hand arc
  // A fast pinch closure (the deliberate tap) briefly freezes the pointer so
  // the press lands where you aim; slow drift and held drags never freeze.
  private let closeFreezeV: CGFloat = 0.9 // pinch-ratio units/s
  private let closeNear: CGFloat = 0.52   // fast closure counts inside this band
  private let freezeMs: Double = 120

  private var velSm: CGFloat?
  private var lastCursor: CGPoint?
  private var lPinchPrev: CGFloat?
  private var rPinchPrev: CGFloat?
  private var freezeUntil: Double = 0

  private let dead: CGFloat = 0.6 // min step (px) that suppresses idle jitter
  // Click needs a near-full close; hold-drag keeps it closed, open releases.
  private let pinchOn: CGFloat = 0.28
  private let pinchOff: CGFloat = 0.54
  private let tapCooldown: Double = 250
  private let handLostMs: Double = 1200

  func setTrusted(_ t: Bool) {
    if t != trusted { probe("trusted -> \(t)") }
    trusted = t
    notifyFrame()
  }

  func setNote(_ n: String?) {
    note = n
    notifyFrame()
  }

  func notifyFrame() {
    if let f = onFrame {
      DispatchQueue.main.async(execute: f)
    }
  }

  func startCamera() {
    probe("startCamera")
    releaseButtons()
    phase = .calibrating
    note = nil
    okAcc = 0
    failAcc = 0
    progress = 0
    smoothX = nil
    smoothY = nil
    notifyFrame()
  }

  func stopCamera() {
    probe("stopCamera")
    phase = .stopped
    handVisible = false
    bones = []
    dots = []
    indexTip = nil
    notifyFrame()
  }

  func recalibrate() {
    probe("recalibrate")
    releaseButtons()
    phase = .calibrating
    okAcc = 0
    failAcc = 0
    progress = 0
    smoothX = nil
    smoothY = nil
    notifyFrame()
  }

  /// Rescue hatch: teleport the pointer back to the exact center of the
  /// screen (relative motion has no anchor, so runaway drift is corrected
  /// only by moving the hand — this gives an instant way back).
  func recenter() {
    guard phase == .active else { return }
    let b = CGDisplayBounds(CGMainDisplayID())
    smoothX = b.midX
    smoothY = b.midY
    postMove()
    probe("recenter")
    notifyFrame()
  }

  func process(_ pixelBuffer: CVPixelBuffer) {
    let now = CACurrentMediaTime() * 1000 // ms

    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1
    do {
      try handler.perform([request])
    } catch {
      return
    }

    let allNames: [VNHumanHandPoseObservation.JointName] = [
      .wrist,
      .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
      .indexMCP, .indexPIP, .indexDIP, .indexTip,
      .middleMCP, .middlePIP, .middleDIP, .middleTip,
      .ringMCP, .ringPIP, .ringDIP, .ringTip,
      .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    let pairs: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
      (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
      (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
      (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
      (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
      (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
    ]

    guard let observation = request.results?.first else {
      lost(now)
      notifyFrame()
      return
    }

    var pts: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
    for name in allNames {
      if let p = try? observation.recognizedPoint(name), p.confidence > 0.3 {
        pts[name] = screenPoint(p.location)
      }
    }

    guard
      let wrist = pts[.wrist],
      let thumbTip = pts[.thumbTip],
      let middleMCP = pts[.middleMCP],
      let idxTip = pts[.indexTip],
      let idxPIP = pts[.indexPIP],
      let midTip = pts[.middleTip],
      let midPIP = pts[.middlePIP],
      let rngTip = pts[.ringTip],
      let rngPIP = pts[.ringPIP],
      let litTip = pts[.littleTip],
      let litPIP = pts[.littlePIP]
    else {
      return // partial joint drop — keep the last state, skip this frame
    }

    let palm = dist(wrist, middleMCP)
    let thumbRatio = palm > 0 ? dist(thumbTip, middleMCP) / palm : 0
    // Pointer between thumb tip and index tip (see cursorPoint above).
    let cursor = CGPoint(x: (idxTip.x + thumbTip.x) / 2, y: (idxTip.y + thumbTip.y) / 2)
    let fingers = [(tip: idxTip, pip: idxPIP), (tip: midTip, pip: midPIP),
                   (tip: rngTip, pip: rngPIP), (tip: litTip, pip: litPIP)]
    let raisedCount = fingers.filter { $0.tip.y < $0.pip.y }.count
    let centered = pts.values.allSatisfy {
      $0.x >= CALIB_X0 && $0.x <= CALIB_X1 && $0.y >= CALIB_Y0 && $0.y <= CALIB_Y1
    }
    let spread = raisedCount >= 3 && thumbRatio >= 0.85

    handVisible = true
    lastSeen = now
    checks = (hand: true, centered: centered, spread: spread)
    indexTip = idxTip
    cursorPoint = cursor
    bones = pairs.compactMap { a, b in
      if let pa = pts[a], let pb = pts[b] { return (pa, pb) }
      return nil
    }
    dots = Array(pts.values)

    switch phase {
    case .calibrating:
      let dt = lastFrameMs > 0 ? min(100, now - lastFrameMs) : 16
      if centered && spread {
        okAcc += dt
        failAcc = 0
      } else {
        failAcc += dt
        if failAcc > 260 {
          okAcc = 0
          failAcc = 0
        }
      }
      progress = CGFloat(min(1.0, okAcc / holdMs))
      if now - lastBeat > 500 {
        lastBeat = now
        probe("calib centered=\(centered) spread=\(spread) progress=\(Int(progress * 100))")
      }
      if okAcc >= holdMs {
        phase = .active
        smoothX = nil
        smoothY = nil
        moveCount = 0
        velSm = nil
        lastCursor = cursor
        lPinchPrev = nil
        rPinchPrev = nil
        freezeUntil = 0
        probe("connect")
        if let f = onConnected {
          DispatchQueue.main.async(execute: f)
        }
      }

    case .active:
      let b = CGDisplayBounds(CGMainDisplayID())
      let dtA = lastFrameMs > 0 ? min(100, max(5, now - lastFrameMs)) : 16
      let lPinch = dist(thumbTip, idxTip) / palm
      let rPinch = dist(thumbTip, midTip) / palm

      // Hand movement this frame, captured before lastCursor is updated.
      let handDx = lastCursor != nil ? cursor.x - lastCursor!.x : 0
      let handDy = lastCursor != nil ? cursor.y - lastCursor!.y : 0

      // Hand speed (normalized units/s), smoothed — drives the gain curve.
      if let last = lastCursor {
        let v = dist(cursor, last) / dtA * 1000
        velSm = velSm == nil ? v : velSm! + (v - velSm!) * 0.35
      }
      lastCursor = cursor

      // Freeze during a fast pinch closure (pre-press only): the tips are
      // flying together, so the pointer holds still and the press lands
      // exactly where you aimed. Held pinches never freeze — moving is the drag.
      if !lDown, !rDown {
        let lRate = lPinchPrev != nil ? (lPinchPrev! - lPinch) / dtA * 1000 : 0
        let rRate = rPinchPrev != nil ? (rPinchPrev! - rPinch) / dtA * 1000 : 0
        if (lPinch < closeNear && lRate > closeFreezeV) || (rPinch < closeNear && rRate > closeFreezeV) {
          freezeUntil = now + freezeMs
        }
      }
      lPinchPrev = lPinch
      rPinchPrev = rPinch

      let frozen = now < freezeUntil

      if !frozen {
        // Mouse-style relative motion: scale just this frame's hand movement
        // by the adaptive gain (slow hand → micro-steps, fast hand → sweeps)
        // and add it to wherever the pointer already is. No anchor — pausing
        // holds the pointer exactly still.
        if smoothX == nil || smoothY == nil {
          smoothX = b.midX
          smoothY = b.midY
        }
        let t = min(1, max(0, ((velSm ?? 0) - gainV0) / (gainV1 - gainV0)))
        let easing = t * t * (3 - 2 * t)
        let g = gainLow + easing * (gainHigh - gainLow)
        let tx = smoothX! + handDx * b.width * g
        let ty = smoothY! + handDy * b.height * g
        let cx = min(max(0, tx), b.width - 1)
        let cy = min(max(0, ty), b.height - 1)
        if abs(cx - smoothX!) > dead || abs(cy - smoothY!) > dead {
          smoothX = cx
          smoothY = cy
        }
      }

      // Thumb+index pinch → left press; stay pinched to drag; open to release.
      // While one button is held the other can't arm — the thumb naturally
      // lands midway between the two fingers mid-pinch, so a slide shouldn't
      // fire a right-click during a left drag (or vice versa).
      if !lDown, !rDown, lPinch < pinchOn, lPinch < rPinch - 0.10, now - lastClick > tapCooldown {
        lDown = true
        lastClick = now
        postButton(right: false, down: true)
      } else if lDown, lPinch > pinchOff {
        lDown = false
        lastClick = now
        postButton(right: false, down: false)
      }

      // Thumb+middle pinch → right press/drag/release, same hold mechanic.
      if !rDown, !lDown, rPinch < pinchOn, rPinch < lPinch - 0.10, now - lastRight > tapCooldown {
        rDown = true
        lastRight = now
        postButton(right: true, down: true)
      } else if rDown, rPinch > pinchOff {
        rDown = false
        lastRight = now
        postButton(right: true, down: false)
      }

      postMove()
      if now - lastBeat > 1000 {
        lastBeat = now
        probe("beat trusted=\(trusted) hand=\(handVisible) moves=\(moveCount)")
      }

    case .stopped:
      break
    }

    lastFrameMs = now
    notifyFrame()
  }

  private var lastFrameMs: Double = 0

  private func lost(_ now: Double) {
    if now - lastSeen > handLostMs || lastSeen == 0 {
      releaseButtons() // never leave the real mouse button stuck down
      smoothX = nil
      smoothY = nil
      velSm = nil
      lastCursor = nil
      lPinchPrev = nil
      rPinchPrev = nil
      freezeUntil = 0
    }
    handVisible = false
    checks = (hand: false, centered: false, spread: false)
    bones = []
    dots = []
    indexTip = nil
    cursorPoint = nil
  }

  // MARK: Real pointer injection

  /// Release any held buttons (recalibrate, camera stop, hand lost) so the
  /// real mouse is never left stuck pressed.
  private func releaseButtons() {
    if lDown { lDown = false; postButton(right: false, down: false) }
    if rDown { rDown = false; postButton(right: true, down: false) }
  }

  private func postMove() {
    guard trusted, let x = smoothX, let y = smoothY else { return }
    let type: CGEventType = lDown ? .leftMouseDragged : (rDown ? .rightMouseDragged : .mouseMoved)
    let button: CGMouseButton = lDown ? .left : (rDown ? .right : .left)
    let e = CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: button)
    e?.post(tap: .cghidEventTap)
    if e != nil { moveCount += 1 }
  }

  private func postButton(right: Bool, down: Bool) {
    guard trusted, let x = smoothX, let y = smoothY else { return }
    let button: CGMouseButton = right ? .right : .left
    let downT: CGEventType = right ? .rightMouseDown : .leftMouseDown
    let upT: CGEventType = right ? .rightMouseUp : .leftMouseUp
    let e = CGEvent(mouseEventSource: nil, mouseType: down ? downT : upT,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: button)
    e?.setIntegerValueField(.mouseEventClickState, value: 1)
    e?.post(tap: .cghidEventTap)
    if e != nil { moveCount += 1 }
    probe("button \(right ? "right" : "left") \(down ? "down" : "up")")
  }
}

// MARK: - Camera

final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let engine: GestureEngine
  private let queue = DispatchQueue(label: "airclick.camera")
  private var configured = false

  init(engine: GestureEngine) {
    self.engine = engine
    super.init()
  }

  func start() {
    AVCaptureDevice.requestAccess(for: .video) { granted in
      guard granted else {
        self.engine.setNote("Camera permission denied")
        return
      }
      self.queue.async { self.setupAndRun() }
    }
  }

  func stop() {
    engine.stopCamera()
    queue.async {
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  private func setupAndRun() {
    engine.setNote(nil)
    if !configured {
      session.beginConfiguration()
      session.sessionPreset = .vga640x480
      guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
              ?? AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input) else {
        session.commitConfiguration()
        engine.setNote("No camera available")
        return
      }
      session.addInput(input)
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
      output.alwaysDiscardsLateVideoFrames = true
      output.setSampleBufferDelegate(self, queue: queue)
      if session.canAddOutput(output) {
        session.addOutput(output)
      }
      session.commitConfiguration()
      configured = true
    }
    session.startRunning()
    engine.startCamera()
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                     from connection: AVCaptureConnection) {
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    engine.process(pb)
  }
}

// MARK: - HUD

private let PANEL_W: CGFloat = 320
private let PANEL_H: CGFloat = 412
private let PAD: CGFloat = 14
private let PREVIEW_W: CGFloat = 292
private let PREVIEW_H: CGFloat = 219 // 4:3, matches the vga640x480 preset

final class HUDPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

final class HUDView: NSView {
  private let engine: GestureEngine
  private let camera: CameraManager
  /// Set by the owner: hides the HUD panel.
  var onHide: (() -> Void)?

  private let previewClip = CALayer()
  private let preview = AVCaptureVideoPreviewLayer()
  private let overlay = CALayer()
  private let bonesLayer = CAShapeLayer()
  private let dotsLayer = CAShapeLayer()
  private let tipLayer = CAShapeLayer()
  private let frameLayer = CAShapeLayer()
  private let ringBack = CAShapeLayer()
  private let ringFill = CAShapeLayer()
  private let titleText = CATextLayer()
  private let statusText = CATextLayer()
  private let chipHand = CATextLayer()
  private let chipCentered = CATextLayer()
  private let chipSpread = CATextLayer()
  private var bannerButton: NSButton!
  private var closeButton: NSButton!
  private var recalButton: NSButton!
  private var centerButton: NSButton!

  init(engine: GestureEngine, camera: CameraManager) {
    self.engine = engine
    self.camera = camera
    let frame = NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H)
    super.init(frame: frame)
    wantsLayer = true
    setupLayers()
    setupButtons()
    refresh()
  }

  required init?(coder: NSCoder) { nil }

  // Layer coordinates are bottom-left; convert from a top-edge offset.
  private func yTop(_ top: CGFloat, _ h: CGFloat) -> CGFloat {
    PANEL_H - top - h
  }

  private func setupLayers() {
    guard let backing = layer else { return }

    backing.frame = bounds
    backing.cornerRadius = 22
    backing.backgroundColor = NSColor(white: 0.055, alpha: 0.95).cgColor
    backing.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
    backing.borderWidth = 1
    backing.masksToBounds = true

    let scale = NSScreen.main?.backingScaleFactor ?? 2

    titleText.string = "AirClick"
    titleText.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
    titleText.fontSize = 14
    titleText.foregroundColor = NSColor(white: 1, alpha: 0.92).cgColor
    titleText.contentsScale = scale
    titleText.frame = CGRect(x: PAD, y: yTop(14, 20), width: 200, height: 20)
    backing.addSublayer(titleText)

    previewClip.frame = CGRect(x: PAD, y: yTop(44, PREVIEW_H), width: PREVIEW_W, height: PREVIEW_H)
    previewClip.cornerRadius = 14
    previewClip.masksToBounds = true
    previewClip.backgroundColor = NSColor(white: 0.02, alpha: 1).cgColor
    backing.addSublayer(previewClip)

    preview.videoGravity = .resizeAspectFill
    preview.session = camera.session // the live feed — without this only the backdrop shows
    preview.frame = previewClip.bounds
    // Mirror the feed so it reads like looking at a mirror: hand right →
    // hand right on screen. The connection may not exist until the session
    // starts, so apply it now and again when the session reports running.
    func applyMirror() {
      if let conn = preview.connection {
        conn.automaticallyAdjustsVideoMirroring = false
        conn.isVideoMirrored = true
      }
    }
    applyMirror()
    NotificationCenter.default.addObserver(
      forName: AVCaptureSession.didStartRunningNotification, object: camera.session, queue: .main
    ) { _ in applyMirror() }
    previewClip.addSublayer(preview)

    overlay.frame = previewClip.bounds
    overlay.isGeometryFlipped = true
    previewClip.addSublayer(overlay)

    bonesLayer.strokeColor = NSColor(white: 1, alpha: 0.38).cgColor
    bonesLayer.fillColor = NSColor.clear.cgColor
    bonesLayer.lineWidth = 2
    bonesLayer.lineCap = .round
    overlay.addSublayer(bonesLayer)

    dotsLayer.fillColor = NSColor(white: 1, alpha: 0.95).cgColor
    overlay.addSublayer(dotsLayer)

    tipLayer.strokeColor = NSColor(white: 1, alpha: 0.9).cgColor
    tipLayer.fillColor = NSColor.clear.cgColor
    tipLayer.lineWidth = 2
    overlay.addSublayer(tipLayer)

    frameLayer.lineWidth = 2
    overlay.addSublayer(frameLayer)
    frameLayer.isHidden = true // calibration shows only the circle, no box chrome

    let c = CGPoint(x: PREVIEW_W / 2, y: PREVIEW_H / 2)
    let ringRect = CGRect(x: c.x - 36, y: c.y - 36, width: 72, height: 72)
    ringBack.path = CGPath(ellipseIn: ringRect, transform: nil)
    ringBack.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
    ringBack.fillColor = NSColor.clear.cgColor
    ringBack.lineWidth = 5
    overlay.addSublayer(ringBack)

    ringFill.path = CGPath(ellipseIn: ringRect, transform: nil)
    ringFill.strokeColor = NSColor(white: 1, alpha: 0.95).cgColor
    ringFill.fillColor = NSColor.clear.cgColor
    ringFill.lineWidth = 5
    ringFill.lineCap = .round
    ringFill.strokeEnd = 0
    overlay.addSublayer(ringFill)

    let size = NSScreen.main?.backingScaleFactor ?? 2
    for chip in [chipHand, chipCentered, chipSpread] {
      chip.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
      chip.fontSize = 11.5
      chip.alignmentMode = .center
      chip.contentsScale = size
      chip.cornerRadius = 9
      chip.masksToBounds = true
      chip.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
      chip.foregroundColor = NSColor(white: 1, alpha: 0.55).cgColor
      backing.addSublayer(chip)
    }
    chipHand.string = "Hand"
    chipHand.frame = CGRect(x: PAD, y: yTop(271, 20), width: 92, height: 20)
    chipCentered.string = "Centered"
    chipCentered.frame = CGRect(x: PAD + 100, y: yTop(271, 20), width: 92, height: 20)
    chipSpread.string = "Spread"
    chipSpread.frame = CGRect(x: PAD + 200, y: yTop(271, 20), width: 92, height: 20)

    statusText.font = NSFont.systemFont(ofSize: 12, weight: .regular)
    statusText.fontSize = 12
    statusText.alignmentMode = .center
    statusText.isWrapped = true
    statusText.contentsScale = size
    statusText.foregroundColor = NSColor(white: 1, alpha: 0.75).cgColor
    statusText.frame = CGRect(x: PAD, y: yTop(299, 36), width: PREVIEW_W, height: 36)
    backing.addSublayer(statusText)
  }

  private func setupButtons() {
    recalButton = makeButton("Recalibrate", width: 140, x: PAD, y: 340, action: #selector(didRecalibrate))
    centerButton = makeButton("Re-center", width: 140, x: PAD + 152, y: 340, action: #selector(didRecenter))
    bannerButton = makeButton("Open System Settings", width: PREVIEW_W, x: PAD, y: 372,
                              action: #selector(didOpenSettings))
    closeButton = makeButton("✕", width: 28, x: PANEL_W - PAD - 28, y: 10, action: #selector(didClose))
  }

  private func makeButton(_ title: String, width: CGFloat, x: CGFloat, y: CGFloat,
                          action: Selector) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    b.bezelStyle = .rounded
    b.controlSize = .small
    b.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    b.frame = CGRect(x: x, y: yTop(y, 28), width: width, height: 28)
    addSubview(b)
    return b
  }

  @objc private func didRecalibrate() {
    engine.recalibrate()
  }

  @objc private func didRecenter() {
    engine.recenter()
  }

  @objc private func didOpenSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }

  @objc private func didClose() {
    onStopCamera()
    onHide?()
  }

  private func onStopCamera() {
    camera.stop()
  }

  /// Called by the engine (main queue) after every frame.
  func refresh() {
    statusText.string = {
      if let note = engine.note { return note }
      if !engine.trusted { return "Grant Accessibility to move the real mouse" }
      switch engine.phase {
      case .stopped:
        return "Camera stopped — use the menu bar to restart"
      case .calibrating:
        return "Hold your hand centered, fingers spread"
      case .active:
        return engine.handVisible
          ? "Pinch thumb+index: click · hold pinch: drag · thumb+middle: right"
          : "Show your hand to the camera"
      }
    }()

    bannerButton.isHidden = engine.trusted
    let by: CGFloat = engine.trusted ? 372 : 340
    for b: NSButton in [recalButton!, centerButton!] {
      b.setFrameOrigin(NSPoint(x: b.frame.origin.x, y: yTop(by, 28)))
    }

    let chips = [(chipHand, engine.checks.hand), (chipCentered, engine.checks.centered),
                 (chipSpread, engine.checks.spread)]
    for (chip, ok) in chips {
      if ok {
        chip.backgroundColor = NSColor(white: 1, alpha: 0.95).cgColor
        chip.foregroundColor = NSColor(white: 0.02, alpha: 1).cgColor
      } else {
        chip.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        chip.foregroundColor = NSColor(white: 1, alpha: 0.55).cgColor
      }
    }

    let calibrating = engine.phase == .calibrating
    ringBack.isHidden = !calibrating
    ringFill.isHidden = !calibrating
    ringFill.strokeEnd = engine.progress

    updateOverlay()
  }

  private func updateOverlay() {
    let w = PREVIEW_W
    let h = PREVIEW_H
    func scale(_ p: CGPoint) -> CGPoint {
      CGPoint(x: p.x * w, y: p.y * h)
    }

    if engine.bones.isEmpty {
      bonesLayer.path = nil
      dotsLayer.path = nil
      tipLayer.path = nil
    } else {
      let bonePath = CGMutablePath()
      for (a, b) in engine.bones {
        bonePath.move(to: scale(a))
        bonePath.addLine(to: scale(b))
      }
      bonesLayer.path = bonePath

      let dotPath = CGMutablePath()
      for p in engine.dots {
        let c = scale(p)
        dotPath.addEllipse(in: CGRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2))
      }
      dotsLayer.path = dotPath

      if let tip = engine.cursorPoint { // the pinch point = where the mouse is
        let c = scale(tip)
        tipLayer.path = CGPath(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14), transform: nil)
      } else {
        tipLayer.path = nil
      }
    }

    let centeredOK = engine.checks.centered && engine.checks.spread
    let rect = CGRect(x: CALIB_X0 * w, y: CALIB_Y0 * h,
                      width: (CALIB_X1 - CALIB_X0) * w,
                      height: (CALIB_Y1 - CALIB_Y0) * h)
    frameLayer.path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
    frameLayer.strokeColor = NSColor(white: 1, alpha: centeredOK ? 0.95 : 0.4).cgColor
    frameLayer.lineDashPattern = centeredOK ? nil : [12, 9]
  }
}

// MARK: - Connect toast (notification-banner style, self-dismissing)

final class ConnectToast {
  private var panel: NSPanel!
  private var titleText: CATextLayer!
  private var subText: CATextLayer!

  func show(trusted: Bool) {
    if panel == nil { build() }
    titleText.string = trusted ? "Connected!" : "Almost connected"
    subText.string = trusted ? "Pinch = click · pinch & hold = drag"
                             : "Grant Accessibility to move the mouse"
    // Top-right, tucked under the menu bar, like a system notification.
    if let screen = NSScreen.main?.frame {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - 232 - 20, y: screen.maxY - 30 - 72))
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      panel.animator().alphaValue = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { [weak self] in
      guard let self, let panel = self.panel, panel.isVisible else { return }
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.4
        panel.animator().alphaValue = 0
      }, completionHandler: {
        panel.orderOut(nil)
      })
    }
  }

  private func build() {
    let w: CGFloat = 232
    let h: CGFloat = 72
    panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                     styleMask: [.borderless, .nonactivatingPanel],
                     backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isFloatingPanel = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.ignoresMouseEvents = true // the takeover must not be interrupted

    let view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    view.wantsLayer = true
    if let l = view.layer {
      l.frame = view.bounds
      l.cornerRadius = 16
      l.backgroundColor = NSColor(white: 0.06, alpha: 0.96).cgColor
      l.borderColor = NSColor(white: 1, alpha: 0.2).cgColor
      l.borderWidth = 1

      let dot = CALayer()
      dot.frame = CGRect(x: 18, y: h - 18 - 12, width: 12, height: 12)
      dot.cornerRadius = 6
      dot.backgroundColor = NSColor.white.cgColor
      l.addSublayer(dot)

      let scale = NSScreen.main?.backingScaleFactor ?? 2
      titleText = CATextLayer()
      titleText.string = "Connected!" // overwritten by show(trusted:)
      titleText.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
      titleText.fontSize = 14
      titleText.foregroundColor = NSColor(white: 1, alpha: 0.95).cgColor
      titleText.contentsScale = scale
      titleText.frame = CGRect(x: 40, y: h - 16 - 18, width: w - 50, height: 18)
      l.addSublayer(titleText)

      subText = CATextLayer()
      subText.string = "Pinch = click · pinch & hold = drag" // overwritten by show(trusted:)
      subText.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
      subText.fontSize = 10.5
      subText.foregroundColor = NSColor(white: 1, alpha: 0.55).cgColor
      subText.contentsScale = scale
      subText.frame = CGRect(x: 40, y: h - 16 - 18 - 20, width: w - 50, height: 16)
      l.addSublayer(subText)
    }
    panel.contentView = view
  }
}

// MARK: - Connect ripple (full-screen celebration, self-dismissing)
//
// A borderless, transparent, mouse-transparent window that plays one ripple
// burst from the screen center when calibration connects: a white flash, a
// rotating dashed ring, and three staggered expanding rings.

final class ConnectRipple {
  private var panel: NSPanel!
  private let host = NSView()

  func show() {
    if panel == nil {
      let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
      panel = NSPanel(contentRect: screen, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
      panel.level = .screenSaver
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.ignoresMouseEvents = true
      panel.hasShadow = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.isReleasedWhenClosed = false
      host.wantsLayer = true
      panel.contentView = host
    }
    playRipple()
    panel.orderFrontRegardless()
    panel.alphaValue = 1
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
      self?.panel?.orderOut(nil) // popups must self-dismiss
    }
    probe("ripple")
  }

  private func playRipple() {
    guard let root = host.layer, let panel = panel else { return }
    root.sublayers?.forEach { $0.removeFromSuperlayer() }
    let c = CGPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
    let scale = NSScreen.main?.backingScaleFactor ?? 2

    // A ring centered at `c`; its scale animation grows it around its anchor.
    // `scaleTo` = grow factor, `alpha` = starting opacity.
    @discardableResult
    func ring(_ radius: CGFloat, lineWidth: CGFloat, scaleTo: CGFloat,
              alpha: CGFloat, delay: Double, spin: CGFloat = 0,
              dash: [CGFloat]? = nil, filled: Bool = false) -> CAShapeLayer {
      let l = CAShapeLayer()
      l.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
      l.position = c
      l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
      if filled {
        l.fillColor = NSColor.white.cgColor
        l.strokeColor = NSColor.clear.cgColor
      } else {
        l.fillColor = NSColor.clear.cgColor
        l.strokeColor = NSColor.white.cgColor
        l.lineWidth = lineWidth
        l.lineCap = .round
      }
      l.path = CGPath(ellipseIn: l.bounds, transform: nil)
      l.lineDashPattern = dash.map { $0.map { NSNumber(value: Float($0)) } }
      l.opacity = 0
      l.contentsScale = scale
      root.addSublayer(l)

      let grow = CABasicAnimation(keyPath: "transform.scale")
      grow.fromValue = 1
      grow.toValue = scaleTo
      let out = CABasicAnimation(keyPath: "opacity")
      out.fromValue = alpha
      out.toValue = 0
      var anims: [CAAnimation] = [grow, out]
      if spin != 0 {
        let s = CABasicAnimation(keyPath: "transform.rotation.z")
        s.fromValue = 0
        s.toValue = spin
        anims.append(s)
      }
      let group = CAAnimationGroup()
      group.animations = anims
      group.duration = 1.2
      group.timingFunction = CAMediaTimingFunction(name: .easeOut)
      group.beginTime = CACurrentMediaTime() + delay
      group.fillMode = .forwards
      l.add(group, forKey: "ripple")
      return l
    }

    // White flash at the center…
    ring(13, lineWidth: 0, scaleTo: 1.6, alpha: 0.95, delay: 0.02, filled: true)
    // …a tight dashed ring that spins as it unwinds ("the code ripple")…
    ring(9, lineWidth: 3, scaleTo: 30, alpha: 0.85, delay: 0.02,
         spin: 0.9, dash: [13, 11])
    // …and three staggered sweep rings crossing the screen.
    ring(44, lineWidth: 5, scaleTo: 22, alpha: 0.9, delay: 0.10)
    ring(44, lineWidth: 3, scaleTo: 15, alpha: 0.5, delay: 0.26)
    ring(44, lineWidth: 2, scaleTo: 10, alpha: 0.3, delay: 0.44)
  }
}

// MARK: - App wiring

final class AppDelegate: NSObject, NSApplicationDelegate {
  let engine = GestureEngine()
  var camera: CameraManager!
  var hud: HUDView!
  var panel: HUDPanel!
  var statusItem: NSStatusItem!
  private let toast = ConnectToast()
  private let ripple = ConnectRipple()

  override init() {
    super.init()
    FileHandle.standardError.write(Data("[AirClick] init\n".utf8))
    probe("launch")
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    FileHandle.standardError.write(Data("[AirClick] didFinishLaunching\n".utf8))
    NSApp.setActivationPolicy(.accessory)

    camera = CameraManager(engine: engine)
    hud = HUDView(engine: engine, camera: camera)

    panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H),
                     styleMask: [.borderless, .nonactivatingPanel],
                     backing: .buffered, defer: false)
    panel.contentView = hud
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isMovableByWindowBackground = true
    panel.hidesOnDeactivate = false // stay put while other apps are active
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    if let screen = NSScreen.main?.frame {
      panel.setFrameOrigin(NSPoint(x: screen.maxX - PANEL_W - 24, y: screen.minY + 70))
    }
    hud.onHide = { [weak panel] in panel?.orderOut(nil) }
    panel.orderFrontRegardless()
    FileHandle.standardError.write(Data(
      "[AirClick] panel ordered front — visible: \(panel.isVisible) frame: \(panel.frame)\n".utf8
    ))

    engine.onFrame = { [weak self] in
      self?.hud.refresh()
    }
    engine.onConnected = { [weak self] in
      guard let self else { return }
      self.ripple.show()
      self.toast.show(trusted: self.engine.trusted)
    }

    setupStatusItem()

    // ⌘1 = rescue hatch: teleport the pointer back to the center of the
    // screen. Global monitor catches it while other apps are key; the local
    // monitor also consumes it so the frontmost app doesn't react to it too.
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.keyCode == 18, // the "1" key
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return }
      self.engine.recenter()
    }
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, event.keyCode == 18,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
            self.engine.phase == .active else { return event }
      self.engine.recenter()
      return nil // consumed
    }

    // Ask once, the standard way — the dialog includes Open System Settings / Deny
    // and dismisses normally. Until trusted the panel sits at normal level so it
    // can never cover the system dialog.
    let trusted = AXIsProcessTrusted()
    engine.setTrusted(trusted)
    probe("didFinishLaunching trusted=\(trusted)")
    if !trusted {
      panel.level = .normal
      let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(prompt)
    }
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self else { return }
      let t = AXIsProcessTrusted()
      if t != self.engine.trusted {
        self.engine.setTrusted(t)
        self.panel.level = t ? .floating : .normal
        if t, self.engine.phase == .active {
          self.ripple.show()
          self.toast.show(trusted: true) // the real "Connected!" when trust lands
        }
      }
    }

    camera.start()
  }

  /// `open` on an already-running (or hidden) instance must actually show it —
  /// without this, re-running `open` appears to do nothing.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    camera.start()
    engine.recalibrate()
    panel.orderFrontRegardless()
    return false
  }

  private func setupStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "cursorarrow.rays",
                             accessibilityDescription: "AirClick")
      button.image?.isTemplate = true
    }
    let menu = NSMenu()
    menu.addItem(withTitle: "Show / hide panel",
                 action: #selector(togglePanel), keyEquivalent: "h")
    menu.addItem(withTitle: "Restart camera & recalibrate",
                 action: #selector(restartCamera), keyEquivalent: "r")
    menu.addItem(withTitle: "Re-center cursor",
                 action: #selector(recenterNow), keyEquivalent: "c")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit AirClick",
                 action: #selector(quitApp), keyEquivalent: "q")
    for item in menu.items {
      item.target = self
    }
    statusItem.menu = menu
  }

  @objc private func togglePanel() {
    if panel.isVisible {
      camera.stop()
      panel.orderOut(nil)
    } else {
      camera.start()
      panel.orderFrontRegardless()
    }
  }

  @objc private func restartCamera() {
    camera.start()
    engine.recalibrate()
  }

  @objc private func recenterNow() {
    engine.recenter()
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
FileHandle.standardError.write(Data("[AirClick] main: entering run loop\n".utf8))
app.run()