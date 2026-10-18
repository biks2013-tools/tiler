# Issues - Pending Items

## Pending

- **Focus without raise may leave the key window behind (apps with several windows).** Focus
  follows mouse on a tiled window partly covered by an untiled one activates the app without
  raising (`focusWindowWithoutRaise`). The app becomes active, but in testing (TextEdit,
  M365Mail) the hovered window did not always become the app's key window, so typing could go
  to another window of the same app. Raised windows (nothing overlapping) are not affected. Next
  step: find a key hand-over that is reliable without ordering the window (the yabai `0x0d`
  window-activation record pair did not work on macOS 27 in testing).

1. **Apps with a minimum size overlap their neighbour.** Tiler writes the tile size and accepts
   what the app does. Outlook refuses widths below 770 pt, so on the 1512 pt laptop display two
   tiles overlap by ~26 pt. A fix would read back the actual size after a write and shift the
   split ratio, which needs care to avoid oscillation. Seen 2026-10-10.
2. **Conflicts with other window tools.** Rectangle (`⌃⌥` arrows/letters, `⌃⌥⌘←/→`), the local
   Hammerspoon config (its `⌘⌥`-drag, Hyper+←/→ desktop move and `⌘⌥M` unminimize were removed
   in favour of Tiler's on 2026-10-10), any other `⌘⌥`-drag tool, and a running
   HyprMac would act on the same windows or keys. Tiler's defaults avoid the known shortcuts; do
   not tile with Tiler on a desktop HyprMac also manages.
3. **Drag-resize not yet checked live** (unit-tested via `BSPTree.adoptResize`). Drag-swap was
   checked live.
4. **Tahoe corner radii.** macOS 26+ windows have large, varying corner radii, so equal gaps can
   look uneven. Cosmetic.
5. **"Displays have separate Spaces" off** is handled in code (falls back to the "Main" managed
   display) but not checked live.
6. **A binding can be taken by another app first.** Carbon accepts a registration even when
   another tool (e.g. Hammerspoon's `⌃⌥K`) already owns the combination, and that tool then
   wins. Settings can only detect clashes between Tiler's own actions. Seen 2026-10-10 while
   testing the recorder.
7. **Old `~/Library/Application Support/Tider/` folder** is left from before the rename (its
   `desktops.json` was copied to the `Tiler` folder). Safe to delete.

9. **Move/resize mode keeps a window on its display.** Moving a window to another display with
   the keyboard is not supported (frames are clamped to the window's display).

10. **Moving a window to another desktop depends on a title-bar drag.** An app whose title bar
    has no draggable area right of the zoom button (custom-drawn chrome) may not move; Tiler then
    says "The window did not move". It also needs the Mission Control "Move left/right a space"
    shortcuts on.

11. **Modifier + drag and synthetic clicks.** `WindowDrag` lets Tiler's own synthetic events
    through (the desktop mover posts with no modifiers anyway), but another tool posting a
    synthetic ⌘⌥ click would be taken as a drag. Not seen; noted 2026-10-10.

## Completed

- **2026-10-18 — Light-green frame around the active window on tiled desktops.** Requested by
  the user. `ActiveBorder` (one click-through overlay ordered just above the focused window),
  config keys `activeBorder` (`"#90EE90"`) and `activeBorderWidth` (4), Settings → General →
  Active window. Both keys were added to the user's config directly (backup kept outside the
  repo); other configs get them through Add Missing Settings. Checked live with a standalone
  driver: the ring drew outside the window's edges with matching corners, ordered above the
  window and below the window stacked above it. Not yet exercised inside Tiler on a tiled
  desktop (none was tiled at the time).
  Follow-up (reported 2026-10-19): after closing a window, the frame kept the remaining window's
  old (half-width) size while the window grew. Cause: the frame read the window-server bounds,
  which lag behind the app's resize, and nothing refreshed it after. Fix: read the frame from the
  app (AX), drop answers overtaken by newer updates, and recheck once 0.25 s after each layout.

- **2026-10-11 — Focus follows mouse raised tiled windows over untiled ones.** Reported: moving
  the mouse over a tiled window must not make it cover an untiled window. Cause: focus follows
  mouse focused and raised (`AppHandle.focus`) the window under the pointer, which put a tiled
  window above a floating window overlapping it. Fix (the user chose focus without raise over
  not focusing): when an ordinary window above the target overlaps it, Tiler focuses it with
  `focusWindowWithoutRaise` (`kCPSNoWindows` activation plus the make-key records); otherwise it
  focuses and raises as before. Checked live with the no-raise activation: hovering the
  uncovered parts of tiled Chrome and a tiled cmux window left a floating cmux window on top and
  made the hovered app active; activation plus make-key kept the stacking order (M365Mail). The
  final build (raise only when nothing overlaps) is installed but not yet exercised by hand.

- **2026-10-10 — A new window split some other window, not the active one (0.8.1).** Reported:
  a new window should halve the window active at that moment. Causes: (1) new windows split
  the desktop's `lastFocused`, which only records focus on windows already in the tree; a new
  window takes focus before it joins, so a window opened from it split the previous one;
  (2) a just-launched app refuses the window notifications for a moment (retried each second),
  and windows it opened meanwhile waited for an unrelated event before tiling, by which time
  focus had moved on. Fix: a focus history (newest first, tiled or not, pruned on close); a new
  window splits the newest focused window, other than itself, already in the tree. A
  `subscribed` app event schedules a reconcile (and re-reads focus) once the app accepts the
  notifications. Checked live: with Chrome focused, TextEdit launched with its windows tiled
  within 1.5 s, splitting Chrome; the next new document split the focused TextEdit window.

- **2026-10-10 — A window moved with ⌥⌘ + drag stayed behind the tiles (0.8.1).** Reported: the
  dragged window should be on top, not hidden behind the windows tiled on the desktop. Cause:
  the swallowed press never brings the window forward (a title-bar press does), and
  `WindowDrag` raised the window (`AXRaise`) before focusing its app; an app in the background
  ignores the raise, and focusing an app that is already active does not reorder its windows.
  Fix: focus first, then raise (the order `AppHandle.focus` uses), on the drag's AX thread at
  grab. Checked live: cmux (the active app, under Chrome) and Dorian (at the back) each came to
  the front within the first drag events. Same release: when the accessibility hit test finds
  no window (apps such as Electron build their tree lazily, so a first press could pick up
  nothing), `WindowDrag` falls back to the frontmost layer-0 window the window server lists
  under the pointer.

- **2026-10-10 — ⌥⌘ + drag did not swap tiled windows (0.8.1).** Reported: dropping a tiled
  window onto another tile swapped it when dragged by the title bar, but not when dragged with
  ⌥⌘ from anywhere in it. Most likely cause (synthetic drags on 0.8.0 swapped almost every
  time, so not reproduced exactly): the controller started and ended drag handling only from the
  app's window-moved notifications. With the press swallowed by `WindowDrag`, the drag ends the
  moment the button is released (`isActive` false), and an app that reports its moves late
  (or only after the release) left Tiler with no drag to end, so no swap and no snap back.
  Fix: `WindowDrag.onGrab`/`onDrop` hand the controller the window and the release point
  directly; `endDrag(at:)` uses that point. Also: a tap disabled by timeout now releases a drag
  in progress at the current pointer, so a lost release cannot leave `isActive` stuck (which
  would block focus follows mouse and later drops). Checked live with ⌥⌘ drags at several
  speeds, down to a 2-event flick, on two- and three-window layouts: every drop on another tile
  swapped and a short drag snapped back.

- **2026-10-10 — ⌥⌘M unminimizes the frontmost app's windows (0.8.0).** Action `unminimizeAll`
  (General group, every desktop), replacing the Hammerspoon `⌘⌥M` (removed from `init.lua` and
  the hotkeys cheatsheet; backup kept outside the repo). Checked live on tiled Desktop 1: two
  minimized TextEdit windows came back on ⌥⌘M and joined the layout. Note: the default shadows
  the system's ⌥⌘M "Minimize All" in apps that offer it.

- **2026-10-10 — ⌘⌥ + drag moves a window from anywhere in it (0.7.0).** `WindowDrag`, config
  key `dragToMove` (Settings → General → Drag windows with), replacing the Hammerspoon
  `windowDragTap` (removed from `~/.hammerspoon/init.lua` and its hotkeys cheatsheet; backup kept
  outside the repo). The Hammerspoon Hyper+←/→ desktop move was removed the same day (Tiler's
  `⌃⌘,` / `⌃⌘.` replace it). First build moved tiled windows without snapping back: the swallowed press
  never reaches the window server, so `NSEvent.pressedMouseButtons` reads 0; fixed by
  `WindowDrag.isActive` feeding the controller's `userDragging`. Checked live: TextEdit moved by
  exactly the drag (−300, −200) with no text selected; plain drags and ⌃⌘ / ⌃⌥⌘ drags reached the
  app; on tiled Desktop 1 a drop on another tile swapped, a short drag snapped back; 0 CPU idle.

- **2026-10-10 — Move the focused window to the previous/next desktop (0.6.0).** `DesktopMover`,
  `⌃⌘,` / `⌃⌘.`. Checked live on the main display: untiled Desktop 3 → 4 → 3 → 2 → tiled
  Desktop 1 (window tiled on arrival) → refused toward the full-screen Space → out to Desktop 2
  (left Desktop 1's layout) → back to Desktop 3.

- **2026-10-10 — Floating windows now keep their size and position (0.5.0).** Frames are captured
  0.3 s after a floating window moves or resizes, saved (coalesced 1 s), restored once after a
  restart, and reused when a window is floated again. Checked live: frame saved after the
  move/resize mode; a window moved while Tiler was off returned to its saved frame on restart;
  tile → float again returned to the saved frame; closing removed the entry.

- **2026-10-10 — Floating windows were tiled again after a Tiler restart (0.4.0).** Floating is
  now saved per desktop with the window's owner pid and validated on restore; closed windows and
  quit apps drop out. Checked live: a floated TextEdit window stayed floating across a restart;
  closing it removed the entry.
- **2026-10-10 — Focus follows mouse (0.4.0).** Listen-only mouse tap at rest, 40 ms tracking
  while moving, one window-list read at rest. Checked live: focus follows a resting pointer
  across three apps; a fast pass does not focus; an open menu blocks it. CPU: 0 idle, 0.015 s per
  10 s of motion (an NSEvent global monitor measured ~0.13 s, so it was replaced).

- **2026-10-10 — Keyboard move/resize for untiled windows (0.3.0).** `⌃⌘M` mode
  (`MoveResizeMode`, `WindowNudge`, `Hotkeys.borrow`). Checked live on a floated TextEdit window:
  refusal on a tiled window, move 40 pt, ⌥ 8 pt, ⇧ resize, hold-to-repeat, M fill, Return and
  ⌃⌘M end, arrows released afterwards. Test-tool note: synthetic arrow-key events must carry the
  fn + numeric-pad flags real keyboards send, or Carbon does not match them.
- **2026-10-10 — Upgrading made the config invalid.** Adding an action makes older files miss a
  required key. Kept strict (no silent default) and added the explicit **Add Missing Shortcuts**
  button in Settings (`Config.addingMissingHotkeys`); checked live: only `moveResize` was added.
- **2026-10-10 — Move/resize hint showed "1.576 × 801"** (locale grouping) and an odd Esc glyph.
  Now `Text(verbatim:)` and "esc".

- **2026-10-10 — Renamed Tider → Tiler** (targets, bundle id `com.giorgosmarinos.tiler`, support
  folder, log subsystem, `TILER_SIGN_IDENTITY`, `scripts/tiler-ctl.sh`, Carbon signature `TLRR`).
  `/Applications/Tider.app` moved to the Trash; tiled desktops carried over.
- **2026-10-10 — Shortcuts overlay ignored Esc.** A non-activating panel shown while another app is
  frontmost does not get keyboard focus. The overlay now never takes focus; Esc is registered as
  a Carbon hotkey only while the overlay is visible (`Hotkeys.captureEscape`). Checked live with
  Finder frontmost: open, Esc, and toggle all work, and Finder keeps focus.
- **2026-10-10 — Settings opened behind other apps** when requested by `tiler-ctl.sh settings` or a
  second launch (macOS 14+ ignores `activate()` without a click in the app). `show()` now brings
  the window forward with `focusWindow` when the app is not active.

- **2026-10-10 — Focus hotkeys did nothing.** `NSRunningApplication.activate()` from a background
  app is ignored since macOS 14. Fixed with `_SLPSSetFrontProcessWithOptions` + make-key-window
  event record + `AXRaise` (`PrivateAPI.swift: focusWindow`). Checked live.
- **2026-10-10 — Tiling hotkeys swallowed keys on an untiled desktop.**
  `SLSCopyActiveMenuBarDisplayIdentifier` reported the laptop display while Finder on the main
  display had focus. The active display is now the focused window's display, else the mouse's.
  Checked live: `⌃⌘J` reached Finder on the main display.
- **2026-10-10 — First default hotkeys collided** with Rectangle and Hammerspoon (a resize key moved
  the window to another display / another Space). Defaults moved to the `⌃⌘` family.
- **2026-10-10 — Screen or gap changes were not applied** until a window came or went. Desktops now
  carry `needsLayout`, set on display changes and config reloads.

## Release log

- **2026-10-10 — v0.8.1 (build 18).** ⌥⌘ + drag swaps reliably and keeps the dragged window on
  top; window lookup falls back to the window server; new windows split the active window;
  launching apps tile at once. 32 tests passed; app and disk image `status: Accepted`,
  `source=Notarized Developer ID`. Zip SHA-256
  `7023cc0e14597407e1f50861fc94f00bae8c5bf80bab7e12c4090f829a028f18` (download verified), DMG
  `f767907a20777dca1b0dd91b5a886157aa245e70ef7f0fb327ca4768cb598986`. Tap commit `tiler 0.8.1`
  (a68bd7e); `brew audit` clean, scratch install accepted; Pages serves the 0.8.1 decks. No config
  changes.

- **2026-10-10 — v0.8.0 (build 17).** ⌥⌘M unminimizes the frontmost app's windows. 32 tests
  passed; app and disk image `status: Accepted`, `source=Notarized Developer ID`. Zip SHA-256
  `ba4658652acadb977884fcfbbdf6946763fcb2e9677e62aeb4622443dd51b924`, DMG
  `d9903ad5b052a340a132f1c878869534d2e8ae0bd81878e3d8380d3fc78284c5`. Config gains
  `hotkeys.unminimizeAll` (Add Missing Settings).

- **2026-10-10 — v0.7.0 (build 16).** ⌥⌘ + drag moves a window from anywhere in it. 31 tests
  passed; app and disk image `status: Accepted`, `source=Notarized Developer ID`. Zip SHA-256
  `9357641c61ebe83de8b15f98f10a1f33acd1f290419d0242d564ca64740512e1` (download verified), DMG
  `87e6473f81a1634e8ea599ce8831b8a526b3d528f8d70c89ec466ad088383a39`. Config gains `dragToMove`
  (Add Missing Settings). Tap commit `tiler 0.7.0`; cask audit clean; scratch install accepted.

- **2026-10-10 — v0.6.0 (build 15).** Move the focused window to the previous/next desktop. 30
  tests passed; app and disk image `status: Accepted`, `source=Notarized Developer ID`. Zip
  SHA-256 `9abd1adbf3caf464cde5a701cd0bc26e6ea97c63549987514e79cf612eb530cb`, DMG
  `105ac65a8abfc4af9779647f89b07b54b1d868863ae521108290b0a56b8cde5b`. Config gains two
  shortcuts (Add Missing Settings).

- **2026-10-10 — v0.5.0 (build 11).** Floating windows keep size and position. 29 tests passed;
  app and disk image `status: Accepted`, `source=Notarized Developer ID`. Zip SHA-256
  `2b3c91eda14a30b138e9b6e794ab97f0b24bfe1768157e79b85d6774ea3a01e7`, DMG
  `0271dd8f694c01b46f10cbbf5cb1629f47faa524e47f3fa1f899d52df662e609`. No config changes.

- **2026-10-10 — v0.4.0 (build 9).** Floating windows persist; focus follows mouse; Add Missing
  Settings. `scripts/package.sh`: 29 tests passed; app and disk image `status: Accepted`,
  `source=Notarized Developer ID`. Zip SHA-256
  `1b660b6ce8b9b293cc1524410207d32f456e6ff9f427d91c56106f2e7eae5aa2`, DMG
  `47ee563a1b9e4b99996dae05ba0ec8fd676149cfccd81a441f542aded5217492`. Installed over 0.3.0
  here; Accessibility kept.

- **2026-10-10 — v0.3.0 (build 3).** Keyboard move/resize mode, Add Missing Shortcuts, MIT
  license. `scripts/package.sh`: 27 tests passed; app and disk image `status: Accepted`, stapled,
  `source=Notarized Developer ID`. Zip SHA-256
  `4e042965f57064f39e310ac90ce6f4cd366c317a42117c26f4256a50f79195b1`, DMG
  `3b4e479d0a5a61e2bd079e50ccc13424b28ea5840882e223924316d1ca9aeb04`. Installed over 0.2.0 on
  this Mac: the Accessibility grant was kept (same Developer ID).

- **2026-10-10 — v0.2.0 (build 1).** `scripts/package.sh` with Developer ID `2C7D6068…` and
  profile `tiler-notary`: 22 tests passed; app and disk image `status: Accepted`, stapled,
  `source=Notarized Developer ID`; universal (x86_64 arm64). Zip SHA-256
  `c3729a053a7b2873d8206baa86ffb039ddd48e27ebf0de7b179f93e412ce345f`, DMG
  `d45a90348b75076ce1613335637827fd193ea4f1593917defa21beb7db44df2b`. Release
  https://github.com/biks2013-tools/tiler/releases/tag/v0.2.0 (downloaded zip checksum verified). Tap
  `biks2013-tools/homebrew-tiler`: `brew style` clean, `brew audit --cask --online` clean, scratch
  `brew install --cask` accepted by Gatekeeper and uninstalled. Moving from the Apple Development
  to the Developer ID signature dropped the Accessibility grant on this Mac (expected; re-grant once).

## Dependency vetting log

- 2026-10-10 — No third-party dependencies. System frameworks only (AppKit, ApplicationServices,
  Carbon, ServiceManagement, private SkyLight).
