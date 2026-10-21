/** Landmark helpers for AirClick — ported from the Gesture Synth gesture kit. */

export type Landmark = { x: number; y: number; z: number; visibility?: number }

const FINGERS = {
  index: { pip: 6, tip: 8 },
  middle: { pip: 10, tip: 12 },
  ring: { pip: 14, tip: 16 },
  pinky: { pip: 18, tip: 20 },
} as const

export type FingerName = keyof typeof FINGERS

/**
 * A finger is "raised" when its tip sits above its middle joint — the base
 * probe for both calibration spread and the middle-finger right-click.
 */
export function isFingerRaised(landmarks: Landmark[], finger: FingerName): boolean {
  const { pip, tip } = FINGERS[finger]
  return landmarks[tip].y < landmarks[pip].y
}

export function raisedFingerCount(landmarks: Landmark[]): number {
  return (Object.keys(FINGERS) as FingerName[])
    .map((f) => isFingerRaised(landmarks, f))
    .filter(Boolean).length
}

/**
 * Thumb "out" ratio, orientation-agnostic: thumb-tip to palm-center distance
 * over wrist-to-palm-center (the hand's own scale). Tucked-in thumb ≈ 0.6–0.9,
 * popped-out thumb ≥ 1.1 — thresholds become reliable once divided by the
 * per-person value captured at calibration.
 */
export function thumbOutRatio(landmarks: Landmark[]): number {
  const tip = landmarks[4]
  const wrist = landmarks[0]
  const mid = landmarks[9]
  const scale = palmLength(landmarks)
  if (!scale) return 1
  return Math.hypot(tip.x - mid.x, tip.y - mid.y) /
    Math.hypot(wrist.x - mid.x, wrist.y - mid.y)
}

export function palmLength(landmarks: Landmark[]): number {
  const wrist = landmarks[0]
  const mid = landmarks[9]
  return Math.hypot(wrist.x - mid.x, wrist.y - mid.y)
}