# AirClick

Control a web page — or your **whole Mac** — with your bare hand.

## Quick Start

**Web app** (in-page virtual cursor):

```bash
npm install
npm run dev      # → http://localhost:5174
```

**Desktop app** (real system mouse):

```bash
cd native
./build.sh               # builds + signs AirClick.app
open AirClick.app
```

On first run, grant **Camera**; grant **Accessibility** when macOS asks
(System Settings → Privacy & Security → Accessibility). Recommended once:
`bash native/make-signing-cert.sh` signs the app with a stable self-signed
identity, so the Accessibility grant survives every rebuild (ad-hoc builds
re-check it, and you'd have to re-toggle after each rebuild).

## Desktop app (real mouse control)

`native/AirClick.app` is a standalone macOS app that drives the **real system pointer**:
same hand tracking (Vision framework, 21 joints), same calibration pose (hand centered +
fingers spread ~1.5 s). The pointer sits at the **pinch point** — the midpoint between your
thumb tip and index tip, so pinching doesn't shift the cursor. Gestures:

- **Pinch thumb + index** — left press; **keep it pinched to drag**; open to release.
- **Pinch thumb + middle** — right press/drag/release, same hold mechanic.
- **Pointer feel** — a slow hand takes very small, precise steps; a fast hand
  sweeps across the screen (velocity-adaptive gain).
- **Pinch-closure freeze** — when the fingers deliberately tap together, the
  pointer holds still so the press lands where you aimed instead of drifting
  with the motion.

Rebuild with `native/build.sh`, launch with `open native/AirClick.app`.

Permissions on first run: **Camera** (prompt) and **Accessibility** (System Settings →
Privacy & Security → Accessibility → add AirClick) — without the latter macOS ignores
injected mouse events; the HUD shows a banner until granted.

## Web app (in-page cursor)

```bash
npm install
npm run dev     # http://localhost:5174
```

`localhost` is a secure context, so `getUserMedia` works over plain HTTP — no certificate warnings.

The camera stays **off** until you opt in, then:

1. **Calibrate** — hold your hand centered in the viewfinder, fingers spread, thumb out for ~1.5 s.
2. **Point** — your index fingertip becomes the cursor (hand offset amplified to cover the whole window).
3. **Left click** — pop your thumb out past its calibrated baseline.
4. **Right click** — raise your middle finger; the AirClick menu opens (Recalibrate / Re-center / Stop camera).
5. **Recalibrate anytime** — press `R`, the topbar button, or the air menu; re-center without recalibrating with `C`.

Keyboard/mouse shortcuts work throughout: `R` recalibrate, `C` re-center, `Esc` stop, `Enter` start.

## Honest limitation (web)

Browsers don't let a page move the real system pointer or send trusted clicks. The web app moves a
**virtual cursor inside the page** and dispatches synthetic (untrusted) pointer/click events, so
it clicks this page's own UI with real `elementFromPoint` targeting — but not other apps or tabs.
The desktop app exists to close that gap.

## Stack

- **Web**: Vite + React 19 + TypeScript; MediaPipe HandLandmarker (@mediapipe/tasks-vision, GPU
  with CPU fallback) for 21-point hand tracking; CSS Modules; Poppins via @fontsource.
- **Desktop**: single-file Swift (`native/main.swift`) on AppKit + AVCapture + Vision; no
  third-party deps; CGEvent pointer/click injection.

## Pushing to your own repository

This folder is already a git repo (branch `main`; all 28 source files committed —
`node_modules/`, `dist/`, and the built `native/AirClick.app/` are gitignored and are
recreated by `npm install` / `./build.sh`). To connect it to any git host — GitHub,
GitLab, self-hosted — add your remote and push:

```bash
git remote add origin git@github.com:YOUR-USER/YOUR-REPO.git   # or an https URL
git push -u origin main
```

The git identity here is repo-scoped (`markusmac2 <markusmac2@users.noreply.github.com>`).
Change it for this repo only with:

```bash
git config user.name "Your Name"
git config user.email "you@example.com"
```