import AppKit
import TilerCore

/// The menu bar item. Its menu acts on the display whose menu bar was clicked,
/// so "Tile This Desktop" always means the desktop right under the pointer.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: Controller
    private let menu = NSMenu()
    var onShowShortcuts: (() -> Void)?
    var onMoveResize: (() -> Void)?
    var onShowSettings: ((SettingsWindowController.Pane?) -> Void)?

    init(controller: Controller) {
        self.controller = controller
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.toolTip = "Tiler"
        refreshIcon()
    }

    /// Filled glyph when the desktop being worked on is tiled.
    func refreshIcon() {
        let tiled = controller.activeDisplay().flatMap { controller.visibleDesktop(onDisplay: $0) } != nil
        item.button?.image = Appearance.statusImage(tiled: tiled)
        item.button?.appearsDisabled = controller.config == nil
    }

    /// The display whose menu bar holds the item that was clicked.
    private var clickedDisplay: (uuid: String, name: String)? {
        guard let screen = item.button?.window?.screen ?? NSScreen.main, let uuid = screen.displayUUID else { return nil }
        return (uuid, screen.localizedName)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hotkeys = controller.config?.hotkeys ?? [:]

        if !AXIsProcessTrusted() {
            add("Allow Accessibility Access…", "exclamationmark.triangle", #selector(openAccessibility))
            menu.addItem(.separator())
        }
        if controller.configError != nil {
            add("Configuration Error…", "exclamationmark.triangle", #selector(openSettingsGeneral))
                .toolTip = controller.configError
            menu.addItem(.separator())
        }

        if let display = clickedDisplay {
            let space = Spaces.current(onDisplay: display.uuid)
            let number = Spaces.all().first { $0.id == space }?.number ?? 0
            let tiled = controller.visibleDesktop(onDisplay: display.uuid) != nil
            menu.addItem(.sectionHeader(title: number > 0 ? "Desktop \(number) · \(display.name)" : display.name))
            let toggle = add(number > 0 ? "Tile This Desktop" : "Full-Screen Space Can’t Be Tiled", nil, #selector(toggleDesktop))
            toggle.state = tiled ? .on : .off
            toggle.isEnabled = number > 0 && controller.config != nil && controller.started
            toggle.representedObject = display.uuid
            toggle.show(hotkeys[.toggleDesktop])
        }
        let others = controller.desktops.count - (clickedDisplay.flatMap { controller.visibleDesktop(onDisplay: $0.uuid) } == nil ? 0 : 1)
        if others > 0 {
            let line = add("\(others) other desktop\(others == 1 ? "" : "s") tiled", nil, nil)
            line.isEnabled = false
        }

        let move = add("Move or Resize Window", "arrow.up.and.down.and.arrow.left.and.right", #selector(moveResizeWindow))
        move.show(hotkeys[.moveResize])
        move.isEnabled = controller.started
        move.toolTip = "Move or resize the focused window with the keyboard (not a tiled one)"

        let follow = add("Focus Follows Mouse", "cursorarrow.rays", #selector(toggleFocusFollowsMouse))
        follow.state = controller.config?.focusFollowsMouse == true ? .on : .off
        follow.isEnabled = controller.config != nil && controller.configError == nil
        follow.toolTip = "On tiled desktops, focus the window under the pointer when it rests"

        menu.addItem(.separator())
        add("Keyboard Shortcuts", "keyboard", #selector(showShortcuts)).show(hotkeys[.showHotkeys])
        let settings = add("Settings…", "gearshape", #selector(openSettings))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(.separator())
        add("About Tiler", nil, #selector(showAbout))
        let quit = add("Quit Tiler", nil, #selector(NSApplication.terminate(_:)), target: NSApp)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
    }

    @discardableResult
    private func add(_ title: String, _ symbol: String?, _ action: Selector?, target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = target ?? self
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(mi)
        return mi
    }

    @objc private func toggleDesktop(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        controller.toggleDesktop(onDisplay: uuid)
    }

    @objc private func showShortcuts() {
        // Let the menu finish closing first, so the overlay can take the keyboard.
        DispatchQueue.main.async { self.onShowShortcuts?() }
    }

    @objc private func moveResizeWindow() {
        DispatchQueue.main.async { self.onMoveResize?() }
    }

    @objc private func toggleFocusFollowsMouse() {
        guard let c = controller.config else { return }
        do {
            try controller.save(Config(innerGap: c.innerGap, outerGap: c.outerGap, resizeStep: c.resizeStep,
                                       floatingApps: c.floatingApps, hotkeys: c.hotkeys,
                                       focusFollowsMouse: !c.focusFollowsMouse, focusDelay: c.focusDelay,
                                       dragToMove: c.dragToMove, activeBorder: c.activeBorder,
                                       activeBorderWidth: c.activeBorderWidth))
        } catch {
            log.error("could not save config: \(error.localizedDescription)")
            NSSound.beep()
        }
    }

    @objc private func openSettings() { onShowSettings?(nil) }
    @objc private func openSettingsGeneral() { onShowSettings?(.general) }

    @objc private func showAbout() { AppDelegate.showAbout() }

    @objc private func openAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}
