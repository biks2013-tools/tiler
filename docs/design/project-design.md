# Tiler — Project Design

Tiler is a menu bar app (`LSUIElement`) that tiles windows with a BSP dwindle layout, scoped to
individual macOS desktops: one (display, Space) pair at a time, chosen by the user.

## Goals

- Same core job as HyprMac (Hyprland-style tiling), restricted to the desktops the user turns on.
- Never read, move or resize a window on another display or another desktop. The exceptions are
  explicit user requests on the focused window: the move/resize mode, and moving a window to the
  previous/next desktop.
- Fast and light: no polling, no keyboard event tap, no work at all while nothing is tiled (the ⌘⌥-drag tap runs only when a mouse button is pressed).
- Few moving parts, so few bugs.

## What was deliberately left out (compared with HyprMac)

| HyprMac feature | Why Tiler drops it |
|---|---|
| 10 virtual workspaces that hide windows in a screen corner | Conflicts with "touch only this desktop"; native Spaces already provide desktops. The hide-corner, parking, and ghost-window logic were HyprMac's largest bug source. |
| Caps Lock Hypr key (`hidutil` remap + active `CGEventTap` + IOHID reading) | An active tap delays every keystroke system-wide when the app's thread stalls (HyprMac's documented sluggishness). Carbon `RegisterEventHotKey` needs no permission and only sees the registered combinations. |
| 1 Hz discovery polling, frame read-back loops, verification transactions | Replaced by AX notifications plus a ~1 ms reconcile, and by acting on window moves only during a mouse drag. |
| Focus borders, dimming overlays, scratchpad, overview, saved layouts | Not part of the core tiling job; each costs WindowServer time. |

## Architecture

```
main.swift ── AppDelegate ── StatusMenu (NSStatusItem, menu acts on the clicked display)
                  ├── ShortcutsOverlay     HUD panel listing the bindings (never takes focus)
                  ├── SettingsWindowController  toolbar panes, SwiftUI forms, SettingsModel
                  └── Controller (main thread: state, events, layout decisions)
                        ├── Desktop[DesktopKey]  BSPTree + floating set + applied frames
                        ├── AppHandle[pid]       one thread + run loop + AXObserver per app
                        ├── Hotkeys              Carbon hot keys, registered per focus
                        └── Spaces / Screen      SkyLight + NSScreen lookups (read-only)
TilerCore (pure, unit-tested): BSPTree, Geometry, Config, KeyCombo
```

### Desktop identity

`DesktopKey = (display UUID, Space uuid)`. Space ids are reassigned at login, Space uuids are not.
The session Space id is resolved from the uuid with `CGSCopyManagedDisplaySpaces` at launch and on
display changes. A desktop is *visible* when `SLSManagedDisplayGetCurrentSpace(display) == spaceID`.
Each desktop owns its own tree, so switching desktops needs no parking or restoring: a hidden
desktop's tree simply waits.

### Event flow

- `AppHandle` (per app, own thread): app-level `kAXWindowCreated`, `kAXFocusedWindowChanged`;
  window-level `kAXUIElementDestroyed`, `kAXWindowMoved`, `kAXWindowResized`,
  `kAXWindowMiniaturized`. Events hop to the main thread as small enums. A launching app may
  refuse the subscription (retried each second, up to 5 times); once it is accepted, a
  `subscribed` event re-reads the app's focus (if frontmost) and schedules a reconcile, so windows
  opened before then are tiled at once instead of on the next unrelated event.
- `NSWorkspace`: app launch/terminate/hide/unhide/activate, active Space change, active display
  change (undocumented `NSWorkspaceActiveDisplayDidChangeNotification`); screen parameter changes.
- Every event schedules a coalesced **reconcile** (20 ms), never a full AX scan.
- Handles exist only while at least one desktop is tiled.

### Reconcile (≈1 ms)

1. Skip unless a tiled desktop is visible; wait while `SLSManagedDisplayIsAnimating`.
2. One `CGWindowListCopyWindowInfo(onScreenOnly)`; keep layer-0 windows of other apps.
3. Per visible tiled desktop: windows whose centre is on its display **and** whose
   `SLSCopySpacesForWindows` contains its Space (empty answer = trust on-screen).
4. Re-check the Space did not change during the read.
5. Remove vanished windows (closed, minimised, hidden, moved away) from the tree; insert new ones.
   A new window splits the window that was active when it opened: the newest entry of the
   controller's focus history (recently focused windows, tiled or not, newest first) that is not
   the new window itself and is already in this desktop's tree; else the desktop's `lastFocused`.
   The history matters because a new window usually takes focus before it joins the tree, so a
   window opened from it must still find it.
   Unknown windows are resolved asynchronously on their app's thread (role `AXWindow`, subrole
   `AXStandardWindow`, not minimised/fullscreen, size settable, enabled fullscreen button), with
   one re-check 0.6 s later for windows that become standard after creation.
6. Lay out only if something changed; write only frames that differ from the last written frame.

### Writing frames

`AppHandle.setFrame` stores the newest frame per window and schedules one flush on the app's
thread, so a slow app (iTerm2 takes up to 700 ms) never replays stale layouts and never blocks
other apps or the main thread. The flush turns `AXEnhancedUserInterface` off if it was on, then
writes size → position → size. Every AX call is bounded by a 1 s messaging timeout.

### Feedback-loop rule

Window moved/resized notifications are acted on only while the left mouse button is down
(a user drag). Tiler therefore never reacts to its own writes, or to an app that refuses a size
or snaps itself. On release: a resize adopts the dragged edges into the split ratios
(`BSPTree.adoptResize`), a move onto another tile swaps, anything else snaps back.

### Focus

Focus is tracked from `kAXFocusedWindowChanged` and app activation. Focusing another window uses
`_SLPSSetFrontProcessWithOptions` + the synthetic make-key-window event record (yabai/AeroSpace)
plus `AXRaise`, because since macOS 14 `NSRunningApplication.activate()` from a background app is
ignored. The *active display* is the display of the focused window, else the one under the mouse.
(`SLSCopyActiveMenuBarDisplayIdentifier` was tried and reported the wrong display on macOS 27.)

### Hotkeys

Carbon `RegisterEventHotKey`. `toggleDesktop`, `showHotkeys` and `moveResize` are always
registered; the others only while the active display shows a tiled desktop, and are unregistered
otherwise so apps keep those keys. Transient UIs (overlay, move/resize mode) borrow plain keys
with `Hotkeys.borrow` and give them back with `release()`.

### User interface

- **Menu bar item**: a template glyph drawn in code (one tall tile, two stacked; filled when the
  desktop being worked on is tiled). Menu: section header "Desktop N · Display", Tile This
  Desktop (checkmark, shortcut hint), count of other tiled desktops, Keyboard Shortcuts,
  Settings…, About, Quit. Shortcut hints are real `keyEquivalent`s, rendered by AppKit.
- **Shortcuts overlay**: borderless non-activating `NSPanel`, `.hudWindow` visual effect with a
  rounded mask, SwiftUI content, centred on the active display. It never becomes key, so the
  app underneath keeps the keyboard. Esc is held as a Carbon hotkey only while it is visible;
  a global mouse-down monitor, Space change and app activation also close it.
- **Settings**: `NSTabViewController` in toolbar style (`toolbarStyle = .preference`) with one
  `NSHostingController` per pane (`sizingOptions = .preferredContentSize`, so the window resizes
  per pane), each a `Form` with `.formStyle(.grouped)`. `SettingsModel` holds a copy of the
  config; every change becomes a new `Config`, is serialised with `Config.json()`, re-parsed,
  written atomically and reloaded through `Controller.save`. While a shortcut is recorded,
  `Controller.hotkeysSuspended` unregisters all hotkeys so the keys reach the recorder (an
  `NSEvent` local monitor). Opening the app again, or a second launch, shows Settings.
- **App bundle**: icon rendered by `scripts/make-icon.swift` (no image assets in the repo), a
  standard About panel, and a hidden main menu so ⌘W/⌘Q/⌘,/editing keys work in Settings.
- Minimum macOS is 14 (section-header menu items, `NSApp.activate()`, SwiftUI `onChange` two-value form).

### Moving a window to another desktop

`DesktopMover` (`⌃⌘,` / `⌃⌘.`, every desktop). The private Space-move calls are blocked on macOS
14.5+ and Tiler never mutates Spaces itself; instead it drives the system's own shortcut, the way
the user would:

1. Read the focused window on a short-lived `WindowMover` thread: id, frame, a grab point just
   right of the zoom button (`kAXZoomButton`, else the top-centre of the frame) and whether it is
   an `AXStandardWindow`.
2. Find the window's display, its Spaces in Mission Control order (`CGSCopyManagedDisplaySpaces`)
   and the neighbour. Refuse (HUD note) if there is none, if it is a full-screen Space, or if the
   window is not standard.
3. Read the user's "Move left/right a space" shortcut from `com.apple.symbolichotkeys` (ids 79 and
   81: key code and modifier flags; default ⌃+fn+arrow when never customised). Refuse if disabled.
4. `Controller.beginDesktopMove`: moved/resized notifications for that window are ignored (not a
   user drag) and reconcile waits.
5. Synthetic HID events, mouse events with no modifier flags (the shortcut's keys are still held):
   mouse-down on the grab point, +50 ms drag by 1 px, +100 ms the Mission Control shortcut, +500 ms
   mouse-up, pointer warped back.
6. +150 ms: success if the display's current Space is the target. `endDesktopMove` removes the
   window from every desktop's tree (that desktop re-lays out when next visible) and floating set;
   if it floated and the target desktop is tiled, it floats there with the same frame. Reconcile
   then tiles it on a tiled target. The window is refocused.

**Here: the desktop on the screen under the pointer** (`windowToPointerDisplay`, `⌃⌘H`, every
desktop, `DesktopMover.moveToPointerDisplay`). The usual case is ⌘Tab with macOS set not to switch
Spaces for the app (`com.apple.dock workspaces-auto-swoosh` = 0): the app is active, its window is
on another desktop.

1. Target = the screen under the pointer and its current Space; refuse a full-screen Space.
2. Read the focused window as above (refuse a non-standard one), its screen (frame centre) and its
   Spaces (`SLSCopySpacesForWindows`, read-only). It is *hidden* when none of them is its
   screen's current Space. Same screen and not hidden: "Already here" note.
3. `beginDesktopMove`.
4. Hidden: `carry` it to its screen's current Space. Warp the pointer to the grab point (the
   shortcuts act on the screen under the pointer); press the Mission Control shortcut toward the
   window's desktop once per desktop in between, each after the previous switch has finished (a
   bounded 50 ms check of `SLSManagedDisplayGetCurrentSpace`/`IsAnimating`, at most 1.5 s, then
   0.1 s); hold the title bar as in step 5 above; press the opposite shortcut the same number of
   times; release; pointer back. Success when the screen is back on its Space and the window is on
   it. Refuse when the window's Space is full screen or a shortcut is off.
5. Other screen: `Geometry.place` (TilerCore: same size shrunk to the target's usable area, same
   relative position, offset ÷ free room per axis) and one frame write on the `WindowMover` thread.
   A window written onto another display joins that display's current Space.
6. `endDesktopMove(display: target, to: space)` on success (tiled/floating carry-over and
   reconcile exactly as step 6 above) and refocus; otherwise a HUD note and `endDesktopMove(to: nil)`.


### Unminimize all (`unminimizeAll`)

`⌥⌘M` (template) on any desktop: a short-lived `WindowMover` thread for the frontmost app reads
`kAXWindows` and sets `kAXMinimized` to false on every minimized one, then stops. Tiler observes
miniaturize but not deminiaturize, so the controller schedules reconciles 0.4 s and 1 s later (the
Dock's restore animation); on a tiled desktop the restored windows rejoin the layout. Nothing
restored: a beep.

### Modifier + drag (`WindowDrag`)

`dragToMove` (template `"alt+cmd"`, `"none"` = off) moves the window under the pointer when the
user drags anywhere inside it with those modifiers held, on any desktop. It is Tiler's one active
`CGEventTap`, kept as cheap as possible:

1. **Tap.** `.cgSessionEventTap`, head insert, default (filtering) options, for `leftMouseDown`,
   `leftMouseDragged` and `leftMouseUp` only: no key events, no plain mouse moves. It lives on its
   own `RunLoopThread` ("tiler.drag.tap"), so a busy main thread never delays anyone's clicks. The
   callback compares the event's cmd/alt/ctrl/shift flags with the configured set (exact match),
   ignores Tiler's own synthetic events (the desktop mover's drag), records the point under a
   lock and returns. A matching press and the drag/release that follow are swallowed (the app
   never sees the click); everything else passes untouched. A tap disabled by timeout is
   re-enabled from the callback, and a drag in progress is then released at the current pointer
   (the real release may have gone by while the tap was off), so it can never stay stuck.
2. **Window.** On a second thread ("tiler.drag.ax"), `AXUIElementCopyElementAtPosition` on the
   system-wide element (0.5 s timeout) → its `AXWindow`, or, when that finds none (apps such as
   Electron and Chromium build their accessibility tree lazily, so the first hit test can come
   back without a window), the frontmost layer-0 window the window server lists under the point,
   matched by id among its app's `AXWindows`; accepted only if it is a standard,
   non-full-screen window of another app with a settable position. The swallowed click never
   brings it forward, so its app is focused (`focusWindow`) and then the window is raised
   (`AXRaise`; an app in the background ignores the raise, hence this order, as in
   `AppHandle.focus`), so it moves above the tiles it is dragged over.
3. **Moves.** Each drag event stores the newest pointer position; the AX thread writes
   `origin + (pointer − press)` as the window position and loops until nothing newer is pending,
   so writes are coalesced to the app's speed. A release that comes before the window is found
   still gets its final position.
4. **Tiling.** The swallowed press never reaches the window server, so `NSEvent.pressedMouseButtons`
   stays 0 during such a drag. `WindowDrag.isActive` (main thread; true from grab until the last
   write) is ORed into the controller's `userDragging`. The drag handling does not wait for the
   app's moved notifications, which can arrive late or only after the release (a fast drag, a
   busy app): `onGrab` (window id) starts the controller's drag as soon as the window is found,
   and `onDrop` (window id, release point), sent after the last write, ends it at once, so the
   release swaps a tiled window with the tile under the pointer or snaps it back. A floating
   window's frame is captured as for any drag.

Measured: 0 CPU at rest (no callback runs without a click). Checked live: an untiled move by
exactly the drag distance with no text selected in TextEdit; plain drags and other modifier sets
reach the app; on a tiled desktop a drop on another tile swaps, a short drag snaps back.

### Active window frame (`ActiveBorder`)

`activeBorder` (`"#RRGGBB"` or `"none"`, template `"#90EE90"`) and `activeBorderWidth` (1...12,
template 4) draw a frame around the focused window on a visible tiled desktop:

- **One overlay.** A borderless, non-activating, click-through, transparent `NSPanel` at normal
  level, ordered directly above the target with `order(.above, relativeTo: windowID)`: windows
  stacked above the target (a floating window, a dialog) still cover the frame where they
  overlap. Collection behaviour `managed` + `ignoresCycle` + `fullScreenNone`: it stays on the
  desktop it was shown on.
- **Geometry.** The window's frame as its app reports it (AX, read on the app's thread after any
  frame Tiler is writing), because the window-server list can lag a moment behind a resize the
  app has already reported (a window closes, its neighbour grows, and the frame kept the old
  size); the window-server bounds are used only when the app gives none. A generation counter
  drops answers overtaken by a newer update, and each layout schedules one recheck 0.25 s later
  for apps that settle on their own size without notifying. Expanded by the width; the ring is stroked inside that rect, outside the window's edges (in the
  gap between tiles), with rounded corners following the window's.
- **Updates, no polling.** `Controller.updateBorder` runs on focus changes and everything else
  that calls `updateHotkeys` (Space and display changes, desktop toggles, config reloads), at the
  end of each reconcile, after a drop, and on moved/resized notifications of the framed window.
  It hides the frame while a window is dragged (title bar or modifier + drag), when the focused
  window is not one the visible tiled desktop owns, when it is off screen, and when the setting
  is `"none"`.

### Focus follows mouse

Optional (`focusFollowsMouse`, off in the template; delay `focusDelay`). Designed so it costs
nothing at rest and almost nothing in motion:

1. **Rest.** A listen-only `CGEventTap` for `mouseMoved` only. Listen-only taps receive copies
   after delivery, so they cannot delay input, unlike the active keyboard tap HyprMac used. It
   exists only while the setting is on and at least one desktop is tiled.
2. **First move.** The callback disables the tap and starts a 40 ms timer that reads the pointer
   position, so a moving mouse costs at most 25 wake-ups per second however fast it reports.
3. **Rested** (no movement for `focusDelay`). One `CGWindowListCopyWindowInfo(onScreenOnly)`
   (~1 ms): if any window at pop-up-menu level or above is on screen (an open menu, a contextual
   menu, the app switcher) nothing happens; otherwise the topmost window under the pointer,
   skipping the cursor ("Window Server") and the Dock's full-screen overlay, decides. It is
   focused only if it is a layer-0 window the visible tiled desktop owns (tile or floating) and is
   not focused already; a menu, popover or panel on top blocks. The timer stops, the tap is on again.
4. **Focus, with or without raise.** If no ordinary window above it overlaps the target, it is
   focused and raised (`AppHandle.focus`). If one does (a floating or other untiled window: tiles
   never overlap), it is focused **without** raising, so a tiled window never covers an untiled
   one: `focusWindowWithoutRaise` activates the app with `kCPSNoWindows` (the stacking order is
   untouched) and sends the make-key event records. In apps with several windows the key window
   does not always follow (Pending item in the issue register).

Measured on this Mac (synthetic mouse events at 80 Hz): 0 CPU idle; 0.015 s of CPU per 10 s of
continuous motion (~0.15 % of a core). An `NSEvent` global monitor (one wake-up per event) cost
about 0.13 s for the same motion, so the tap-then-track design is about 9× cheaper. Skipped while
the shortcuts overlay or the move/resize mode is up, during drags and with a mouse button down.

### Floating windows persist (membership, size and position)

`Desktop.floating` maps each floating window id to its owner pid; `Desktop.floatingFrames` holds
the last frame seen for each. `desktops.json` stores, per desktop, `displayUUID`, `spaceUUID` and
`floating: [{id, pid, frame}]` (the 0.2/0.3 list of keys and 0.4 records without `frame` still
load).

- **Capture.** A moved/resized notification for a floating window (a drag, the move/resize mode,
  the app itself) schedules one frame read 0.3 s after the last change; a changed frame is saved
  with writes coalesced to one per second. `centerFloating` records the frame it writes.
- **Restore after a restart.** Restored windows go into `framesToRestore`; the next reconcile that
  sees one on screen resolves it on its app's handle (so later moves are observed) and writes the
  saved frame once, if at least half of it lies on the desktop's display (`frameFits`).
- **Float again.** Floating a window that floated before puts it back at its last frame (same
  `frameFits` check), otherwise it is centred. Frames are kept in memory after a window is tiled
  again and dropped when it closes or its app quits. On restore a window stays floating only if that id exists now and belongs to the same pid,
because window ids restart after a logout or reboot. Entries drop when the window is destroyed or
its app quits. Reconcile no longer prunes floating windows that are merely hidden, minimised or on
another Space.

### Move/resize mode (untiled windows)

`MoveResizeMode` (menu or `⌃⌘M`) is the one place Tiler touches a window outside a tiled
desktop, and only on an explicit request, only the focused window, only while the mode is on.

- **Target**: the frontmost app's focused window, read on a dedicated `WindowMover` thread
  (`kAXFocusedWindow`, position settable, not full screen). If a tiled desktop holds it
  (`Controller.isTiled`), a HUD says to float it first and nothing changes.
- **Keys**: `Hotkeys.borrow` registers the arrows (plain, ⇧, ⌥, ⇧⌥), C, M, Return, Enter and Esc
  as Carbon hotkeys for the life of the mode and `release()` gives them back, so apps never lose
  those keys otherwise. Pressed and released events are both delivered; a held key repeats from a
  main-thread timer (0.3 s delay, 45 ms interval) because Carbon hotkeys do not auto-repeat. The
  shortcuts overlay borrows Esc the same way.
- **Arithmetic**: `WindowNudge` (TilerCore, pure, unit-tested) computes the next frame inside the
  window's usable display area inset by `outerGap`: moves clamp to the area, resizes keep the
  top-left corner with a 160×100 minimum and push back inside, C centres, M fills.
- **Writes**: `WindowMover.setFrame` coalesces to the newest frame and writes size → position →
  size on its thread, then reads back what the app accepted; the mode continues from that frame,
  so an app's own size limits are respected.
- **End**: Return / Enter / Esc / the shortcut again, an app activation, a Space change, or a
  click (global mouse monitor). The thread stops with the mode.

### Startup

`Controller.prepare()` runs at launch (config, scripting hook); `start()` (desktops, observers,
hotkeys) runs once Accessibility is granted. Menu toggling is disabled until then.

### Layout

`BSPTree`: leaves hold windows, splits hold orientation + ratio (0.1–0.9). New windows split the
last focused tile along its longer side and take the second half. `layout(in:gap:)` records each
node's frame, which `moveDivider` and `adoptResize` use. Frames are rounded to whole points.

## Private APIs (SIP on; verified on macOS 27.0.1)

`SLSMainConnectionID`, `CGSCopyManagedDisplaySpaces`, `SLSManagedDisplayGetCurrentSpace`,
`SLSManagedDisplayIsAnimating`, `SLSCopySpacesForWindows`, `_AXUIElementGetWindow`,
`GetProcessForPID`, `_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`.
All are read-only or focus-related; Tiler never moves windows between Spaces (broken on 26/27).

## Files

| Path | Role |
|---|---|
| `Sources/TilerCore/BSPTree.swift` | Dwindle tree, layout, divider moves, drag-resize adoption |
| `Sources/TilerCore/Geometry.swift` | Directional neighbour, hit testing, placing a frame on another screen |
| `Sources/TilerCore/Config.swift` | Strict config parsing and writing, actions (titles, groups), key combos (symbols, recorder init), template |
| `Sources/Tiler/Controller.swift` | State, events, reconcile, layout, hotkey actions, drags |
| `Sources/Tiler/AppHandle.swift` | Per-app thread, AX observer, reads/writes |
| `Sources/Tiler/Spaces.swift` | Screens and Spaces lookups |
| `Sources/Tiler/Hotkeys.swift` | Carbon hot keys |
| `Sources/Tiler/StatusMenu.swift` | Menu bar item |
| `Sources/Tiler/ShortcutsOverlay.swift` | Keyboard shortcuts HUD |
| `Sources/Tiler/MoveResizeMode.swift` | Move/resize mode, `WindowMover` thread, its HUD |
| `Sources/Tiler/HUDPanel.swift` | Shared non-activating HUD panel |
| `Sources/Tiler/DesktopMover.swift` | Move the focused window to the previous/next desktop, or to the screen under the pointer |
| `Sources/TilerCore/WindowNudge.swift` | Move/resize arithmetic (pure, tested) |
| `Sources/Tiler/Settings.swift` | Settings window, model and panes (incl. shortcut recorder) |
| `Sources/Tiler/Appearance.swift` | Menu bar glyph, key caps view, menu key equivalents |
| `Sources/Tiler/PrivateAPI.swift` | Private symbol declarations |
| `scripts/build-app.sh` | Build, bundle (icon, Info.plist), sign, install |
| `scripts/make-icon.swift` | Render the app icon iconset |
| `scripts/tiler-ctl.sh` | Send commands to the running app |
