import { isFingerRaised, raisedFingerCount, thumbOutRatio, type Landmark } from "../vision/gestures"
import type { HandLandmarkerResult } from "@mediapipe/tasks-vision"

/** A single tracked hand, normalized video coords (y grows downward, x mirrored later). */
export function bestHand(result: HandLandmarkerResult | null): Landmark[] | null {
  return result?.landmarks[0] ?? null
}

/** Live checks for the calibration pose: hand centered + all five spread. */
export type CalibrationChecks = {
  hand: boolean
  centered: boolean
  spread: boolean
}

/** The gesture frame keeps the pose region — the middle of the camera view. */
export const CALIB_BOUNDS = { x0: 0.24, x1: 0.76, y0: 0.14, y1: 0.78 } as const
const { x0: X_MIN, x1: X_MAX, y0: Y_MIN, y1: Y_MAX } = CALIB_BOUNDS
/** Thumb must read as "out" without a personal baseline yet (see gestures.ts). */
const SPREAD_THUMB_RATIO = 1.0

export function calibrationChecks(
  lm: Landmark[] | null | undefined,
): CalibrationChecks {
  const hand = !!lm && lm.length >= 21
  let centered = false
  let spread = false
  if (hand) {
    centered = lm!.every((p) => p.x >= X_MIN && p.x <= X_MAX && p.y >= Y_MIN && p.y <= Y_MAX)
    spread = raisedFingerCount(lm!) === 4 && isFingerRaised(lm!, "index")
      && thumbOutRatio(lm!) >= SPREAD_THUMB_RATIO
  }
  return { hand, centered, spread }
}

/** The snapshot captured when calibration completes. */
export type Calibration = {
  /** Mirrored x / raw y of the index fingertip at calibration time. */
  anchorMx: number
  anchorMy: number
  /** This person's spread-thumb ratio — the click thresholds divide by it. */
  thumbRatio: number
}

export function captureCalibration(lm: Landmark[]): Calibration {
  return {
    anchorMx: 1 - lm[8].x,
    anchorMy: lm[8].y,
    thumbRatio: Math.max(0.4, thumbOutRatio(lm)),
  }
}