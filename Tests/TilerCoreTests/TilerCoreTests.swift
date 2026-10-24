import XCTest
@testable import TilerCore

final class BSPTreeTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testSingleWindowFillsTheArea() {
        let t = BSPTree()
        t.insert(1, splitting: nil)
        XCTAssertEqual(t.layout(in: screen, gap: 10)[1], screen)
    }

    func testDwindleSplitsTheLongerSideOfTheTarget() {
        let t = BSPTree()
        t.insert(1, splitting: nil)
        _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        var f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 500, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 600))
        // Window 2 is taller than wide now: splitting it stacks vertically.
        t.insert(3, splitting: 2)
        f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[2], CGRect(x: 500, y: 0, width: 500, height: 300))
        XCTAssertEqual(f[3], CGRect(x: 500, y: 300, width: 500, height: 300))
    }

    func testGapSeparatesTiles() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 10)
        t.insert(2, splitting: 1)
        let f = t.layout(in: screen, gap: 10)
        XCTAssertEqual(f[1]!.maxX + 10, f[2]!.minX)
    }

    func testRemovePromotesSibling() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1); _ = t.layout(in: screen, gap: 0)
        t.insert(3, splitting: 2); _ = t.layout(in: screen, gap: 0)
        t.remove(2)
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[3], CGRect(x: 500, y: 0, width: 500, height: 600))
        XCTAssertEqual(t.windows, [1, 3])
        t.remove(1); t.remove(3)
        XCTAssertTrue(t.isEmpty)
    }

    func testInsertWithoutTargetSplitsLastLeaf() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 99); _ = t.layout(in: screen, gap: 0)
        XCTAssertEqual(t.windows, [1, 2])
    }

    func testSwapExchangesPositions() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        t.swap(1, 2)
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[2]!.minX, 0)
        XCTAssertEqual(t.windows, [2, 1])
        t.remove(1)
        XCTAssertEqual(t.windows, [2])
    }

    func testMoveDividerPrefersTheSideOfTheArrow() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        XCTAssertTrue(t.moveDivider(of: 1, .right, step: 0.1))
        XCTAssertEqual(t.layout(in: screen, gap: 0)[1]!.width, 600)
        // Window 2 has no divider on its right: its left divider moves right.
        XCTAssertTrue(t.moveDivider(of: 2, .right, step: 0.1))
        XCTAssertEqual(t.layout(in: screen, gap: 0)[1]!.width, 700)
        XCTAssertFalse(t.moveDivider(of: 2, .up, step: 0.1))
    }

    func testRatioIsClamped() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        for _ in 0..<20 { t.moveDivider(of: 1, .right, step: 0.1) }
        XCTAssertEqual(t.layout(in: screen, gap: 0)[1]!.width, 900)
    }

    func testMirrorKeepsWidths() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        t.moveDivider(of: 1, .right, step: 0.2)
        t.mirrorHorizontally()
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[1], CGRect(x: 300, y: 0, width: 700, height: 600))
        XCTAssertEqual(f[2], CGRect(x: 0, y: 0, width: 300, height: 600))
    }

    func testToggleOrientationAndEqualize() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 0)
        t.insert(2, splitting: 1)
        t.moveDivider(of: 1, .right, step: 0.2)
        t.toggleOrientation(of: 2)
        t.equalize()
        let f = t.layout(in: screen, gap: 0)
        XCTAssertEqual(f[1], CGRect(x: 0, y: 0, width: 1000, height: 300))
    }

    func testAdoptResizeFollowsTheDraggedEdge() {
        let t = BSPTree()
        t.insert(1, splitting: nil); _ = t.layout(in: screen, gap: 10)
        t.insert(2, splitting: 1)
        let before = t.layout(in: screen, gap: 10)
        var dragged = before[1]!
        dragged.size.width += 100
        XCTAssertTrue(t.adoptResize(of: 1, to: dragged, gap: 10))
        let after = t.layout(in: screen, gap: 10)
        XCTAssertEqual(after[1]!.maxX, dragged.maxX, accuracy: 1)
        XCTAssertEqual(after[2]!.minX, dragged.maxX + 10, accuracy: 1)
        // A pure move changes nothing.
        XCTAssertFalse(t.adoptResize(of: 1, to: after[1]!, gap: 10))
    }
}

final class GeometryTests: XCTestCase {
    func testNeighborPrefersOverlappingTiles() {
        let frames: [WindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 500, height: 600),
            2: CGRect(x: 500, y: 0, width: 500, height: 300),
            3: CGRect(x: 500, y: 300, width: 500, height: 300),
        ]
        XCTAssertEqual(Geometry.neighbor(of: 3, .left, in: frames), 1)
        XCTAssertEqual(Geometry.neighbor(of: 3, .up, in: frames), 2)
        XCTAssertNil(Geometry.neighbor(of: 3, .down, in: frames))
        XCTAssertNil(Geometry.neighbor(of: 1, .left, in: frames))
        XCTAssertEqual(Geometry.neighbor(of: 1, .right, in: frames), 2) // tie on gap; closer centre wins → both equal, lower id
    }

    func testWindowAtPoint() {
        let frames: [WindowID: CGRect] = [1: CGRect(x: 0, y: 0, width: 10, height: 10)]
        XCTAssertEqual(Geometry.window(at: CGPoint(x: 5, y: 5), in: frames), 1)
        XCTAssertNil(Geometry.window(at: CGPoint(x: 50, y: 5), in: frames))
    }
}

final class ConfigTests: XCTestCase {
    func testTemplateParses() throws {
        let c = try Config.parse(Data(Config.template.utf8))
        XCTAssertEqual(c.innerGap, 8)
        XCTAssertEqual(c.hotkeys.count, Action.allCases.count)
        XCTAssertEqual(c.hotkeys[.focusLeft], try KeyCombo.parse("cmd+ctrl+left"))
    }

    func testMissingKeyIsAnError() {
        var dict = try! JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict.removeValue(forKey: "outerGap")
        let data = try! JSONSerialization.data(withJSONObject: dict)
        XCTAssertThrowsError(try Config.parse(data)) { XCTAssertEqual($0 as? ConfigError, .missingKey("outerGap")) }
    }

    func testMissingHotkeyIsAnErrorButNoneUnbinds() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys["mirror"] = "none"
        dict["hotkeys"] = keys
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(c.hotkeys[.mirror])
        keys.removeValue(forKey: "mirror")
        dict["hotkeys"] = keys
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
    }

    func testBadHotkeysAreRejected() {
        XCTAssertThrowsError(try KeyCombo.parse("left"))
        XCTAssertThrowsError(try KeyCombo.parse("hyper+left"))
        XCTAssertThrowsError(try KeyCombo.parse("ctrl+banana"))
    }

    func testDuplicateHotkeyIsRejected() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys["mirror"] = "ctrl+cmd+left"
        dict["hotkeys"] = keys
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
    }

    func testUnknownKeyIsRejected() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict["gapz"] = 3
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
    }

    func testJSONRoundTrips() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys["mirror"] = "none"
        keys["retile"] = "cmd+alt+\\"
        dict["hotkeys"] = keys
        dict["innerGap"] = 4.5
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        let again = try Config.parse(Data(c.json().utf8))
        XCTAssertEqual(again, c)
        XCTAssertEqual(Config.defaults, try Config.parse(Data(Config.defaults.json().utf8)))
    }

    func testComboFromKeyEvent() throws {
        let combo = try XCTUnwrap(KeyCombo(keyCode: 0x7B, carbonModifiers: KeyCombo.cmdKey | KeyCombo.controlKey))
        XCTAssertEqual(combo.canonicalText, "ctrl+cmd+left")
        XCTAssertEqual(combo.symbols, "⌃⌘←")
        XCTAssertEqual(combo, try KeyCombo.parse("cmd+ctrl+left"))
        XCTAssertNil(KeyCombo(keyCode: 0x7B, carbonModifiers: 0))
        XCTAssertNil(KeyCombo(keyCode: 0xFF, carbonModifiers: KeyCombo.cmdKey))
    }

    func testDesktopMovesWorkEverywhereWithDefaults() throws {
        let c = Config.defaults
        XCTAssertEqual(c.hotkeys[.windowToPreviousDesktop], try KeyCombo.parse("ctrl+cmd+,"))
        XCTAssertEqual(c.hotkeys[.windowToNextDesktop]?.symbols, "⌃⌘.")
        XCTAssertTrue(Action.windowToNextDesktop.worksOnUntiledDesktop)
        XCTAssertFalse(Action.focusLeft.worksOnUntiledDesktop)
        XCTAssertEqual(Action.windowToPreviousDesktop.group, .desktops)
    }

    func testWindowToPointerDisplayDefaults() throws {
        XCTAssertEqual(Config.defaults.hotkeys[.windowToPointerDisplay]?.symbols, "⌃⌘H")
        XCTAssertTrue(Action.windowToPointerDisplay.worksOnUntiledDesktop)
        XCTAssertEqual(Action.windowToPointerDisplay.group, .desktops)
    }

    func testPlaceOnAnotherDisplay() {
        let big = CGRect(x: 0, y: 25, width: 2560, height: 1415)
        let small = CGRect(x: 2560, y: 25, width: 1512, height: 957)
        // Top-left corner stays top-left; size kept when it fits.
        XCTAssertEqual(Geometry.place(CGRect(x: 0, y: 25, width: 800, height: 600), from: big, to: small),
                       CGRect(x: 2560, y: 25, width: 800, height: 600))
        // Centred (to the pixel) stays centred.
        XCTAssertEqual(Geometry.place(CGRect(x: 880, y: 432, width: 800, height: 600), from: big, to: small),
                       CGRect(x: 2916, y: 203, width: 800, height: 600))
        // Too big: shrunk to the target's usable area.
        XCTAssertEqual(Geometry.place(CGRect(x: 8, y: 33, width: 2544, height: 1399), from: big, to: small), small)
        // Unknown source: centred.
        XCTAssertEqual(Geometry.place(CGRect(x: -5000, y: 0, width: 512, height: 357), from: nil, to: small),
                       CGRect(x: 3060, y: 325, width: 512, height: 357))
    }

    func testUnminimizeWorksEverywhereWithDefaults() {
        XCTAssertEqual(Config.defaults.hotkeys[.unminimizeAll]?.symbols, "⌥⌘M")
        XCTAssertTrue(Action.unminimizeAll.worksOnUntiledDesktop)
        XCTAssertEqual(Action.unminimizeAll.group, .general)
    }

    func testConflicts() {
        let c = Config.defaults
        XCTAssertEqual(c.conflicts(c.hotkeys[.retile]!, for: .equalize), [.retile])
        XCTAssertEqual(c.conflicts(c.hotkeys[.retile]!, for: .retile), [])
    }
}

final class WindowNudgeTests: XCTestCase {
    let area = CGRect(x: 0, y: 30, width: 1000, height: 600)

    func testMoveStaysInside() {
        let f = CGRect(x: 10, y: 40, width: 300, height: 200)
        XCTAssertEqual(WindowNudge.apply(.move(.right), to: f, in: area, step: 40), CGRect(x: 50, y: 40, width: 300, height: 200))
        XCTAssertEqual(WindowNudge.apply(.move(.left), to: f, in: area, step: 40).minX, 0)
        XCTAssertEqual(WindowNudge.apply(.move(.up), to: f, in: area, step: 40).minY, 30)
        let atRight = CGRect(x: 690, y: 40, width: 300, height: 200)
        XCTAssertEqual(WindowNudge.apply(.move(.right), to: atRight, in: area, step: 40).maxX, 1000)
    }

    func testResizeAnchorsTopLeftAndClamps() {
        let f = CGRect(x: 100, y: 100, width: 300, height: 200)
        XCTAssertEqual(WindowNudge.apply(.resize(.right), to: f, in: area, step: 40), CGRect(x: 100, y: 100, width: 340, height: 200))
        XCTAssertEqual(WindowNudge.apply(.resize(.up), to: f, in: area, step: 40), CGRect(x: 100, y: 100, width: 300, height: 160))
        let tiny = CGRect(x: 100, y: 100, width: 170, height: 110)
        XCTAssertEqual(WindowNudge.apply(.resize(.left), to: tiny, in: area, step: 40).size, CGSize(width: 160, height: 110))
        XCTAssertEqual(WindowNudge.apply(.resize(.up), to: tiny, in: area, step: 40).size, CGSize(width: 170, height: 100))
        let wide = CGRect(x: 600, y: 100, width: 380, height: 200)
        let grown = WindowNudge.apply(.resize(.right), to: wide, in: area, step: 40)
        XCTAssertEqual(grown.maxX, 1000)
        XCTAssertEqual(grown.width, 420)
    }

    func testCenterAndMaximize() {
        let f = CGRect(x: 0, y: 30, width: 400, height: 200)
        XCTAssertEqual(WindowNudge.apply(.center, to: f, in: area, step: 0), CGRect(x: 300, y: 230, width: 400, height: 200))
        XCTAssertEqual(WindowNudge.apply(.maximize, to: f, in: area, step: 0), area)
    }
}

final class ConfigUpgradeTests: XCTestCase {
    func testMissingHotkeysAreAddedFromTheTemplate() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        var keys = dict["hotkeys"] as! [String: String]
        keys.removeValue(forKey: "moveResize")
        keys["mirror"] = "none"
        dict["hotkeys"] = keys
        dict["innerGap"] = 12
        let old = try JSONSerialization.data(withJSONObject: dict)
        XCTAssertThrowsError(try Config.parse(old))
        let (text, added) = try Config.addingMissingSettings(to: old)
        XCTAssertEqual(added, ["hotkeys.moveResize"])
        let c = try Config.parse(Data(text.utf8))
        XCTAssertEqual(c.innerGap, 12)
        XCTAssertNil(c.hotkeys[.mirror])
        XCTAssertEqual(c.hotkeys[.moveResize], try KeyCombo.parse("ctrl+cmd+m"))
    }

    func testMissingTopLevelSettingsAreAdded() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict.removeValue(forKey: "focusFollowsMouse")
        dict.removeValue(forKey: "focusDelay")
        dict["outerGap"] = 20
        let (text, added) = try Config.addingMissingSettings(to: try JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(added, ["focusDelay", "focusFollowsMouse"])
        let c = try Config.parse(Data(text.utf8))
        XCTAssertEqual(c.outerGap, 20)
        XCTAssertFalse(c.focusFollowsMouse)
        XCTAssertEqual(c.focusDelay, 0.15)
    }

    func testOtherErrorsStillSurface() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict["outerGap"] = "wide"
        XCTAssertThrowsError(try Config.addingMissingSettings(to: try JSONSerialization.data(withJSONObject: dict)))
    }

    func testFocusFollowsMouseMustBeABoolean() throws {
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        dict["focusFollowsMouse"] = 1
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
        dict["focusFollowsMouse"] = true
        dict["focusDelay"] = 2
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
        dict["focusDelay"] = 0.3
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        XCTAssertTrue(c.focusFollowsMouse)
        XCTAssertEqual(try Config.parse(Data(c.json().utf8)), c)
    }

    func testDragToMoveModifiers() throws {
        XCTAssertEqual(Config.defaults.dragToMove, KeyCombo.optionKey | KeyCombo.cmdKey)
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        for bad: Any in ["shift", "cmd+hyper", "", true] {
            dict["dragToMove"] = bad
            XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)), "\(bad)")
        }
        dict["dragToMove"] = "none"
        XCTAssertNil(try Config.parse(try JSONSerialization.data(withJSONObject: dict)).dragToMove)
        dict["dragToMove"] = "cmd+ctrl"
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(c.dragToMove, KeyCombo.controlKey | KeyCombo.cmdKey)
        XCTAssertTrue(c.json().contains("\"dragToMove\": \"ctrl+cmd\""))
        XCTAssertEqual(try Config.parse(Data(c.json().utf8)), c)
        dict["dragToMove"] = nil
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
        let upgraded = try Config.addingMissingSettings(to: try JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(upgraded.added, ["dragToMove"])
    }

    func testActiveBorder() throws {
        XCTAssertEqual(Config.defaults.activeBorder, 0x90EE90)
        XCTAssertEqual(Config.defaults.activeBorderWidth, 4)
        var dict = try JSONSerialization.jsonObject(with: Data(Config.template.utf8)) as! [String: Any]
        for bad: Any in ["green", "#12345", "#1234567", "#GGHHII", "", 5, true] {
            dict["activeBorder"] = bad
            XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)), "\(bad)")
        }
        dict["activeBorder"] = "none"
        XCTAssertNil(try Config.parse(try JSONSerialization.data(withJSONObject: dict)).activeBorder)
        dict["activeBorder"] = "#a6e3a1"
        for bad: Any in [0, 13, "4", true] {
            dict["activeBorderWidth"] = bad
            XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)), "\(bad)")
        }
        dict["activeBorderWidth"] = 6
        let c = try Config.parse(try JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(c.activeBorder, 0xA6E3A1)
        XCTAssertTrue(c.json().contains("\"activeBorder\": \"#A6E3A1\""))
        XCTAssertTrue(c.json().contains("\"activeBorderWidth\": 6"))
        XCTAssertEqual(try Config.parse(Data(c.json().utf8)), c)
        dict["activeBorder"] = nil
        dict["activeBorderWidth"] = nil
        XCTAssertThrowsError(try Config.parse(try JSONSerialization.data(withJSONObject: dict)))
        let upgraded = try Config.addingMissingSettings(to: try JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(upgraded.added, ["activeBorder", "activeBorderWidth"])
    }
}

