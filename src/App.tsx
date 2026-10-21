import { useCallback, useEffect, useRef, useState } from "react"
import HandStage, { type StageMode } from "./components/HandStage"
import AirMenu, { type MenuKind } from "./components/AirMenu"
import Playground from "./components/Playground"
import { useHandTracking } from "./vision/useHandTracking"
import {
  calibrationChecks,
  captureCalibration,
  type CalibrationChecks,
} from "./control/calibration"
import { createCursorEngine, type CursorEngine } from "./control/cursor"
import { dispatchClickAt, HoverTracker } from "./control/clicks"
import styles from "./App.module.css"

/** idle → starting → calibrating → active (→ back via recalibrate/stop). */
type Phase = "idle" | "starting" | "calibrating" | "active"

const HOLD_MS = 1400 // how long the centered+spread pose must hold
const CURSOR_HALF = 17 // half the cursor's rendered size

function Check({ ok, label }: { ok: boolean; label: string }) {
  return (
    <span className={ok ? `${styles.check} ${styles.checkOn}` : styles.check}>
      {label}
    </span>
  )
}

export default function App() {
  const videoRef = useRef<HTMLVideoElement | null>(null)
  const cursorRef = useRef<HTMLDivElement | null>(null)
  const ringRef = useRef<HTMLDivElement | null>(null)
  const rippleLayerRef = useRef<HTMLDivElement | null>(null)
  const hoverRef = useRef<HoverTracker | null>(null)
  const engineRef = useRef<CursorEngine | null>(null)
  const menuRef = useRef(false)

  const [phase, setPhase] = useState<Phase>("idle")
  const [cameraOn, setCameraOn] = useState(false)
  const { status, error, handsRef } = useHandTracking(videoRef, cameraOn)
  const [checks, setChecks] = useState<CalibrationChecks | null>(null)
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null)
  const [handSeen, setHandSeen] = useState(false)

  const setMenuOpen = useCallback((m: { x: number; y: number } | null) => {
    menuRef.current = m !== null
    setMenu(m)
  }, [])

  const start = useCallback(() => {
    setPhase("starting")
    setCameraOn(true)
  }, [])

  const stop = useCallback(() => {
    hoverRef.current?.clear()
    engineRef.current = null
    setCameraOn(false)
    setPhase("idle")
    setChecks(null)
    setMenuOpen(null)
  }, [setMenuOpen])

  const recalibrate = useCallback(() => {
    setMenuOpen(null)
    setPhase("calibrating")
  }, [setMenuOpen])

  const recenter = useCallback(() => {
    setMenuOpen(null)
    const lm = handsRef.current?.hands?.[0]
    if (lm) engineRef.current?.recenter(lm)
  }, [handsRef, setMenuOpen])

  const retry = useCallback(() => {
    setCameraOn(false)
    window.setTimeout(() => setCameraOn(true), 80)
  }, [])

  const onMenuAction = useCallback(
    (kind: MenuKind) => {
      if (kind === "recalibrate") recalibrate()
      else if (kind === "recenter") recenter()
      else stop()
    },
    [recalibrate, recenter, stop],
  )

  // Camera is on and tracking → move to calibration.
  useEffect(() => {
    if (phase === "starting" && status === "ready") setPhase("calibrating")
  }, [phase, status])

  // --- Calibration loop ---------------------------------------------------
  useEffect(() => {
    if (phase !== "calibrating") return
    let raf = 0
    let okAcc = 0
    let failAcc = 0
    let last = performance.now()
    let prev = ""

    const tick = (now: number) => {
      raf = requestAnimationFrame(tick)
      const dt = Math.min(64, now - last)
      last = now
      const lm = handsRef.current?.hands?.[0] ?? null
      const c = calibrationChecks(lm)
      const ok = c.hand && c.centered && c.spread
      if (ok) {
        okAcc += dt
        failAcc = 0
      } else {
        failAcc += dt
        if (failAcc > 260) {
          okAcc = 0
          failAcc = 0
        }
      }
      ringRef.current?.style.setProperty("--p", `${Math.min(1, okAcc / HOLD_MS) * 100}%`)
      const tag = `${c.hand}|${c.centered}|${c.spread}`
      if (tag !== prev) {
        prev = tag
        setChecks(c)
      }
      if (okAcc >= HOLD_MS && lm) {
        engineRef.current = createCursorEngine(captureCalibration(lm))
        setPhase("active")
      }
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [phase, handsRef])

  // --- Driving loop -------------------------------------------------------
  useEffect(() => {
    if (phase !== "active") return
    let hover = hoverRef.current
    if (!hover) {
      hover = new HoverTracker()
      hoverRef.current = hover
    }
    const spawnRipple = (x: number, y: number) => {
      const layer = rippleLayerRef.current
      if (!layer) return
      const el = document.createElement("div")
      el.className = "air-ripple"
      el.style.left = `${x}px`
      el.style.top = `${y}px`
      layer.appendChild(el)
      el.addEventListener("animationend", () => el.remove(), { once: true })
    }
    let raf = 0
    let seen = false

    const tick = (now: number) => {
      raf = requestAnimationFrame(tick)
      const lm = handsRef.current?.hands?.[0] ?? null
      const frame = engineRef.current?.update(lm, now) ?? null
      const cur = cursorRef.current
      if (!frame || !cur) return

      cur.style.transform = `translate3d(${frame.x - CURSOR_HALF}px, ${frame.y - CURSOR_HALF}px, 0)`
      cur.classList.toggle("is-off", !frame.visible)
      cur.classList.toggle("is-pressed", frame.thumbOut && frame.visible)
      if (!frame.visible) {
        hover.clear()
        if (seen) {
          seen = false
          setHandSeen(false)
        }
        return
      }
      if (!seen) {
        seen = true
        setHandSeen(true)
      }

      const target = hover.update(frame.x, frame.y)
      cur.classList.toggle("is-hot", !!target)

      if (frame.leftClick) {
        const menuOpen = menuRef.current
        if (menuOpen && !(target && target.closest("[data-air-menu]"))) {
          setMenuOpen(null) // click outside a menu item just closes it
        } else {
          dispatchClickAt(frame.x, frame.y)
          if (menuOpen) setMenuOpen(null)
          spawnRipple(frame.x, frame.y)
          window.dispatchEvent(new CustomEvent("airclick", { detail: { kind: "left" } }))
        }
      }
      if (frame.rightClick) {
        if (menuRef.current) {
          setMenuOpen(null)
        } else {
          setMenuOpen({ x: frame.x, y: frame.y })
          if (target) {
            target.classList.add("air-flash")
            window.setTimeout(() => target.classList.remove("air-flash"), 700)
          }
        }
        window.dispatchEvent(new CustomEvent("airclick", { detail: { kind: "right" } }))
      }
    }

    raf = requestAnimationFrame(tick)
    return () => {
      cancelAnimationFrame(raf)
      hover.clear()
      cursorRef.current?.classList.add("is-off")
      seen = false
      setHandSeen(false)
    }
  }, [phase, handsRef, setMenuOpen])

  // --- Keyboard shortcuts (mouse users get them too) ----------------------
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.repeat) return
      if (e.code === "KeyR" && phase === "active") {
        recalibrate()
      } else if (e.code === "KeyC" && phase === "active") {
        recenter()
      } else if (e.code === "Escape") {
        if (menuRef.current) setMenuOpen(null)
        else if (phase === "calibrating" || phase === "active") stop()
      } else if ((e.code === "Enter" || e.code === "Space") && phase === "idle") {
        start()
      }
    }
    window.addEventListener("keydown", onKey)
    return () => window.removeEventListener("keydown", onKey)
  }, [phase, recalibrate, recenter, setMenuOpen, stop, start])

  const mode: StageMode =
    phase === "active" ? "mini" : phase === "idle" ? "hidden" : "full"

  const statusText =
    phase === "starting"
      ? status === "requesting"
        ? "Waiting for camera permission…"
        : status === "loading"
          ? "Loading hand model…"
          : "Starting…"
      : phase === "calibrating"
        ? "Center your spread hand in the frame"
        : handSeen
          ? "Hand tracked"
          : "Show your hand to the camera"

  return (
    <div className={styles.app}>
      <Playground />
      <HandStage
        videoRef={videoRef}
        handsRef={handsRef}
        mode={mode}
        showFrame={phase === "calibrating"}
        frameOk={!!checks && checks.centered && checks.spread}
      />

      {phase !== "idle" && (
        <header className={styles.topbar}>
          <span className={styles.brand}>AirClick</span>
          <span className={styles.status}>{statusText}</span>
          <span className={styles.separate} />
          <button
            type="button"
            className={styles.btn}
            onClick={recalibrate}
            disabled={phase !== "active"}
          >
            Recalibrate <kbd>R</kbd>
          </button>
          <button type="button" className={styles.btn} onClick={stop}>
            Stop <kbd>Esc</kbd>
          </button>
        </header>
      )}

      {(phase === "calibrating" || phase === "starting") && (
        <div className={styles.calib} aria-live="polite">
          {phase === "calibrating" ? (
            <>
              <div ref={ringRef} className={styles.ring} />
              <div className={styles.checks}>
                <Check ok={!!checks?.hand} label="Hand" />
                <Check ok={!!checks?.centered} label="Centered" />
                <Check ok={!!checks?.spread} label="Spread" />
              </div>
              <p className={styles.calibHint}>Hold it there — fingers spread, thumb out</p>
            </>
          ) : (
            <div className={styles.checks}>
              <span className={styles.check}>{statusText}</span>
            </div>
          )}
        </div>
      )}

      {phase === "active" && (
        <p className={styles.hintChip}>
          Point with your index finger · thumb up = left click · middle up = right click ·{" "}
          <kbd>R</kbd> recalibrate
        </p>
      )}

      {error && cameraOn && (
        <div className={styles.errorBox} role="alert">
          <strong>Camera problem</strong>
          <p>{error}</p>
          <div className={styles.errorActions}>
            <button type="button" className={styles.btn} onClick={retry}>
              Retry
            </button>
            <button type="button" className={styles.btn} onClick={stop}>
              Back
            </button>
          </div>
        </div>
      )}

      {menu && <AirMenu x={menu.x} y={menu.y} onAction={onMenuAction} />}

      {phase === "idle" && (
        <div className={styles.landing}>
          <div className={styles.card}>
            <h1 className={styles.title}>AirClick</h1>
            <p className={styles.tagline}>
              Control this page with your bare hand. No camera until you say so.
            </p>
            <ul className={styles.bullets}>
              <li>Turn on the camera, then hold your hand centered with fingers spread</li>
              <li>Your index fingertip becomes the cursor; the hand is the mouse</li>
              <li>Pop your thumb up → left click · raise your middle finger → right click</li>
              <li>Recalibrate anytime — press <kbd>R</kbd>, the topbar button, or the air menu</li>
            </ul>
            <button type="button" className={styles.startBtn} onClick={start}>
              Turn on camera &amp; calibrate
            </button>
            <p className={styles.startHint}>
              or press <kbd>Enter</kbd> — the camera stays off until then
            </p>
            <p className={styles.footnote}>
              AirClick moves its own cursor inside this page. Browsers don't allow a page to
              drive the real system pointer, so clicks land wherever your finger points — on
              this page itself. For real system-mouse control, run the AirClick desktop app in
              native/AirClick.app.
            </p>
          </div>
        </div>
      )}

      <div ref={cursorRef} className={`${styles.cursor} is-off`} aria-hidden="true">
        <span className={styles.cursorDot} />
      </div>
      <div ref={rippleLayerRef} className={styles.ripples} aria-hidden="true" />
    </div>
  )
}