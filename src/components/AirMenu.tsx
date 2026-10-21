import styles from "./AirMenu.module.css"

/**
 * The "right-click" menu, opened by raising the middle finger. Items are
 * real buttons (real mice work too) and carry [data-air] + data-air-menu-item
 * so the virtual cursor's hover ring and click dispatch find them.
 */
export type MenuKind = "recalibrate" | "recenter" | "stop"

type Props = {
  x: number
  y: number
  onAction: (kind: MenuKind) => void
}

const MENU_W = 252

const ITEMS: { kind: MenuKind; label: string; key: string }[] = [
  { kind: "recalibrate", label: "Recalibrate", key: "R" },
  { kind: "recenter", label: "Re-center cursor", key: "C" },
  { kind: "stop", label: "Stop camera", key: "Esc" },
]

export default function AirMenu({ x, y, onAction }: Props) {
  const px = Math.min(Math.max(8, x), window.innerWidth - MENU_W - 8)
  const py = Math.min(Math.max(8, y - 10), window.innerHeight - 216)

  return (
    <div className={styles.menu} data-air-menu style={{ left: px, top: py, width: MENU_W }}>
      <div className={styles.head}>AirClick menu</div>
      {ITEMS.map((it) => (
        <button
          key={it.kind}
          type="button"
          className={styles.item}
          data-air
          data-air-menu-item
          onClick={() => onAction(it.kind)}
        >
          <span>{it.label}</span>
          <kbd>{it.key}</kbd>
        </button>
      ))}
      <div className={styles.foot}>Thumb up = click · Middle up = right-click</div>
    </div>
  )
}