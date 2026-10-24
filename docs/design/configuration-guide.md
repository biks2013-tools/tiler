# Tiler — Configuration Guide

There is one configuration source: `~/Library/Application Support/Tiler/config.json`. No
environment variables or command-line flags configure Tiler. The file is written from a template
on first launch; after that **every key is required** and nothing falls back to a default.

Two ways to change it, both ending in the same file:

1. **Settings window** (menu → Settings…, or open Tiler again). Each change is validated, written
   to the file (keys in a fixed order) and applied immediately. While the file on disk has an
   error, Settings shows it and stays read-only, with Open in Editor / Reload / Restore Defaults,
   so it never overwrites a file you are fixing by hand.
2. **Edit the file**, then Settings → General → Reload (or `scripts/tiler-ctl.sh reload`).

An invalid file is reported in the menu ("Configuration Error…") and Tiler keeps using the last
valid configuration (with none, nothing tiles).

| Key | Type / range | Template value | Meaning |
|---|---|---|---|
| `innerGap` | number, 0–200 | 8 | Points between neighbouring tiles. |
| `outerGap` | number, 0–400 | 8 | Points between the tiles and the usable screen edge (menu bar and Dock excluded). |
| `resizeStep` | number, 0.01–0.5 | 0.05 | Share of a split moved by one resize keypress. |
| `focusFollowsMouse` | `true` / `false` | `false` | On tiled desktops, focus the window under the pointer once it rests. Also toggled from the menu and Settings → General. |
| `focusDelay` | number (seconds), 0.05–1 | 0.15 | How long the pointer must rest before focus follows it. Lower feels snappier; higher avoids focusing windows you only cross. |
| `activeBorder` | string: a colour `"#RRGGBB"` or `"none"` | `"#90EE90"` | Colour of the frame drawn around the focused window on tiled desktops (tiles and floating windows). `"none"` turns the frame off. Also set in Settings → General → Active window. |
| `activeBorderWidth` | number, 1...12 points | `4` | Width of that frame, drawn outside the window's edges (in the gap between tiles). Also set in Settings → General → Active window. |
| `dragToMove` | string: modifiers (`ctrl`, `alt`, `shift`, `cmd`, joined with `+`) or `"none"` | `"alt+cmd"` | Hold these and drag anywhere inside a window to move it, on any desktop. Needs `cmd`, `alt` or `ctrl` (shift alone is refused: shift-click extends selections). `"none"` turns it off. Also set in Settings → General → Drag windows with. |
| `floatingApps` | array of bundle ids | System Settings, Activity Monitor, Calculator | Apps whose windows are never tiled. Find an id with `osascript -e 'id of app "Name"'`. |
| `hotkeys` | object, every action required | see below | Action → key combination, or `"none"` to unbind. |

## Hotkey syntax

`modifier+modifier+key`, at least one modifier. Modifiers: `cmd`/`command`, `ctrl`/`control`,
`alt`/`opt`/`option`, `shift`. Keys: `a`–`z`, `0`–`9`, `left right up down`, `return tab space
delete escape`, `f1`–`f20`, and `- = [ ] ; ' , . / \ \``. A combination may be bound to one
action only. Unknown actions or keys are errors.

Actions: `toggleDesktop`, `focusLeft/Right/Up/Down`, `swapLeft/Right/Up/Down`,
`resizeLeft/Right/Up/Down`, `toggleFloat`, `toggleSplit`, `mirror`, `equalize`, `retile`,
`showHotkeys` (template `ctrl+cmd+/`, opens the shortcuts overlay), `moveResize` (template
`ctrl+cmd+m`, starts the move/resize mode for the focused untiled window), `unminimizeAll`
(template `alt+cmd+m`, restores every minimized window of the frontmost app; it takes over the
system's ⌥⌘M "Minimize All" in apps that have it),
`windowToPreviousDesktop` / `windowToNextDesktop` (templates `ctrl+cmd+,` / `ctrl+cmd+.`, carry the
focused window to the neighbouring desktop), `windowToPointerDisplay` (template `ctrl+cmd+h`, brings
the focused window to the desktop showing on the screen under the pointer). `toggleDesktop`,
`showHotkeys`, `moveResize`, `unminimizeAll` and the three window moves work on every desktop; the rest only while a tiled desktop has focus.

The desktop moves also depend on a macOS setting outside Tiler: System Settings → Keyboard →
Keyboard Shortcuts → Mission Control → **Move left a space** / **Move right a space** must be on
(any key combination). Tiler reads them and says so when they are off. The keys used inside the move/resize mode (arrows, ⇧, ⌥, C, M, Return, Esc) are fixed.

**Upgrading.** A config file written by an older version lacks the newer actions and is rejected
("missing required key 'focusFollowsMouse'"); nothing is filled in silently. Settings → General
then offers **Add Missing Settings**, which adds the template value for each missing setting or
shortcut and changes nothing else (or add the keys by hand, or Restore Defaults).

Settings ranges are narrower than the file allows for convenience (gaps 0–48 / 0–64 pt, resize
step 1–25 %); a larger value set in the file is kept and shown.

`resize<Direction>` moves the divider next to the focused window in that direction (the divider on
that side if there is one, otherwise the opposite one).

## Other files

| File | Content |
|---|---|
| `desktops.json` (same folder) | Tiled desktops (display UUID + Space uuid) and, per desktop, the floating windows (window id, owner pid, last size and position). Written by Tiler; safe to delete to forget all. |

## Build-time setting

| Variable | Required | Meaning |
|---|---|---|
| `NOTARY_PROFILE` | yes, for `scripts/package.sh` | notarytool keychain profile (`tiler-notary`); created once, see `docs/design/release-runbook.md` §0.3. Depends on the App Store Connect API key, which does not expire but must be recreated if leaked. |
| `TILER_SIGN_IDENTITY` | yes, for `scripts/build-app.sh` | Code-signing identity, best given as its SHA-1 (`security find-identity -v -p codesigning`). Releases use the Developer ID Application certificate `2C7D6068C232BA74073D56085DDBB04E5F14DF30` (expires **2027-02-01**; renew a few weeks before, or signing fails). A stable certificate keeps the Accessibility grant valid across rebuilds; the script refuses to run without it. |
