import { isFingerRaised, thumbOutRatio, type Landmark } from "../vision/gestures"
import type { Calibration } from "./calibration"

/**
 * Turns a tracked hand into virtual-cursor state, one frame at a time.
 *
 * Cursor: the index fingertip, anchored at calibration ("where your hand was,
 * screen center") and amplified so a small hand sweep covers the whole window.
 * Click: the thumb pops out past the personal spread baseline → left click.
 * Right click: the middle finger raises while the hand stays pointed.
 */

const SMOOTH = 0.42 // exponential smoothing per frame
const GAIN = 1.9 // hand offsets → viewport multiplier
const DEAD_PX = 3 // ignore sub-pixel drift so the cursor rests
const HAND_LOST_MS = 1200 // rearm the cursor after the hand is gone this long

const THUMB_ON = 0.72 // × calibration ratio → thumb popped up = click
const THUMB_OFF = 0.58 // × calibration ratio → thumb tucked again (rearm)
const CLICK_COOLDOWN_MS = 380
const RIGHT_COOLDOWN_MS = 450
/** The middle finger must stay up this long to count (flick-guard). */
const MIDDLE_RUN = 2

export type CursorFrame = {
  x: number
  y: number
  visible: boolean
  thumbOut: boolean
  /** One-shot events for this frame. */
  leftClick: boolean
  rightClick: boolean
}

export type CursorEngine = {
  update(lm: Landmark[] | null | undefined, now: number): CursorFrame
  /** Map the current fingertip position to the screen center. */
  recenter(lm: Landmark[]): void
}

export function createCursorEngine(cal: Calibration): CursorEngine {
  let sx: number | null = null
  let sy: number | null = null
  let thumbUp = false
  let middleRun = 0
  let lastClick = 0
  let lastRight = 0
  let lastSeen = 0

  function update(
    lm: Landmark[] | null | undefined,
    now: number,
  ): CursorFrame {
    const frame: CursorFrame = {
      x: 0,
      y: 0,
      visible: false,
      thumbOut: false,
      leftClick: false,
      rightClick: false,
    }

    if (!lm || lm.length < 21) {
      if (now - lastSeen > HAND_LOST_MS || lastSeen === 0) {
        sx = null
        sy = null
        thumbUp = false
        middleRun = 0
      }
      return frame
    }
    lastSeen = now

    // --- Cursor position --------------------------------------------------
    const tip = lm[8]
    const vx = window.innerWidth
    const vy = window.innerHeight
    const tx = vx / 2 + (1 - tip.x - cal.anchorMx) * vx * GAIN
    const ty = vy / 2 + (tip.y - cal.anchorMy) * vy * GAIN
    const target = Math.max(0, Math.min(vx - 1, tx))
    const targetY = Math.max(0, Math.min(vy - 1, ty))

    if (sx === null || sy === null) {
      sx = target
      sy = targetY
    } else {
      const dx = target - sx
      const dy = targetY - sy
      // Deadzone: don't chase pixel-level jitter while the hand rests.
      if (Math.abs(dx) > DEAD_PX || Math.abs(dy) > DEAD_PX) {
        sx += dx * SMOOTH
        sy += dy * SMOOTH
      }
    }
    frame.x = sx
    frame.y = sy
    frame.visible = true

    // --- Thumb click (left) -----------------------------------------------
    const rel = thumbOutRatio(lm) / cal.thumbRatio
    if (!thumbUp && rel >= THUMB_ON) {
      thumbUp = true
      if (now - lastClick > CLICK_COOLDOWN_MS) {
        frame.leftClick = true
        lastClick = now
      }
    } else if (thumbUp && rel < THUMB_OFF) {
      thumbUp = false
    }
    frame.thumbOut = thumbUp

    // --- Middle finger (right click) ---------------------------------------
    if (isFingerRaised(lm, "middle")) {
      middleRun = Math.min(middleRun + 1, MIDDLE_RUN + 1)
      if (middleRun >= MIDDLE_RUN && now - lastRight > RIGHT_COOLDOWN_MS) {
        frame.rightClick = true
        lastRight = now
      }
    } else {
      middleRun = 0
    }

    return frame
  }

  return {
    update,
    recenter(lm) {
      if (!lm || lm.length < 21) return
      cal.anchorMx = 1 - lm[8].x
      cal.anchorMy = lm[8].y
      sx = null
      sy = null
    },
  }
}