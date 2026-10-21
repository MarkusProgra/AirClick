/**
 * Synthetic pointer + click events at a screen position. Browsers mark events
 * generated from script as "untrusted" (they can't move the OS pointer or open
 * native menus) but they drive this page's own UI perfectly.
 */
export function dispatchClickAt(x: number, y: number): Element | null {
  const el = document.elementFromPoint(x, y)
  if (!(el instanceof Element)) return null
  const init = {
    clientX: x,
    clientY: y,
    bubbles: true,
    cancelable: true,
    view: window,
    button: 0,
    buttons: 0,
    pointerId: 1,
    pointerType: "mouse",
    isPrimary: true,
  } as PointerEventInit
  try {
    el.dispatchEvent(new PointerEvent("pointerdown", init))
    el.dispatchEvent(new PointerEvent("pointerup", init))
  } catch {
    /* pointer events unavailable — mouse events below still fire */
  }
  el.dispatchEvent(new MouseEvent("mousedown", init))
  el.dispatchEvent(new MouseEvent("mouseup", init))
  el.dispatchEvent(new MouseEvent("click", init))
  return el
}

/** Hover-highlight plumbing for aimable targets ([data-air]). */
export class HoverTracker {
  private current: Element | null = null

  update(x: number, y: number): Element | null {
    const el = document.elementFromPoint(x, y)
    const target = el?.closest("[data-air]") ?? null
    if (target === this.current) return this.current
    this.current?.classList.remove("air-hover")
    target?.classList.add("air-hover")
    this.current = target
    return this.current
  }

  clear() {
    this.current?.classList.remove("air-hover")
    this.current = null
  }
}