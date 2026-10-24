import AppKit
import TilerCore

/// The tiling brain. Main-thread only. Owns the tiled desktops, the per-app
/// AX handles and the hotkeys, and turns window events into layouts.
///
/// Design rules that keep it fast and predictable:
/// - Nothing runs while no desktop is tiled: no AX observers, no threads.
/// - Event-driven, never polled. A reconcile costs one CGWindowList call plus
///   one Space lookup per on-screen window (about a millisecond).
/// - Only windows on a tiled desktop's Space *and* display are ever touched.
/// - Window moves and resizes are acted on only while the mouse button is
///   down (a user drag), so the app can never fight its own writes or an
///   app that refuses a size.
final class Controller {
    private(set) var config: Config?
    private(set) var configError: String?
    private(set) var desktops: [DesktopKey: Desktop] = [:]
    var onChange: (() -> Void)?
    /// The shortcuts overlay hotkey was pressed.
    var onShowHotkeys: (() -> Void)?
    /// The move/resize shortcut was pressed.
    var onMoveResize: (() -> Void)?
    /// A move-window-to-desktop shortcut was pressed (true = next desktop).
    var onMoveToDesktop: ((Bool) -> Void)?
    var onMoveToPointerDisplay: (() -> Void)?
    /// The window being carried to another desktop: its synthetic drag is not
    /// a user drag, and reconcile waits until it has landed.
    private var movingWindow: CGWindowID?
    /// True while a transient UI (shortcuts overlay, move/resize mode) is up;
    /// focus does not follow the mouse then.
    var transientUIActive: (() -> Bool)?
    /// A second launch or `tiler-ctl.sh settings` asked for the Settings window.
    var onShowSettings: (() -> Void)?
    /// True while Settings records a shortcut: no hotkey is registered, so the
    /// keys reach the recorder.
    var hotkeysSuspended = false {
        didSet {
            guard hotkeysSuspended != oldValue else { return }
            hotkeys.configure(hotkeysSuspended ? [:] : config?.hotkeys ?? [:])
            updateHotkeys()
        }
    }

    private var apps: [pid_t: AppHandle] = [:]
    private var facts: [CGWindowID: WindowFacts] = [:]
    private var resolving: Set<CGWindowID> = []
    private var rechecked: Set<CGWindowID> = []
    private var focused: (pid: pid_t, id: CGWindowID?)?
    /// Recently focused windows, newest first, tiled or not: a new window
    /// splits the newest one already in its desktop's tree.
    private var focusHistory: [CGWindowID] = []
    private var reconcileScheduled = false
    private var drag: (key: DesktopKey?, id: CGWindowID, timer: Timer)?
    private let myPID = ProcessInfo.processInfo.processIdentifier
    /// Set once Accessibility is granted and tiling runs.
    private(set) var started = false
    private lazy var hotkeys = Hotkeys { [weak self] action in self?.perform(action) }

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tiler", isDirectory: true)
    static let configURL = supportDir.appendingPathComponent("config.json")
    private static let desktopsURL = supportDir.appendingPathComponent("desktops.json")

    // MARK: Lifecycle

    /// Config and the scripting hook: available before Accessibility is granted,
    /// so Settings and `tiler-ctl.sh` work from the first launch.
    func prepare() {
        reloadConfig()
        // Scripting hook: `scripts/tiler-ctl.sh toggle <display-uuid|active>`, `retile`, `reload`, `settings`, `shortcuts`, `moveresize`, `unminimize`, `nextdesktop`, `previousdesktop`, `dump`.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.giorgosmarinos.tiler.command"),
                                                            object: nil, queue: .main) { [weak self] n in
            self?.command(n.object as? String ?? "")
        }
    }

    /// Tiling itself; needs Accessibility.
    func start() {
        started = true
        restoreDesktops()
        windowDrag.onGrab = { [weak self] id in self?.windowDragGrabbed(id) }
        windowDrag.onDrop = { [weak self] id, point in self?.windowDragDropped(id, at: point) }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, !desktops.isEmpty, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            attach(app)
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            detach(app.processIdentifier)
            forgetFloating(of: app.processIdentifier)
            scheduleReconcile()
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleReconcile() }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            readFocus(of: app)
            scheduleReconcile()
        }
        // The second name is undocumented (yabai uses it): focus moved to another display.
        for name in [NSWorkspace.activeSpaceDidChangeNotification,
                     Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateHotkeys()
                self?.scheduleReconcile()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            refreshSpaceIDs()
            for d in desktops.values { d.applied.removeAll(); d.needsLayout = true }
            scheduleReconcile()
            onChange?()
        }
        if !desktops.isEmpty { attachAll() }
        if let front = NSWorkspace.shared.frontmostApplication { readFocus(of: front) }
        updateHotkeys()
        updateMouseMonitor()
        scheduleReconcile()
    }

    private func command(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        switch parts.first {
        case "toggle":
            let target = parts.count > 1 && parts[1] != "active" ? parts[1] : activeDisplay()
            if let target { toggleDesktop(onDisplay: target) }
        case "retile":
            perform(.retile)
        case "reload":
            reloadConfig()
        case "settings":
            onShowSettings?()
        case "shortcuts":
            onShowHotkeys?()
        case "moveresize":
            onMoveResize?()
        case "unminimize":
            unminimizeFrontApp()
        case "nextdesktop":
            onMoveToDesktop?(true)
        case "previousdesktop":
            onMoveToDesktop?(false)
        case "here":
            onMoveToPointerDisplay?()
        case "dump":
            for d in desktops.values {
                let visible = Spaces.current(onDisplay: d.key.displayUUID) == d.spaceID
                let tiles = d.tree.windows.map { id in "\(id)@\(d.frames[id].map { "\($0)" } ?? "-")" }
                log.notice("desktop \(d.key.displayUUID, privacy: .public)/\(d.spaceID) visible=\(visible) tiles=\(tiles, privacy: .public) floating=\(d.floating.keys.sorted(), privacy: .public)")
            }
            log.notice("apps=\(self.apps.count) facts=\(self.facts.count) focused=\(String(describing: self.focused), privacy: .public)")
        default:
            log.error("unknown command '\(text, privacy: .public)'")
        }
    }

    // MARK: Config

    func reloadConfig() {
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: Self.configURL.path) {
                try Data(Config.template.utf8).write(to: Self.configURL)
            }
            config = try Config.parse(Data(contentsOf: Self.configURL))
            configError = nil
            hotkeys.configure(hotkeysSuspended ? [:] : config!.hotkeys)
            for d in desktops.values { d.applied.removeAll(); d.needsLayout = true }
        } catch {
            // Keep running with the last good config; with none, nothing tiles.
            configError = (error as? ConfigError)?.description ?? error.localizedDescription
            log.error("config: \(self.configError ?? "")")
        }
        updateHotkeys()
        updateMouseMonitor()
        scheduleReconcile()
        onChange?()
    }

    /// Borrow plain keys while a transient UI is up (see `Hotkeys.borrow`).
    func borrowKeys(_ keys: [(code: UInt32, modifiers: UInt32)], handler: @escaping (Int, Bool) -> Void) {
        hotkeys.borrow(keys, handler: handler)
    }
    func releaseKeys() { hotkeys.release() }

    /// Write a configuration from Settings and apply it. The text is parsed
    /// before it replaces the file, so a bad value can never land on disk.
    func save(_ new: Config) throws {
        let text = new.json()
        _ = try Config.parse(Data(text.utf8))
        try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: Self.configURL, options: .atomic)
        reloadConfig()
    }

    /// Replace the config file with the template.
    func restoreDefaultConfig() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try Data(Config.template.utf8).write(to: Self.configURL, options: .atomic)
        } catch {
            log.error("could not write config: \(error.localizedDescription)")
        }
        reloadConfig()
    }

    // MARK: Unminimize

    /// Bring back every minimized window of the frontmost app (any desktop).
    /// Restored windows land on a tiled desktop's layout through reconcile,
    /// once the Dock's animation has put them back on screen.
    private func unminimizeFrontApp() {
        guard started, let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != myPID else { return }
        let mover = WindowMover(pid: app.processIdentifier)
        mover.unminimizeAll { [weak self] count in
            mover.stop()
            guard let self else { return }
            if count == 0 { NSSound.beep(); return }
            for delay in [0.4, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleReconcile() }
            }
        }
    }

    // MARK: Desktops

    /// The desktop mover is about to drag this window to another desktop.
    func beginDesktopMove(of id: CGWindowID) { movingWindow = id }

    /// The drag is over. `target` is the Space the window landed on, or nil if
    /// it did not move. The window leaves its old desktop's layout (that desktop
    /// lays out again when it is next on screen); a floating window stays
    /// floating, with its frame, if the new desktop is tiled too.
    func endDesktopMove(of id: CGWindowID, pid: pid_t, display: String, to target: SpaceID?) {
        movingWindow = nil
        if let target {
            var floatFrame: CGRect?
            var wasFloating = false
            for d in desktops.values where d.owns(id) || d.floatingFrames[id] != nil {
                if d.floating.removeValue(forKey: id) != nil { wasFloating = true; floatFrame = d.floatingFrames[id] }
                d.floatingFrames[id] = nil
                d.framesToRestore.remove(id)
                if d.tree.contains(id) {
                    d.tree.remove(id)
                    d.applied[id] = nil
                    d.needsLayout = true
                }
            }
            if wasFloating, let t = desktops.values.first(where: { $0.key.displayUUID == display && $0.spaceID == target }) {
                t.floating[id] = pid
                t.floatingFrames[id] = floatFrame
            }
            saveDesktops()
        }
        scheduleReconcile()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scheduleReconcile() }
    }

    /// True when a tiled desktop holds the window in its layout.
    func isTiled(_ id: CGWindowID) -> Bool { desktops.values.contains { $0.tree.contains(id) } }

    /// The tiled desktop currently shown on the display, if any.
    func visibleDesktop(onDisplay uuid: String) -> Desktop? {
        let space = Spaces.current(onDisplay: uuid)
        return desktops.values.first { $0.key.displayUUID == uuid && $0.spaceID == space }
    }

    /// Turn tiling on or off for the desktop showing on the display.
    func toggleDesktop(onDisplay uuid: String) {
        guard started, config != nil else { NSSound.beep(); return }
        let space = Spaces.current(onDisplay: uuid)
        if let d = visibleDesktop(onDisplay: uuid) {
            desktops[d.key] = nil
            log.info("desktop off: \(d.key.spaceUUID)")
        } else {
            guard let info = Spaces.all().first(where: { $0.id == space }), info.number > 0, !info.uuid.isEmpty else {
                NSSound.beep() // fullscreen Spaces are not desktops
                return
            }
            let key = DesktopKey(displayUUID: uuid, spaceUUID: info.uuid)
            desktops[key] = Desktop(key: key, spaceID: space)
            log.info("desktop on: \(info.uuid) (#\(info.number))")
        }
        saveDesktops()
        if desktops.isEmpty { detachAll() } else { attachAll() }
        if let front = NSWorkspace.shared.frontmostApplication { readFocus(of: front) }
        updateHotkeys()
        updateMouseMonitor()
        reconcile()
        onChange?()
    }

    private func saveDesktops() {
        let saved = desktops.values.map { d in
            SavedDesktop(displayUUID: d.key.displayUUID, spaceUUID: d.key.spaceUUID,
                         floating: d.floating.map { SavedDesktop.Window(id: $0.key, pid: $0.value, frame: d.floatingFrames[$0.key]) }
                            .sorted { $0.id < $1.id })
        }.sorted { ($0.displayUUID, $0.spaceUUID) < ($1.displayUUID, $1.spaceUUID) }
        do {
            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: Self.desktopsURL, options: .atomic)
        } catch {
            log.error("could not save desktops: \(error.localizedDescription)")
        }
    }

    private func restoreDesktops() {
        guard let data = try? Data(contentsOf: Self.desktopsURL) else { return }
        // 0.2 and 0.3 wrote a plain list of desktop keys; read that too.
        let saved = (try? JSONDecoder().decode([SavedDesktop].self, from: data))
            ?? ((try? JSONDecoder().decode([DesktopKey].self, from: data)) ?? []).map {
                SavedDesktop(displayUUID: $0.displayUUID, spaceUUID: $0.spaceUUID, floating: [])
            }
        let spaces = Dictionary(Spaces.all().map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        // A floating window is kept only if that window id still exists and still
        // belongs to the same process (ids restart after a logout or reboot).
        var owners: [CGWindowID: pid_t] = [:]
        if saved.contains(where: { !$0.floating.isEmpty }),
           let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                if let id = info[kCGWindowNumber as String] as? CGWindowID, let pid = info[kCGWindowOwnerPID as String] as? pid_t {
                    owners[id] = pid
                }
            }
        }
        var dropped = false
        for entry in saved {
            let key = DesktopKey(displayUUID: entry.displayUUID, spaceUUID: entry.spaceUUID)
            // A desktop deleted in Mission Control is forgotten.
            guard let id = spaces[key.spaceUUID] else { dropped = true; continue }
            let d = Desktop(key: key, spaceID: id)
            for w in entry.floating {
                guard owners[w.id] == w.pid else { dropped = true; continue }
                d.floating[w.id] = w.pid
                if let frame = w.frame {
                    d.floatingFrames[w.id] = frame
                    d.framesToRestore.insert(w.id)
                }
            }
            desktops[key] = d
        }
        if dropped { saveDesktops() }
    }

    /// An app quit: its windows are gone, so they no longer float anywhere.
    private func forgetFloating(of pid: pid_t) {
        var changed = false
        for d in desktops.values {
            let before = d.floating.count
            d.floating = d.floating.filter { $0.value != pid }
            d.floatingFrames = d.floatingFrames.filter { d.floating[$0.key] != nil || d.tree.contains($0.key) }
            changed = changed || d.floating.count != before
        }
        if changed { saveDesktops() }
    }

    private func refreshSpaceIDs() {
        let spaces = Dictionary(Spaces.all().map { ($0.uuid, $0.id) }, uniquingKeysWith: { a, _ in a })
        for d in desktops.values {
            if let id = spaces[d.key.spaceUUID] { d.spaceID = id }
        }
    }

    // MARK: App handles

    private func attachAll() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            attach(app)
        }
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != myPID, apps[pid] == nil, pid > 0 else { return }
        let handle = AppHandle(app: app) { [weak self] event in self?.handle(event) }
        apps[pid] = handle
        handle.start()
    }

    private func detach(_ pid: pid_t) {
        apps.removeValue(forKey: pid)?.stop()
        facts = facts.filter { $0.value.pid != pid }
    }

    private func detachAll() {
        for handle in apps.values { handle.stop() }
        apps.removeAll()
        facts.removeAll()
        resolving.removeAll()
    }

    // MARK: Events

    private func handle(_ event: AppEvent) {
        switch event {
        case .windowCreated(_, let id):
            facts[id] = nil
            scheduleReconcile()
            // Some apps put a new window on screen a little after announcing it.
            for delay in [0.15, 0.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleReconcile() }
            }
        case .windowDestroyed(_, let id):
            facts[id] = nil
            focusHistory.removeAll { $0 == id }
            rechecked.remove(id)
            for d in desktops.values where d.owns(id) {
                d.tree.remove(id)
                d.floatingFrames[id] = nil
                d.framesToRestore.remove(id)
                if d.floating.removeValue(forKey: id) != nil { saveDesktops() }
                d.applied[id] = nil
                layout(d)
            }
        case .windowMinimized:
            scheduleReconcile()
        case .windowMoved(_, let id), .windowResized(_, let id):
            if id == movingWindow { return }
            if let d = desktops.values.first(where: { $0.floating[id] != nil }) { captureFloatingFrame(id, on: d) }
            let tiled = desktops.values.first { $0.tree.contains(id) }
            if userDragging {
                // A user drag: act once the button is released.
                if drag == nil { beginDrag(of: id, on: tiled) }
                return
            }
            // The framed window moved (a layout, the app itself): the frame follows.
            if id == activeBorder.windowID || id == focused?.id { updateBorder() }
            if tiled == nil {
                // Something (a script, the app itself) moved an untiled window:
                // it may have landed on a tiled desktop. The window server updates
                // its Space a moment after the move, so look again shortly.
                scheduleReconcile()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.scheduleReconcile() }
            }
        case .focusChanged(let pid, let id):
            focusChanged(pid: pid, id: id)
        case .subscribed(let pid):
            if pid == NSWorkspace.shared.frontmostApplication?.processIdentifier,
               let app = NSRunningApplication(processIdentifier: pid) { readFocus(of: app) }
            scheduleReconcile()
        }
    }

    /// Ask the app which window has focus; the answer arrives as a focus change.
    private func readFocus(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        focused = (pid, nil)
        apps[pid]?.focusedWindow { [weak self] id in self?.focusChanged(pid: pid, id: id) }
        updateHotkeys()
    }

    private func focusChanged(pid: pid_t, id: CGWindowID?) {
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        focused = (pid, id)
        if let id {
            focusHistory.removeAll { $0 == id }
            focusHistory.insert(id, at: 0)
            if focusHistory.count > 32 { focusHistory.removeLast() }
        }
        if let id, let d = desktops.values.first(where: { $0.tree.contains(id) }) { d.lastFocused = id }
        updateHotkeys()
    }

    // MARK: Reconcile

    func scheduleReconcile() {
        guard !reconcileScheduled, !desktops.isEmpty else { return }
        reconcileScheduled = true
        // A short delay folds bursts of events (an app opening five windows) into one pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.reconcileScheduled = false
            self?.reconcile()
        }
    }

    /// Bring every visible tiled desktop's tree in line with the windows that
    /// are actually on it.
    private func reconcile() {
        guard config != nil, !desktops.isEmpty else { return }
        // A window is in transit to another desktop: wait for it to land.
        if movingWindow != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.scheduleReconcile() }
            return
        }
        let screens = Dictionary(Screen.all().map { ($0.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = desktops.values.filter {
            screens[$0.key.displayUUID] != nil && Spaces.current(onDisplay: $0.key.displayUUID) == $0.spaceID
        }
        // Mid-switch the window list mixes two desktops: wait for the animation to end.
        if visible.contains(where: { Spaces.isAnimating(display: $0.key.displayUUID) }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.scheduleReconcile() }
            return
        }
        guard !visible.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }

        // Ordinary (layer 0), visible windows of other apps, front to back.
        var onScreen: [(id: CGWindowID, pid: pid_t, center: CGPoint)] = []
        for info in list {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.width > 1, bounds.height > 1 else { continue }
            onScreen.append((id, pid, CGPoint(x: bounds.midX, y: bounds.midY)))
        }

        var toResolve: [pid_t: Set<CGWindowID>] = [:]
        for d in visible {
            let screen = screens[d.key.displayUUID]!
            let present = onScreen.filter {
                guard screen.bounds.contains($0.center) else { return false }
                // An empty answer means the window server did not say; the window is
                // on screen on this display, so it is on the visible desktop.
                let spaces = Spaces.of(window: $0.id)
                return spaces.isEmpty || spaces.contains(d.spaceID)
            }
            // During a desktop switch the list can hold both desktops' windows;
            // if the Space changed while reading, the next event redoes it.
            guard Spaces.current(onDisplay: d.key.displayUUID) == d.spaceID else { continue }

            let presentIDs = Set(present.map(\.id))
            var changed = d.needsLayout
            d.needsLayout = false
            for id in d.tree.windows where !presentIDs.contains(id) || isFloatingApp(facts[id]?.pid) {
                d.tree.remove(id)
                d.applied[id] = nil
                changed = true
            }
            // Floating windows are not pruned here: a hidden, minimised or moved
            // window keeps floating. Closed windows and quit apps drop out
            // through the destroyed / terminate events.
            restoreFloatingFrames(on: d, present: presentIDs)

            // A new window splits the window that was active when it opened:
            // the newest focused window, other than itself, already tiled here.
            // Back to front, so the frontmost new window is inserted last.
            for w in present.reversed() where !d.owns(w.id) && !isFloatingApp(w.pid) {
                guard let f = facts[w.id] else {
                    if !resolving.contains(w.id) { toResolve[w.pid, default: []].insert(w.id) }
                    continue
                }
                guard f.tileable else { continue }
                let target = focusHistory.first { $0 != w.id && d.tree.contains($0) }
                    ?? d.lastFocused.flatMap { d.tree.contains($0) ? $0 : nil }
                d.tree.insert(w.id, splitting: target)
                // A new window usually has focus before it joins the tree, and
                // that focus change was not recorded: record it now, so the
                // next new window splits this one.
                if w.id == focused?.id { d.lastFocused = w.id }
                changed = true
            }
            if changed { layout(d) }
        }

        for (pid, ids) in toResolve { resolve(ids, of: pid) }
        updateBorder()
    }

    private func isFloatingApp(_ pid: pid_t?) -> Bool {
        guard let pid, let config, let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return config.floatingApps.contains(bundle)
    }

    private func resolve(_ ids: Set<CGWindowID>, of pid: pid_t) {
        if apps[pid] == nil, let app = NSRunningApplication(processIdentifier: pid) { attach(app) }
        guard let handle = apps[pid] else { return }
        resolving.formUnion(ids)
        handle.resolve(ids) { [weak self] result in
            guard let self else { return }
            resolving.subtract(ids)
            for id in ids {
                let f = result[id] ?? WindowFacts(pid: pid, tileable: false)
                facts[id] = f
                // A window can start out as a non-standard window and become a
                // normal one a moment later: look once more.
                if !f.tileable, rechecked.insert(id).inserted {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.facts[id] = nil
                        self?.scheduleReconcile()
                    }
                }
            }
            reconcile()
        }
    }

    // MARK: Layout

    private func layout(_ d: Desktop) {
        defer { log.debug("layout \(d.spaceID): \(d.frames.map { "\($0.key)=\($0.value)" }, privacy: .public)") }
        guard let config, let screen = Screen.all().first(where: { $0.uuid == d.key.displayUUID }) else { return }
        let area = screen.usable.insetBy(dx: config.outerGap, dy: config.outerGap)
        d.frames = d.tree.layout(in: area, gap: config.innerGap)
        for (id, frame) in d.frames where d.applied[id] != frame {
            guard let pid = facts[id]?.pid, let handle = apps[pid] else { continue }
            handle.setFrame(id, frame)
            d.applied[id] = frame
        }
        // Some apps settle on their own size a moment after the write (minimum
        // sizes, size increments) without a further notification: look once more.
        if activeBorder.windowID != nil || focused?.id.map({ d.owns($0) }) == true, !borderRecheckScheduled {
            borderRecheckScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.borderRecheckScheduled = false
                self?.updateBorder()
            }
        }
    }

    // MARK: Mouse drags

    /// The mouse button is down on a window (title bar or edge), or a
    /// modifier + drag is moving one (its press never reaches the system).
    private var userDragging: Bool { NSEvent.pressedMouseButtons & 1 != 0 || windowDrag.isActive }

    private func beginDrag(of id: CGWindowID, on d: Desktop?) {
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard self?.userDragging == false else { return }
            self?.endDrag()
        }
        RunLoop.main.add(timer, forMode: .common)
        drag = (d?.key, id, timer)
        activeBorder.hide()
    }

    /// A modifier + drag picked up a window. Its moved notifications may come
    /// late, or only after the drop, so the drag starts here rather than there.
    private func windowDragGrabbed(_ id: CGWindowID) {
        guard drag == nil else { return }
        beginDrag(of: id, on: desktops.values.first { $0.tree.contains(id) })
    }

    /// A modifier + drag let go of a window at `point`: the drop is handled now.
    private func windowDragDropped(_ id: CGWindowID, at point: CGPoint) {
        guard drag?.id == id else { return }
        endDrag(at: point)
    }

    /// The user let go of a tiled window: a resized window moves its dividers,
    /// a window dropped onto another tile swaps with it, anything else snaps back.
    private func endDrag(at point: CGPoint? = nil) {
        guard let (key, id, timer) = drag else { return }
        timer.invalidate()
        drag = nil
        // A dragged untiled window may have been dropped onto a tiled desktop.
        guard let key else { scheduleReconcile(); updateBorder(); return }
        let mouse = point ?? CGEvent(source: nil)?.location ?? .zero
        guard let pid = facts[id]?.pid, let handle = apps[pid] else { return }
        handle.frame(of: id) { [weak self] frame in
            guard let self, let config, let d = desktops[key], d.tree.contains(id),
                  let old = d.frames[id], let frame else { return }
            let resized = abs(frame.width - old.width) > 2 || abs(frame.height - old.height) > 2
            if resized {
                d.tree.adoptResize(of: id, to: frame, gap: config.innerGap)
            } else if let target = Geometry.window(at: mouse, in: d.frames), target != id {
                d.tree.swap(id, target)
            } else if !(Screen.all().first { $0.uuid == key.displayUUID }?.bounds.contains(mouse) ?? true) {
                // Dragged to another display: let it go.
                scheduleReconcile()
                return
            }
            d.applied[id] = nil
            layout(d)
            // A window that ends where it already is reports no move.
            updateBorder()
        }
    }

    // MARK: Focus follows mouse

    /// Focus follows mouse is event-driven at rest and bounded while moving:
    /// - At rest a listen-only event tap waits for a mouse-moved event. Listen-
    ///   only taps get copies after delivery, so they never delay input (unlike
    ///   the active keyboard tap HyprMac used), and the tap exists only while the
    ///   setting is on and a desktop is tiled.
    /// - The first move switches the tap off and starts a 40 ms check of the
    ///   pointer position, so a moving mouse costs at most 25 cheap wake-ups a
    ///   second however fast it reports, instead of one per event.
    /// - Once the pointer has not moved for `focusDelay`, the window under it is
    ///   focused if needed, the check stops and the tap is switched back on.
    private let windowDrag = WindowDrag()
    private var mouseTap: CFMachPort?
    private var mouseTapSource: CFRunLoopSource?
    private var trackTimer: Timer?
    private var lastPoint: CGPoint = .zero
    private var lastMove: CFTimeInterval = 0

    private func updateMouseMonitor() {
        // Modifier + drag works on every desktop, tiled or not, once Tiler runs.
        windowDrag.configure(started ? config?.dragToMove : nil)
        let want = started && config?.focusFollowsMouse == true && !desktops.isEmpty
        if want, mouseTap == nil {
            let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                              eventsOfInterest: mask, callback: mouseMovedCallback,
                                              userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                log.error("focus follows mouse: could not create the mouse-moved listener")
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            mouseTap = tap
            mouseTapSource = source
        } else if !want, let tap = mouseTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = mouseTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            mouseTap = nil
            mouseTapSource = nil
            trackTimer?.invalidate()
            trackTimer = nil
        }
    }

    /// The first move after a rest: stop listening, follow the pointer until it rests.
    fileprivate func pointerStartedMoving(at point: CGPoint) {
        guard let tap = mouseTap, trackTimer == nil else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        lastPoint = point
        lastMove = CACurrentMediaTime()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in self?.trackPointer() }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func trackPointer() {
        let now = CACurrentMediaTime()
        if let p = CGEvent(source: nil)?.location, p != lastPoint {
            lastPoint = p
            lastMove = now
            return
        }
        guard now - lastMove >= (config?.focusDelay ?? 0.15) else { return }
        trackTimer?.invalidate()
        trackTimer = nil
        pointerRested()
        if let tap = mouseTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// The system disables a tap it thinks is slow; turn it back on unless a
    /// tracking pass has it off on purpose.
    fileprivate func reenableMouseTap() {
        if let tap = mouseTap, trackTimer == nil { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// The pointer stopped: focus the window under it if it is a window of the
    /// visible tiled desktop there and is not focused already. One window-list
    /// read (about a millisecond); nothing at all when the pointer is elsewhere.
    private func pointerRested() {
        guard NSEvent.pressedMouseButtons == 0, !windowDrag.isActive, drag == nil, transientUIActive?() != true,
              let mouse = CGEvent(source: nil)?.location,
              let screen = Screen.all().first(where: { $0.bounds.contains(mouse) }),
              let d = visibleDesktop(onDisplay: screen.uuid),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        // An open menu (any app's, or a contextual menu), the app switcher or a
        // similar system overlay: leave focus alone so it is not dismissed.
        if list.contains(where: { ($0[kCGWindowLayer as String] as? Int ?? 0) >= Int(CGWindowLevelForKey(.popUpMenuWindow))
                                  && $0[kCGWindowOwnerName as String] as? String != "Window Server" }) { return }
        // Ordinary windows above the one under the pointer (front to back).
        var above: [CGRect] = []
        for info in list {
            guard let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            guard bounds.contains(mouse) else {
                if info[kCGWindowLayer as String] as? Int == 0 { above.append(bounds) }
                continue
            }
            // The cursor and the Dock's full-screen window sit above everything.
            let owner = info[kCGWindowOwnerName as String] as? String
            if owner == "Window Server" || owner == "Dock" { continue }
            // The topmost real window decides. A menu, popover or panel on top
            // (any layer but 0) blocks, so an open menu is never closed.
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  d.owns(id), id != focused?.id else { return }
            // A window partly covered by another (a floating or other untiled
            // window: tiles never overlap) gets focus without being raised,
            // so it never covers that window.
            if above.contains(where: { $0.intersects(bounds.insetBy(dx: 1, dy: 1)) }) {
                if let pid = facts[id]?.pid { apps[pid]?.focusWithoutRaise(id) }
            } else {
                focus(id)
            }
            return
        }
    }

    // MARK: Hotkeys

    /// The display the user is working on: the one holding the focused
    /// window, or the one under the mouse when no window has focus.
    func activeDisplay() -> String? {
        let screens = Screen.all()
        if let id = focused?.id,
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
           let b = info[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b),
           let screen = screens.first(where: { $0.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }) {
            return screen.uuid
        }
        guard let mouse = CGEvent(source: nil)?.location else { return nil }
        return screens.first { $0.bounds.contains(mouse) }?.uuid
    }

    /// The tiled desktop the keyboard is working on, and its focused window
    /// when Tiler manages that window.
    private func keyboardContext() -> (Desktop, CGWindowID?)? {
        guard let display = activeDisplay(), let d = visibleDesktop(onDisplay: display) else { return nil }
        let id = focused?.id
        return (d, id.flatMap { d.owns($0) ? $0 : nil })
    }

    private func updateHotkeys() {
        guard started else { return }
        hotkeys.activate(tilingKeys: config != nil && keyboardContext() != nil)
        updateBorder()
        onChange?()
    }

    // MARK: Active window frame

    private let activeBorder = ActiveBorder()

    /// Frame the focused window when it belongs to a visible tiled desktop
    /// (tile or floating) and is on screen; otherwise no frame. Also off while
    /// a window is being dragged; the drop's layout brings it back.
    private func updateBorder() {
        borderGeneration &+= 1
        guard started, let config, config.activeBorder != nil, drag == nil, !windowDrag.isActive,
              let id = focused?.id,
              let d = desktops.values.first(where: { $0.owns(id) }),
              Spaces.current(onDisplay: d.key.displayUUID) == d.spaceID,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let b = info[kCGWindowBounds as String] as? NSDictionary,
              let listed = CGRect(dictionaryRepresentation: b)
        else { activeBorder.hide(); return }
        // The window-server list can lag a moment behind a resize the app has
        // already reported (a window closed, its neighbour grows): take the
        // frame from the app itself, read after any frame Tiler is writing.
        let generation = borderGeneration
        let show: (CGRect) -> Void = { [weak self] frame in
            guard let self, generation == borderGeneration, let config = self.config, let rgb = config.activeBorder else { return }
            activeBorder.show(around: id, frame: frame, color: NSColor(rgb: rgb), width: config.activeBorderWidth)
        }
        guard let pid = facts[id]?.pid, let handle = apps[pid] else { show(listed); return }
        handle.frame(of: id) { frame in show(frame ?? listed) }
    }

    /// Bumped by every `updateBorder`, so a slower answer never overrides a newer one.
    private var borderGeneration = 0
    private var borderRecheckScheduled = false

    private func perform(_ action: Action) {
        log.debug("action \(action.rawValue, privacy: .public)")
        switch action {
        case .toggleDesktop:
            if let display = activeDisplay() { toggleDesktop(onDisplay: display) }
            return
        case .showHotkeys:
            onShowHotkeys?()
            return
        case .moveResize:
            onMoveResize?()
            return
        case .windowToPreviousDesktop, .windowToNextDesktop:
            onMoveToDesktop?(action == .windowToNextDesktop)
            return
        case .windowToPointerDisplay:
            onMoveToPointerDisplay?()
            return
        case .unminimizeAll:
            unminimizeFrontApp()
            return
        default:
            break
        }
        guard let config, let (d, focusedID) = keyboardContext() else { return }
        let id = focusedID.flatMap { d.tree.contains($0) ? $0 : nil }

        switch action {
        case .focusLeft, .focusRight, .focusUp, .focusDown:
            let target = id.flatMap { Geometry.neighbor(of: $0, direction(action), in: d.frames) }
                ?? (id == nil ? (d.lastFocused.flatMap { d.tree.contains($0) ? $0 : nil } ?? d.tree.windows.first) : nil)
            if let target { focus(target) }
        case .swapLeft, .swapRight, .swapUp, .swapDown:
            guard let id, let other = Geometry.neighbor(of: id, direction(action), in: d.frames) else { return }
            d.tree.swap(id, other)
            layout(d)
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown:
            guard let id, d.tree.moveDivider(of: id, direction(action), step: config.resizeStep) else { return }
            layout(d)
        case .toggleFloat:
            guard let fid = focusedID else { return }
            if d.tree.contains(fid) {
                d.tree.remove(fid)
                d.applied[fid] = nil
                d.floating[fid] = facts[fid]?.pid ?? focused?.pid
                layout(d)
                // Back where it last floated, if that is still on this display;
                // otherwise centred.
                if let frame = d.floatingFrames[fid], frameFits(frame, on: d),
                   let pid = d.floating[fid], let handle = apps[pid] {
                    handle.setFrame(fid, frame)
                } else {
                    centerFloating(fid, on: d)
                }
                saveDesktops()
            } else if d.floating.removeValue(forKey: fid) != nil {
                d.tree.insert(fid, splitting: d.lastFocused.flatMap { d.tree.contains($0) ? $0 : nil })
                d.lastFocused = fid
                layout(d)
                saveDesktops()
            }
        case .toggleSplit:
            guard let id else { return }
            d.tree.toggleOrientation(of: id)
            layout(d)
        case .mirror:
            d.tree.mirrorHorizontally()
            layout(d)
        case .equalize:
            d.tree.equalize()
            layout(d)
        case .retile:
            d.applied.removeAll()
            facts = facts.filter { $0.value.tileable }
            rechecked.removeAll()
            layout(d)
            reconcile()
        case .toggleDesktop, .showHotkeys, .moveResize, .unminimizeAll, .windowToPreviousDesktop, .windowToNextDesktop,
             .windowToPointerDisplay:
            break
        }
    }

    private func direction(_ action: Action) -> Direction {
        switch action {
        case .focusLeft, .swapLeft, .resizeLeft: return .left
        case .focusRight, .swapRight, .resizeRight: return .right
        case .focusUp, .swapUp, .resizeUp: return .up
        default: return .down
        }
    }

    private func focus(_ id: CGWindowID) {
        guard let pid = facts[id]?.pid else { return }
        apps[pid]?.focus(id)
    }

    /// A window set floating is centred at 60% of the usable area, so it is
    /// obvious that it left the tiling.
    private func centerFloating(_ id: CGWindowID, on d: Desktop) {
        guard let pid = facts[id]?.pid, let screen = Screen.all().first(where: { $0.uuid == d.key.displayUUID }) else { return }
        let u = screen.usable
        let size = CGSize(width: (u.width * 0.6).rounded(), height: (u.height * 0.6).rounded())
        let frame = CGRect(x: (u.midX - size.width / 2).rounded(), y: (u.midY - size.height / 2).rounded(),
                           width: size.width, height: size.height)
        apps[pid]?.setFrame(id, frame)
        d.floatingFrames[id] = frame
    }

    /// True when most of the frame lies on the desktop's display (a display
    /// may have been unplugged or rearranged since the frame was saved).
    private func frameFits(_ frame: CGRect, on d: Desktop) -> Bool {
        guard let screen = Screen.all().first(where: { $0.uuid == d.key.displayUUID }) else { return false }
        let visible = frame.intersection(screen.bounds)
        return !visible.isNull && visible.width * visible.height >= 0.5 * frame.width * frame.height
    }

    // MARK: Floating frames

    private var captureWork: [CGWindowID: DispatchWorkItem] = [:]
    private var saveWork: DispatchWorkItem?

    /// A floating window moved or changed size (a drag, the move/resize mode,
    /// the app itself): read its frame once things settle, then save.
    private func captureFloatingFrame(_ id: CGWindowID, on d: Desktop) {
        captureWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak d] in
            guard let self, let d, let pid = d.floating[id], let handle = self.apps[pid] else { return }
            self.captureWork[id] = nil
            handle.frame(of: id) { [weak self, weak d] frame in
                guard let self, let d, let frame, d.floating[id] != nil, d.floatingFrames[id] != frame else { return }
                d.floatingFrames[id] = frame
                d.framesToRestore.remove(id)
                self.scheduleSave()
            }
        }
        captureWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// After a restart: put restored floating windows back at their saved frame
    /// (once), and register them with their app's handle so later moves are
    /// seen. Only windows on screen on this desktop right now.
    private func restoreFloatingFrames(on d: Desktop, present: Set<CGWindowID>) {
        let due = d.framesToRestore.intersection(present)
        guard !due.isEmpty else { return }
        d.framesToRestore.subtract(due)
        var byApp: [pid_t: Set<CGWindowID>] = [:]
        for id in due { if let pid = d.floating[id] { byApp[pid, default: []].insert(id) } }
        for (pid, ids) in byApp {
            if apps[pid] == nil, let app = NSRunningApplication(processIdentifier: pid) { attach(app) }
            guard let handle = apps[pid] else { continue }
            handle.resolve(ids) { [weak self, weak d] result in
                guard let self, let d else { return }
                for id in ids {
                    if let f = result[id] { self.facts[id] = f }
                    guard d.floating[id] != nil, let frame = d.floatingFrames[id], self.frameFits(frame, on: d) else { continue }
                    handle.setFrame(id, frame)
                }
            }
        }
    }

    /// Coalesce bursts of frame changes into one write.
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveDesktops() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// Mouse-moved listener (main run loop): hands the first move to the controller.
private func mouseMovedCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<Controller>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenableMouseTap()
    } else {
        controller.pointerStartedMoving(at: event.location)
    }
    return Unmanaged.passUnretained(event)
}
