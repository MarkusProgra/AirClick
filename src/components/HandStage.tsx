import { useEffect, useRef, type RefObject } from "react"
import { landmarkInBox } from "../vision/screenMap"
import { CALIB_BOUNDS } from "../control/calibration"
import type { TrackedHands } from "../vision/useHandTracking"
import styles from "./HandStage.module.css"

/**
 * The persistent camera stage. The <video> element must survive across
 * phases (idle → calibrating → active) so the stream isn't torn down, so
 * the container changes shape by switching a CSS class instead of
 * unmounting: full-bleed while calibrating, a mini picture-in-picture
 * while driving the cursor.
 */

export type StageMode = "hidden" | "full" | "mini"

type Props = {
  videoRef: RefObject<HTMLVideoElement | null>
  handsRef: RefObject<TrackedHands>
  mode: StageMode
  showFrame: boolean
  frameOk: boolean
}

const CONNECTIONS: [number, number][] = [
  [0, 1], [1, 2], [2, 3], [3, 4],
  [0, 5], [5, 6], [6, 7], [7, 8],
  [5, 9], [9, 10], [10, 11], [11, 12],
  [9, 13], [13, 14], [14, 15], [15, 16],
  [13, 17], [17, 18], [18, 19], [19, 20],
  [0, 17],
]
const TIPS = [4, 8, 12, 16, 20]

function strokeRoundRect(
  ctx: CanvasRenderingContext2D,
  x: number,
  y: number,
  w: number,
  h: number,
  r: number,
) {
  ctx.beginPath()
  ctx.moveTo(x + r, y)
  ctx.lineTo(x + w - r, y)
  ctx.arcTo(x + w, y, x + w, y + r, r)
  ctx.lineTo(x + w, y + h - r)
  ctx.arcTo(x + w, y + h, x + w - r, y + h, r)
  ctx.lineTo(x + r, y + h)
  ctx.arcTo(x, y + h, x, y + h - r, r)
  ctx.lineTo(x, y + r)
  ctx.arcTo(x, y, x + r, y, r)
  ctx.closePath()
  ctx.stroke()
}

export default function HandStage({ videoRef, handsRef, mode, showFrame, frameOk }: Props) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const canvasRef = useRef<HTMLCanvasElement | null>(null)

  useEffect(() => {
    const container = containerRef.current
    const canvas = canvasRef.current
    if (!container || !canvas) return
    const ctx = canvas.getContext("2d")
    if (!ctx) return
    let raf = 0

    const paint = () => {
      raf = requestAnimationFrame(paint)
      const box = container.getBoundingClientRect()
      if (box.width < 4 || box.height < 4) return
      const dpr = Math.min(2, window.devicePixelRatio || 1)
      const W = Math.round(box.width * dpr)
      const H = Math.round(box.height * dpr)
      if (canvas.width !== W || canvas.height !== H) {
        canvas.width = W
        canvas.height = H
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, box.width, box.height)

      const video = videoRef.current
      const vw = video?.videoWidth ?? 0
      const vh = video?.videoHeight ?? 0
      if (vw === 0 || vh === 0) return

      const box2 = { x: 0, y: 0, width: box.width, height: box.height }
      const hand = handsRef.current?.result?.landmarks?.[0] ?? null

      if (hand) {
        const pts = hand.map((l) => landmarkInBox(l, vw, vh, box2))
        ctx.strokeStyle = "rgba(255,255,255,0.38)"
        ctx.lineWidth = 2
        ctx.beginPath()
        for (const [a, b] of CONNECTIONS) {
          ctx.moveTo(pts[a].x, pts[a].y)
          ctx.lineTo(pts[b].x, pts[b].y)
        }
        ctx.stroke()
        ctx.fillStyle = "rgba(10,10,12,0.9)"
        for (const p of pts) {
          ctx.beginPath()
          ctx.arc(p.x, p.y, 3.4, 0, Math.PI * 2)
          ctx.fill()
        }
        ctx.fillStyle = "rgba(255,255,255,0.95)"
        for (const i of TIPS) {
          ctx.beginPath()
          ctx.arc(pts[i].x, pts[i].y, 3.2, 0, Math.PI * 2)
          ctx.fill()
        }
        // The index fingertip is the cursor tip — mark it.
        ctx.beginPath()
        ctx.arc(pts[8].x, pts[8].y, 7, 0, Math.PI * 2)
        ctx.strokeStyle = "rgba(255,255,255,0.9)"
        ctx.lineWidth = 2
        ctx.stroke()
      }

      if (showFrame) {
        const tl = landmarkInBox({ x: CALIB_BOUNDS.x0, y: CALIB_BOUNDS.y0 }, vw, vh, box2)
        const br = landmarkInBox({ x: CALIB_BOUNDS.x1, y: CALIB_BOUNDS.y1 }, vw, vh, box2)
        ctx.strokeStyle = frameOk ? "rgba(255,255,255,0.95)" : "rgba(255,255,255,0.4)"
        ctx.lineWidth = 2
        if (!frameOk) ctx.setLineDash([12, 9])
        strokeRoundRect(ctx, tl.x, tl.y, br.x - tl.x, br.y - tl.y, 18)
        ctx.setLineDash([])
      }

      const g = ctx.createRadialGradient(
        box.width / 2, box.height / 2, Math.min(box.width, box.height) * 0.42,
        box.width / 2, box.height / 2, Math.max(box.width, box.height) * 0.74,
      )
      g.addColorStop(0, "rgba(0,0,0,0)")
      g.addColorStop(1, "rgba(0,0,0,0.45)")
      ctx.fillStyle = g
      ctx.fillRect(0, 0, box.width, box.height)
    }

    raf = requestAnimationFrame(paint)
    return () => cancelAnimationFrame(raf)
  }, [videoRef, handsRef, showFrame, frameOk])

  return (
    <div ref={containerRef} className={`${styles.stage} ${styles[mode]}`}>
      <video ref={videoRef} className={styles.video} muted playsInline autoPlay />
      <canvas ref={canvasRef} className={styles.canvas} />
    </div>
  )
}