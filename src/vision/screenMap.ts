/**
 * Mirrored cover-crop mapping between normalized video coords and a display
 * box — ported from Gesture Synth so the preview skeleton, target rings and
 * the cursor all agree on where the hand is.
 */

export type CoverCrop = { sx: number; sy: number; sWidth: number; sHeight: number }

export function coverCrop(vw: number, vh: number, cw: number, ch: number): CoverCrop {
  const videoAspect = vw / vh
  const boxAspect = cw / ch
  if (videoAspect > boxAspect) {
    const sHeight = vh
    const sWidth = vh * boxAspect
    return { sx: (vw - sWidth) / 2, sy: 0, sWidth, sHeight }
  }
  const sWidth = vw
  const sHeight = vw / boxAspect
  return { sx: 0, sy: (vh - sHeight) / 2, sWidth, sHeight }
}

/** Mirror + cover-crop a landmark into a box's client coordinates. */
export function landmarkInBox(
  lm: { x: number; y: number },
  videoWidth: number,
  videoHeight: number,
  box: { x: number; y: number; width: number; height: number },
): { x: number; y: number } {
  const vx = (1 - lm.x) * videoWidth
  const vy = lm.y * videoHeight
  const crop = coverCrop(videoWidth, videoHeight, box.width, box.height)
  return {
    x: box.x + ((vx - crop.sx) / crop.sWidth) * box.width,
    y: box.y + ((vy - crop.sy) / crop.sHeight) * box.height,
  }
}