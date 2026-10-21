import { useEffect, useState } from "react"
import styles from "./Playground.module.css"

/**
 * The demo surface AirClick controls. Every interactive element carries
 * [data-air] so the virtual cursor's hover ring finds it, and all clicks —
 * synthetic (thumb pop) or real mouse — share the same handlers.
 * Left/right click tallies arrive as window "airclick" events from App.
 */
export default function Playground() {
  const [counts, setCounts] = useState({ left: 0, right: 0 })
  const [clicked, setClicked] = useState(0)
  const [on, setOn] = useState(true)
  const [opened, setOpened] = useState(false)

  useEffect(() => {
    const onAir = (e: Event) => {
      const kind = (e as CustomEvent<{ kind: string }>).detail?.kind
      if (kind === "left") setCounts((c) => ({ ...c, left: c.left + 1 }))
      if (kind === "right") setCounts((c) => ({ ...c, right: c.right + 1 }))
    }
    window.addEventListener("airclick", onAir)
    return () => window.removeEventListener("airclick", onAir)
  }, [])

  return (
    <main className={styles.wrap}>
      <div className={styles.header}>
        <h1 className={styles.title}>Playground</h1>
        <span className={styles.counts}>
          Air clicks {counts.left} · right {counts.right}
        </span>
      </div>

      <div className={styles.grid}>
        <section className={styles.card} data-air>
          <button type="button" className={styles.bigBtn} data-air onClick={() => setClicked((n) => n + 1)}>
            Click me
          </button>
          <div className={styles.count}>{clicked}</div>
          <p className={styles.sub}>Point, then pop your thumb up.</p>
        </section>

        <section className={styles.card} data-air>
          <h2 className={styles.cardTitle}>Hover target</h2>
          <p className={styles.sub}>
            The ring follows your fingertip — whatever it points at lights up.
          </p>
        </section>

        <section className={styles.card} data-air>
          <h2 className={styles.cardTitle}>Right-click me</h2>
          <p className={styles.sub}>
            Raise your middle finger — the AirClick menu opens here.
          </p>
        </section>

        <button
          type="button"
          className={styles.toggleCard}
          data-air
          role="switch"
          aria-checked={on}
          onClick={() => setOn((v) => !v)}
        >
          <span className={styles.cardTitle}>Auto-blink</span>
          <span className={on ? `${styles.pill} ${styles.pillOn}` : styles.pill}>
            <span className={styles.dot} />
          </span>
          <span className={styles.sub}>{on ? "Yes, blinking" : "No, resting"}</span>
        </button>

        <section className={styles.card} data-air>
          <h2 className={styles.cardTitle}>Fake link</h2>
          <a
            className={styles.fakeLink}
            href="#opened"
            data-air
            onClick={(e) => {
              e.preventDefault()
              setOpened(true)
            }}
          >
            visit fake.page
          </a>
          <p className={styles.sub}>{opened ? "✓ navigation prevented" : "It counts as a click."}</p>
        </section>

        <section className={styles.card} data-air>
          <h2 className={styles.cardTitle}>Why a real mouse still works</h2>
          <p className={styles.sub}>
            Your mouse and trackpad do exactly the same things here — same buttons, same handlers.
          </p>
        </section>
      </div>

      <p className={styles.note}>
        AirClick moves its own cursor inside this page. Browsers don't let a page drive the
        real system pointer — so clicks land wherever your finger points, on this page.
      </p>
    </main>
  )
}