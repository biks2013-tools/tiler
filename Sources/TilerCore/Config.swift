import Foundation

/// Everything a hotkey can trigger.
public enum Action: String, CaseIterable, Codable {
    case toggleDesktop
    case focusLeft, focusRight, focusUp, focusDown
    case swapLeft, swapRight, swapUp, swapDown
    case resizeLeft, resizeRight, resizeUp, resizeDown
    case toggleFloat
    case toggleSplit
    case mirror
    case equalize
    case retile
    case showHotkeys
    case moveResize
    case unminimizeAll
    case windowToPreviousDesktop, windowToNextDesktop
    case windowToPointerDisplay

    /// `toggleDesktop`, `showHotkeys` and `moveResize` stay registered on desktops
    /// Tiler does not tile; every other hotkey is released there so apps keep the key.
    public var worksOnUntiledDesktop: Bool {
        switch self {
        case .toggleDesktop, .showHotkeys, .moveResize, .unminimizeAll, .windowToPreviousDesktop, .windowToNextDesktop,
             .windowToPointerDisplay: return true
        default: return false
        }
    }

    /// What the action does, as shown in the shortcuts overlay and Settings.
    public var title: String {
        switch self {
        case .toggleDesktop: return "Tile or untile this desktop"
        case .showHotkeys: return "Show keyboard shortcuts"
        case .moveResize: return "Move or resize an untiled window"
        case .unminimizeAll: return "Unminimize the app's windows"
        case .windowToPreviousDesktop: return "Move window to previous desktop"
        case .windowToNextDesktop: return "Move window to next desktop"
        case .windowToPointerDisplay: return "Move window to the screen under the pointer"
        case .focusLeft: return "Focus left"
        case .focusRight: return "Focus right"
        case .focusUp: return "Focus up"
        case .focusDown: return "Focus down"
        case .swapLeft: return "Swap left"
        case .swapRight: return "Swap right"
        case .swapUp: return "Swap up"
        case .swapDown: return "Swap down"
        case .resizeLeft: return "Move vertical divider left"
        case .resizeRight: return "Move vertical divider right"
        case .resizeUp: return "Move horizontal divider up"
        case .resizeDown: return "Move horizontal divider down"
        case .toggleFloat: return "Float or tile window"
        case .toggleSplit: return "Flip split direction"
        case .mirror: return "Mirror left and right"
        case .equalize: return "Equalize splits"
        case .retile: return "Retile desktop"
        }
    }

    public enum Group: String, CaseIterable {
        case general = "General", desktops = "Desktops", focus = "Focus", swap = "Swap", resize = "Resize", layout = "Layout"
    }

    public var group: Group {
        switch self {
        case .toggleDesktop, .showHotkeys, .moveResize, .unminimizeAll: return .general
        case .windowToPreviousDesktop, .windowToNextDesktop, .windowToPointerDisplay: return .desktops
        case .focusLeft, .focusRight, .focusUp, .focusDown: return .focus
        case .swapLeft, .swapRight, .swapUp, .swapDown: return .swap
        case .resizeLeft, .resizeRight, .resizeUp, .resizeDown: return .resize
        case .toggleFloat, .toggleSplit, .mirror, .equalize, .retile: return .layout
        }
    }
}

/// A key plus modifiers, in Carbon terms (virtual key code, modifier mask).
public struct KeyCombo: Hashable, CustomStringConvertible {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let text: String

    // Carbon modifier bits (HIToolbox/Events.h).
    public static let cmdKey: UInt32 = 0x0100
    public static let shiftKey: UInt32 = 0x0200
    public static let optionKey: UInt32 = 0x0800
    public static let controlKey: UInt32 = 0x1000

    public var description: String { text }

    /// A combination from a key event (used by the shortcut recorder). Nil when
    /// the key is not one Tiler can bind or no modifier is held.
    public init?(keyCode: UInt32, carbonModifiers: UInt32) {
        let mods = carbonModifiers & (Self.cmdKey | Self.shiftKey | Self.optionKey | Self.controlKey)
        guard mods != 0, let name = Self.keyNames[keyCode] else { return nil }
        self.init(keyCode: keyCode, carbonModifiers: mods, text: Self.canonical(name: name, mods: mods))
    }

    private init(keyCode: UInt32, carbonModifiers: UInt32, text: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.text = text
    }

    /// The config-file spelling, modifiers in macOS order: "ctrl+alt+shift+cmd+key".
    public var canonicalText: String { Self.canonical(name: Self.keyNames[keyCode] ?? "?", mods: carbonModifiers) }

    /// The macOS spelling, e.g. "⌃⌘←".
    public var symbols: String { modifierSymbols + keySymbol }

    public var modifierSymbols: String { Self.symbols(modifiers: carbonModifiers) }

    /// "⌃⌥⇧⌘" for a Carbon modifier mask, in macOS order.
    public static func symbols(modifiers: UInt32) -> String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s
    }

    /// "ctrl+alt+shift+cmd" for a Carbon modifier mask (the config spelling).
    public static func text(modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & controlKey != 0 { parts.append("ctrl") }
        if modifiers & optionKey != 0 { parts.append("alt") }
        if modifiers & shiftKey != 0 { parts.append("shift") }
        if modifiers & cmdKey != 0 { parts.append("cmd") }
        return parts.joined(separator: "+")
    }

    public var keySymbol: String {
        let name = Self.keyNames[keyCode] ?? "?"
        switch name {
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "return": return "↩"
        case "tab": return "⇥"
        case "space": return "Space"
        case "delete": return "⌫"
        case "escape": return "⎋"
        default: return name.uppercased()
        }
    }

    private static func canonical(name: String, mods: UInt32) -> String {
        mods == 0 ? name : text(modifiers: mods) + "+" + name
    }

    public static func == (a: KeyCombo, b: KeyCombo) -> Bool {
        a.keyCode == b.keyCode && a.carbonModifiers == b.carbonModifiers
    }
    public func hash(into h: inout Hasher) { h.combine(keyCode); h.combine(carbonModifiers) }

    /// Parse "ctrl+alt+shift+left". Throws on unknown parts or no modifier.
    public static func parse(_ raw: String) throws -> KeyCombo {
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let keyName = parts.last, !keyName.isEmpty else { throw ConfigError.badHotkey(raw, "empty") }
        var mods: UInt32 = 0
        for part in parts.dropLast() {
            guard let bit = modifierBits[part] else { throw ConfigError.badHotkey(raw, "unknown modifier '\(part)'") }
            mods |= bit
        }
        guard mods != 0 else { throw ConfigError.badHotkey(raw, "needs at least one modifier") }
        guard let code = keyCodes[keyName] else { throw ConfigError.badHotkey(raw, "unknown key '\(keyName)'") }
        return KeyCombo(keyCode: code, carbonModifiers: mods, text: raw)
    }

    static let modifierBits: [String: UInt32] = [
        "cmd": cmdKey, "command": cmdKey, "shift": shiftKey,
        "alt": optionKey, "opt": optionKey, "option": optionKey, "ctrl": controlKey, "control": controlKey,
    ]

    /// ANSI virtual key codes (HIToolbox/Events.h, kVK_*).
    static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "escape": 0x35,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "f13": 0x69, "f14": 0x6B, "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F,
        "f19": 0x50, "f20": 0x5A,
    ]

    /// Key code → canonical name ("enter" is an alias of "return").
    static let keyNames: [UInt32: String] = Dictionary(
        keyCodes.filter { $0.key != "enter" }.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
}

public enum ConfigError: Error, CustomStringConvertible, Equatable {
    case unreadable(String)
    case missingKey(String)
    case badValue(String, String)
    case badHotkey(String, String)
    case unknownKey(String)
    case duplicateHotkey(String)

    public var description: String {
        switch self {
        case .unreadable(let why): return "config unreadable: \(why)"
        case .missingKey(let key): return "config is missing required key '\(key)'"
        case .badValue(let key, let why): return "config key '\(key)': \(why)"
        case .badHotkey(let raw, let why): return "hotkey '\(raw)': \(why)"
        case .unknownKey(let key): return "config has unknown key '\(key)'"
        case .duplicateHotkey(let raw): return "hotkey '\(raw)' is bound to more than one action"
        }
    }
}

/// Tiler's settings. Every key is required: a missing key is an error, never
/// silently replaced by a default. The first launch writes `Config.template`
/// to disk so the user starts from a complete file.
public struct Config: Equatable {
    /// Points between neighbouring tiles.
    public let innerGap: Double
    /// Points between the tiles and the screen's usable edges.
    public let outerGap: Double
    /// Share of a split moved by one resize keypress (0.01...0.5).
    public let resizeStep: Double
    /// Bundle identifiers whose windows always float.
    public let floatingApps: Set<String>
    /// Action → key combination. Actions set to "none" are unbound.
    public let hotkeys: [Action: KeyCombo]
    /// Focus the window under the mouse on tiled desktops once the pointer rests.
    public let focusFollowsMouse: Bool
    /// How long the pointer must rest before focus follows it (0.05...1 s).
    public let focusDelay: Double
    /// The modifiers (Carbon mask) that, held while pressing the mouse button,
    /// drag the window under the pointer from anywhere in it. Nil = off.
    public let dragToMove: UInt32?
    /// Colour (0xRRGGBB) of the frame drawn around the active window on tiled
    /// desktops. Nil = no frame.
    public let activeBorder: UInt32?
    /// Width of that frame in points (1...12).
    public let activeBorderWidth: Double

    public init(innerGap: Double, outerGap: Double, resizeStep: Double, floatingApps: Set<String>, hotkeys: [Action: KeyCombo],
                focusFollowsMouse: Bool, focusDelay: Double, dragToMove: UInt32?,
                activeBorder: UInt32?, activeBorderWidth: Double) {
        self.dragToMove = dragToMove
        self.activeBorder = activeBorder
        self.activeBorderWidth = activeBorderWidth
        self.focusFollowsMouse = focusFollowsMouse
        self.focusDelay = focusDelay
        self.innerGap = innerGap
        self.outerGap = outerGap
        self.resizeStep = resizeStep
        self.floatingApps = floatingApps
        self.hotkeys = hotkeys
    }

    /// The settings of `template`.
    public static let defaults: Config = try! parse(Data(template.utf8))

    /// The bindings that clash with `combo` (other than `action` itself).
    public func conflicts(_ combo: KeyCombo, for action: Action) -> [Action] {
        hotkeys.filter { $0.key != action && $0.value == combo }.map(\.key)
    }

    /// The config file text: every key, in a stable order, so Settings can
    /// write it back and the file stays readable and diffable.
    public func json() -> String {
        func num(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        func str(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let apps = floatingApps.sorted().map { "    \(str($0))" }.joined(separator: ",\n")
        let keys = Action.allCases.map { "    \(str($0.rawValue)): \(str(hotkeys[$0]?.canonicalText ?? "none"))" }
            .joined(separator: ",\n")
        return """
        {
          "innerGap": \(num(innerGap)),
          "outerGap": \(num(outerGap)),
          "resizeStep": \(num(resizeStep)),
          "focusFollowsMouse": \(focusFollowsMouse),
          "focusDelay": \(num(focusDelay)),
          "dragToMove": \(str(dragToMove.map { KeyCombo.text(modifiers: $0) } ?? "none")),
          "activeBorder": \(str(activeBorder.map(Self.colorText) ?? "none")),
          "activeBorderWidth": \(num(activeBorderWidth)),
          "floatingApps": [\(apps.isEmpty ? "" : "\n" + apps + "\n  ")],
          "hotkeys": {
        \(keys)
          }
        }

        """
    }

    /// The file text with every missing setting added from the template, for the
    /// explicit "Add Missing Settings" action in Settings after an upgrade adds
    /// settings or actions. Values already in the file are never changed, and the
    /// result is parsed before it is returned, so any other error still surfaces.
    public static func addingMissingSettings(to data: Data) throws -> (text: String, added: [String]) {
        guard var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ConfigError.unreadable("not a JSON object")
        }
        let template = try JSONSerialization.jsonObject(with: Data(Self.template.utf8)) as! [String: Any]
        var added: [String] = []
        for key in topLevelKeys.sorted() where dict[key] == nil {
            dict[key] = template[key]
            added.append(key)
        }
        if var keys = dict["hotkeys"] as? [String: String] {
            let defaults = template["hotkeys"] as! [String: String]
            for action in Action.allCases where keys[action.rawValue] == nil {
                keys[action.rawValue] = defaults[action.rawValue]
                added.append("hotkeys.\(action.rawValue)")
            }
            dict["hotkeys"] = keys
        }
        let merged = try parse(try JSONSerialization.data(withJSONObject: dict))
        return (merged.json(), added)
    }

    public static let topLevelKeys: Set<String> = ["innerGap", "outerGap", "resizeStep", "focusFollowsMouse", "focusDelay",
                                                   "dragToMove", "activeBorder", "activeBorderWidth", "floatingApps", "hotkeys"]

    /// "#RRGGBB" for a 0xRRGGBB colour.
    public static func colorText(_ rgb: UInt32) -> String { String(format: "#%06X", rgb & 0xFFFFFF) }

    /// Parse the `activeBorder` value: "none", or a colour "#RRGGBB".
    public static func parseColor(_ raw: String) throws -> UInt32? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.lowercased() == "none" { return nil }
        guard text.count == 7, text.hasPrefix("#"), let v = UInt32(text.dropFirst(), radix: 16) else {
            throw ConfigError.badValue("activeBorder", "must be a colour such as \"#90EE90\", or \"none\"")
        }
        return v
    }

    /// Parse the `dragToMove` value: "none", or modifiers such as "alt+cmd".
    /// Shift alone is refused: shift-click extends selections everywhere.
    public static func parseDragModifiers(_ raw: String) throws -> UInt32? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if text == "none" { return nil }
        var mods: UInt32 = 0
        for part in text.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let bit = KeyCombo.modifierBits[part] else {
                throw ConfigError.badValue("dragToMove", "unknown modifier '\(part)' (use ctrl, alt, shift, cmd, or \"none\")")
            }
            mods |= bit
        }
        guard mods & (KeyCombo.cmdKey | KeyCombo.optionKey | KeyCombo.controlKey) != 0 else {
            throw ConfigError.badValue("dragToMove", "needs cmd, alt or ctrl (or \"none\")")
        }
        return mods
    }

    public static func parse(_ data: Data) throws -> Config {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch {
            throw ConfigError.unreadable("not valid JSON (\(error.localizedDescription))")
        }
        guard let dict = object as? [String: Any] else { throw ConfigError.unreadable("top level must be an object") }
        for key in dict.keys where !topLevelKeys.contains(key) { throw ConfigError.unknownKey(key) }

        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double {
            guard let raw = dict[key] else { throw ConfigError.missingKey(key) }
            guard let n = raw as? NSNumber, !(raw is Bool) else { throw ConfigError.badValue(key, "must be a number") }
            let v = n.doubleValue
            guard range.contains(v) else { throw ConfigError.badValue(key, "must be within \(range.lowerBound)...\(range.upperBound)") }
            return v
        }

        let inner = try number("innerGap", 0...200)
        guard let rawFollow = dict["focusFollowsMouse"] else { throw ConfigError.missingKey("focusFollowsMouse") }
        guard let follow = rawFollow as? Bool, CFGetTypeID(rawFollow as CFTypeRef) == CFBooleanGetTypeID() else {
            throw ConfigError.badValue("focusFollowsMouse", "must be true or false")
        }
        let delay = try number("focusDelay", 0.05...1)
        guard let rawDrag = dict["dragToMove"] else { throw ConfigError.missingKey("dragToMove") }
        guard let dragText = rawDrag as? String else { throw ConfigError.badValue("dragToMove", "must be a string such as \"alt+cmd\" or \"none\"") }
        let drag = try parseDragModifiers(dragText)
        guard let rawBorder = dict["activeBorder"] else { throw ConfigError.missingKey("activeBorder") }
        guard let borderText = rawBorder as? String else {
            throw ConfigError.badValue("activeBorder", "must be a string such as \"#90EE90\" or \"none\"")
        }
        let border = try parseColor(borderText)
        let borderWidth = try number("activeBorderWidth", 1...12)
        let outer = try number("outerGap", 0...400)
        let step = try number("resizeStep", 0.01...0.5)

        guard let rawApps = dict["floatingApps"] else { throw ConfigError.missingKey("floatingApps") }
        guard let apps = rawApps as? [String] else { throw ConfigError.badValue("floatingApps", "must be an array of bundle identifiers") }

        guard let rawKeys = dict["hotkeys"] else { throw ConfigError.missingKey("hotkeys") }
        guard let keys = rawKeys as? [String: String] else { throw ConfigError.badValue("hotkeys", "must map action names to strings") }
        for name in keys.keys where Action(rawValue: name) == nil { throw ConfigError.unknownKey("hotkeys.\(name)") }
        var hotkeys: [Action: KeyCombo] = [:]
        var seen: Set<KeyCombo> = []
        for action in Action.allCases {
            guard let raw = keys[action.rawValue] else { throw ConfigError.missingKey("hotkeys.\(action.rawValue)") }
            if raw.lowercased() == "none" { continue }
            let combo = try KeyCombo.parse(raw)
            guard seen.insert(combo).inserted else { throw ConfigError.duplicateHotkey(raw) }
            hotkeys[action] = combo
        }
        return Config(innerGap: inner, outerGap: outer, resizeStep: step, floatingApps: Set(apps), hotkeys: hotkeys,
                      focusFollowsMouse: follow, focusDelay: delay, dragToMove: drag,
                      activeBorder: border, activeBorderWidth: borderWidth)
    }

    /// The file written on first launch. Edit it and choose "Reload Config".
    public static let template = """
    {
      "innerGap": 8,
      "outerGap": 8,
      "resizeStep": 0.05,
      "focusFollowsMouse": false,
      "focusDelay": 0.15,
      "dragToMove": "alt+cmd",
      "activeBorder": "#90EE90",
      "activeBorderWidth": 4,
      "floatingApps": [
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.calculator"
      ],
      "hotkeys": {
        "toggleDesktop": "ctrl+cmd+p",
        "focusLeft": "ctrl+cmd+left",
        "focusRight": "ctrl+cmd+right",
        "focusUp": "ctrl+cmd+up",
        "focusDown": "ctrl+cmd+down",
        "swapLeft": "ctrl+cmd+shift+left",
        "swapRight": "ctrl+cmd+shift+right",
        "swapUp": "ctrl+cmd+shift+up",
        "swapDown": "ctrl+cmd+shift+down",
        "resizeLeft": "ctrl+cmd+[",
        "resizeRight": "ctrl+cmd+]",
        "resizeUp": "ctrl+cmd+shift+[",
        "resizeDown": "ctrl+cmd+shift+]",
        "toggleFloat": "ctrl+cmd+t",
        "toggleSplit": "ctrl+cmd+j",
        "mirror": "ctrl+cmd+shift+j",
        "equalize": "ctrl+cmd+e",
        "retile": "ctrl+cmd+r",
        "showHotkeys": "ctrl+cmd+/",
        "moveResize": "ctrl+cmd+m",
        "unminimizeAll": "alt+cmd+m",
        "windowToPreviousDesktop": "ctrl+cmd+,",
        "windowToNextDesktop": "ctrl+cmd+.",
        "windowToPointerDisplay": "ctrl+cmd+h"
      }
    }

    """
}
