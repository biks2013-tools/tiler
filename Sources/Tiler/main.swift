import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = Controller()
    private var menu: StatusMenu?
    private var overlay: ShortcutsOverlay?
    private var moveResize: MoveResizeMode?
    private var desktopMover: DesktopMover?
    private var settings: SettingsWindowController?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let menu = StatusMenu(controller: controller)
        let overlay = ShortcutsOverlay(controller: controller)
        let moveResize = MoveResizeMode(controller: controller)
        self.menu = menu
        self.overlay = overlay
        self.moveResize = moveResize
        menu.onShowShortcuts = { moveResize.end(); overlay.toggle() }
        menu.onMoveResize = { overlay.close(); moveResize.toggle() }
        controller.onMoveResize = { overlay.close(); moveResize.toggle() }
        let desktopMover = DesktopMover(controller: controller)
        self.desktopMover = desktopMover
        controller.onMoveToDesktop = { forward in overlay.close(); moveResize.end(); desktopMover.move(forward: forward) }
        controller.onMoveToPointerDisplay = { overlay.close(); moveResize.end(); desktopMover.moveToPointerDisplay() }
        menu.onShowSettings = { [weak self] pane in self?.showSettings(pane) }
        controller.onShowHotkeys = { moveResize.end(); overlay.toggle() }
        controller.onShowSettings = { [weak self] in self?.showSettings(nil) }
        controller.transientUIActive = { overlay.isShown || moveResize.isActive }
        controller.onChange = { [weak self] in
            self?.menu?.refreshIcon()
            self?.settings?.model.refresh()
        }
        // Bound every AX call: a hung app can cost at most a second, never a freeze.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
        controller.prepare()

        if AXIsProcessTrusted() {
            controller.start()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.controller.start()
                self?.settings?.model.refresh()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open -a Tiler`) shows Settings,
    /// the usual behaviour of a menu bar app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }

    func showSettings(_ pane: SettingsWindowController.Pane? = nil) {
        if settings == nil { settings = SettingsWindowController(controller: controller) }
        settings?.show(pane)
    }

    @objc private func showSettingsFromMenu(_ sender: Any?) { showSettings(nil) }

    static func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Tiles one desktop at a time, only where you turn it on.",
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                             .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func about(_ sender: Any?) { Self.showAbout() }

    /// A menu bar app has no visible main menu, but the Settings window still
    /// needs the standard key equivalents (⌘W, ⌘Q, ⌘C/⌘V in text, ⌘,).
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            holder.submenu = m
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu("Tiler", [
            item("About Tiler", #selector(about(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettingsFromMenu(_:)), ","),
            .separator(),
            item("Quit Tiler", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return main
    }
}

func send(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.giorgosmarinos.tiler.command"), object: command,
        userInfo: nil, deliverImmediately: true)
}

// `Tiler --send "<command>"` forwards a command to the running instance and exits.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--send" {
    send(CommandLine.arguments[2])
    exit(0)
}

// One instance only: two would fight over the same windows. Launching again
// opens Settings in the running instance.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
    send("settings")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
