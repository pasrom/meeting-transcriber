#!/usr/bin/env swift
// Drives the speaker-naming dialog of the running dev app from OUTSIDE the
// process, through the Accessibility API and real WindowServer keystrokes.
//
// Why this exists next to the System Events path the --naming-escape lane
// uses. The naming window is deliberately off the in-process /ui/press and
// /ui/type allowlists (it shows speaker names, which are PII), so a lane that
// has to type into it must do so the way a person does: focus a field, post
// key events. System Events can do that, but only with TWO grants, Automation
// and Accessibility, and Automation is bound to the exact process context the
// runner service happens to have; measured on the CI mini, no context reachable
// from an SSH shell (a plain shell, a launchd agent in the GUI domain, a
// launchd agent replaying the runner's own bash -> node chain) can send it an
// AppleEvent without raising a consent prompt nobody is there to answer. The
// AX API and CGEventPost need only Accessibility, which the same host grants to
// the SSH shell, so a lane built on them can be run by hand over SSH and in CI
// with one grant instead of two. System Events posts its keystrokes through
// the same CGEvent path; this is the same keystroke with one fewer intermediary.
//
// Usage: drive-naming-field.swift <command> [--bundle-id ID] [--identifier AXID] [--text T]
//   trusted                        exit 0 if this process may use Accessibility, 3 if not
//   windows                        list the app's windows and every AXIdentifier under them
//   focus  --identifier AXID       bring the app to front and make AXID the focused element
//   type   --identifier AXID --text T
//                                  verify AXID is focused, post one keystroke per character
//                                  to the app, then print the field's value as read back
//   read   --identifier AXID       print the element's AX value
//   press  --identifier AXID       perform AXPress on the element (buttons)
//   select-job --index N           pick the Nth meeting (0-based) in the naming window's job menu
//
// Output is `key=value` lines. Exit codes: 0 ok, 2 usage, 3 not trusted,
// 4 app not running, 5 element not found, 6 focus or frontmost verification
// failed (nothing is typed in that case), 7 the app terminated while being typed
// into, 8 an AX call failed.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Arguments

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

func usage() -> Never {
    FileHandle.standardError.write(Data(
        "usage: drive-naming-field.swift trusted|windows|tree|focus|type|read|press|select-job [--bundle-id ID] [--identifier AXID] [--text T] [--index N]\n".utf8,
    ))
    exit(2)
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(code)
}

guard CommandLine.arguments.count >= 2 else { usage() }
let command = CommandLine.arguments[1]
let bundleID = argument("--bundle-id") ?? "app.meetingtranscriber.dev"
let identifier = argument("--identifier")
let text = argument("--text")

// MARK: - Accessibility helpers

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// Depth-first walk over the accessibility tree under `root`, bounded so a
/// pathological tree cannot spin forever.
func walk(_ root: AXUIElement, _ visit: (AXUIElement, Int) -> Bool) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    while let (element, depth) = stack.popLast(), visited < 20000 {
        visited += 1
        guard visit(element, depth) else { return }
        if depth < 40 {
            for child in children(element).reversed() {
                stack.append((child, depth + 1))
            }
        }
    }
}

func windows(of app: AXUIElement) -> [AXUIElement] {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

/// The identifier of the element the app reports as focused. AppKit may report
/// the field editor (an AXTextArea with no identifier of its own) rather than
/// the text field it edits, so the nearest identified ancestor counts.
func focusedIdentifier(in app: AXUIElement) -> String? {
    guard let focused = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
    // swiftlint:disable:next force_cast
    var element = focused as! AXUIElement
    for _ in 0 ..< 4 {
        if let id = string(element, kAXIdentifierAttribute), !id.isEmpty { return id }
        guard let parent = attribute(element, kAXParentAttribute) else { return nil }
        // swiftlint:disable:next force_cast
        element = parent as! AXUIElement
    }
    return nil
}

/// The first element under any of the app's windows whose AXIdentifier is `id`,
/// together with the window it lives in.
func find(identifier id: String, in app: AXUIElement) -> (AXUIElement, AXUIElement)? {
    for window in windows(of: app) {
        var found: AXUIElement?
        walk(window) { element, _ in
            if string(element, kAXIdentifierAttribute) == id {
                found = element
                return false
            }
            return true
        }
        if let found { return (found, window) }
    }
    return nil
}

// MARK: - Commands

if command == "trusted" {
    let trusted = AXIsProcessTrusted()
    print("trusted=\(trusted)")
    exit(trusted ? 0 : 3)
}

guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    fail(4, "no running application with bundle id \(bundleID)")
}
let pid = running.processIdentifier
let app = AXUIElementCreateApplication(pid)
print("pid=\(pid)")

switch command {
case "windows":
    for window in windows(of: app) {
        print("window=\(string(window, kAXTitleAttribute) ?? "")")
        walk(window) { element, _ in
            if let id = string(element, kAXIdentifierAttribute), !id.isEmpty {
                print("identifier=\(id) role=\(string(element, kAXRoleAttribute) ?? "")")
            }
            return true
        }
    }

case "tree":
    // Diagnostic: role/subrole/title/value/identifier for every element under
    // each window. Not used by the lane; kept for inspecting the AX shape of a
    // control the lane needs to drive (e.g. the job picker).
    for window in windows(of: app) {
        print("window=\(string(window, kAXTitleAttribute) ?? "")")
        walk(window) { element, depth in
            let role = string(element, kAXRoleAttribute) ?? ""
            let subrole = string(element, kAXSubroleAttribute) ?? ""
            let title = string(element, kAXTitleAttribute) ?? ""
            let value = string(element, kAXValueAttribute) ?? ""
            let id = string(element, kAXIdentifierAttribute) ?? ""
            print(String(repeating: "  ", count: depth)
                + "role=\(role) subrole=\(subrole) title=\(title.prefix(30)) value=\(value.prefix(20)) id=\(id)")
            return true
        }
    }

case "select-job":
    // Select the Nth entry (0-based) of the naming window's job picker, a
    // SwiftUI menu Picker (AXPopUpButton), by pressing it open and then
    // pressing the menu item. Used to switch between two still-pending naming
    // jobs without resolving either. Found by its identifier
    // (`A11yID.namingJobPicker`); the naming view holds no other pop-up
    // button, so the first one in the "Name Speakers" window is the fallback
    // if the identifier does not reach the AX element, or lands on a wrapping
    // element rather than the pop-up itself. Other windows (Settings) have
    // pop-ups of their own, so the fallback does not look there.
    guard let idxStr = argument("--index"), let idx = Int(idxStr) else { usage() }
    let popUpRole = kAXPopUpButtonRole as String
    var picker = find(identifier: "naming-job-picker", in: app)
        .map(\.0)
        .flatMap { string($0, kAXRoleAttribute) == popUpRole ? $0 : nil }
    for window in windows(of: app) where picker == nil && string(window, kAXTitleAttribute) == "Name Speakers" {
        walk(window) { element, _ in
            if string(element, kAXRoleAttribute) == popUpRole {
                picker = element
                return false
            }
            return true
        }
    }
    guard let picker else { fail(5, "no job picker (pop-up button) found in any window") }
    // The menu's items, exposed as AXMenu > AXMenuItem under the pop-up only
    // while the menu is open; empty while it is closed.
    func menuItems() -> [AXUIElement] {
        children(picker)
            .filter { string($0, kAXRoleAttribute) == (kAXMenuRole as String) }
            .flatMap { children($0) }
            .filter { string($0, kAXRoleAttribute) == (kAXMenuItemRole as String) }
    }
    // Polls every 0.1 s until the menu is open (`true`) or closed (`false`),
    // for at most `seconds`; returns the items seen last.
    func awaitMenu(open: Bool, within seconds: Double) -> [AXUIElement] {
        // A wall-clock deadline, not a sum of sleeps: an AX read can block
        // while the app tracks the menu, and the bound must still hold.
        let deadline = Date().addingTimeInterval(seconds)
        var items = menuItems()
        while items.isEmpty == open, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            items = menuItems()
        }
        return items
    }
    // Closes an open menu the way AX offers it: the pop-up itself has only
    // AXPress, the items carry AXCancel (the pop-up answers AXCancel with
    // "action unsupported" and the menu stays).
    func cancelMenu(via item: AXUIElement) {
        _ = AXUIElementPerformAction(item, kAXCancelAction as CFString)
    }
    // Waits until no menu is exposed under the pop-up, cancelling one that
    // lingers. After an item press the menu stays exposed for about 350 ms
    // (measured at 50 ms steps on one machine, macOS 27.2, whether or not the
    // entry was already the one shown), and the lane's next call arrives
    // within that window. The selection survives the cancel (the dialog keeps
    // the newly chosen job's fields).
    func ensureMenuClosed(_ when: String) {
        let lingering = awaitMenu(open: false, within: 1.0)
        guard !lingering.isEmpty else { return }
        cancelMenu(via: lingering[0])
        guard awaitMenu(open: false, within: 1.0).isEmpty else {
            fail(8, "the job picker's menu stayed open \(when); the next press would be swallowed")
        }
    }
    // Press the pop-up only while its menu is closed. AXPress on an OPEN
    // pop-up removes the menu from the tree but leaves the picker deaf to
    // further presses (about 3 s after a lingering post-selection menu,
    // indefinitely after a fully opened one, until an Escape key reaches the
    // app), which is what "menu has 0 items" then reports. So the same
    // invariant holds at entry as at exit: whatever an earlier call left
    // exposed is closed first, then the menu is opened afresh.
    ensureMenuClosed("before entry \(idx) could be selected")
    // `.cannotComplete` has not been observed here; it is tolerated rather
    // than failed because the items polled below are the check that the menu
    // opened, so a press that did nothing fails there.
    let opened = AXUIElementPerformAction(picker, kAXPressAction as CFString)
    guard opened == .success || opened == .cannotComplete else {
        fail(8, "AXPress on the job picker failed: \(opened.rawValue)")
    }
    // The menu is built when it opens; give it a moment to appear.
    let items = awaitMenu(open: true, within: 2.0)
    guard !items.isEmpty else {
        fail(5, "the job picker's menu did not open: no menu items appeared under the pop-up within 2 s of pressing it")
    }
    guard idx >= 0, idx < items.count else {
        cancelMenu(via: items[0])
        fail(5, "job index \(idx) out of range (menu has \(items.count) items)")
    }
    // `.cannotComplete` as on the open press; here the lane's entry count and
    // labels are the check.
    let result = AXUIElementPerformAction(items[idx], kAXPressAction as CFString)
    guard result == .success || result == .cannotComplete else {
        cancelMenu(via: items[0])
        fail(8, "AXPress on menu item \(idx) failed: \(result.rawValue)")
    }
    // Leave the menu closed for the next call.
    ensureMenuClosed("after selecting entry \(idx)")
    print("selected-job=\(idx) of=\(items.count)")

case "read":
    guard let id = identifier else { usage() }
    guard let (element, _) = find(identifier: id, in: app) else { fail(5, "no element with identifier \(id)") }
    print("value=\(string(element, kAXValueAttribute) ?? "")")

case "press":
    guard let id = identifier else { usage() }
    guard let (element, _) = find(identifier: id, in: app) else { fail(5, "no element with identifier \(id)") }
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { fail(8, "AXPress on \(id) failed: \(result.rawValue)") }
    print("pressed=\(id)")

case "focus", "type":
    guard let id = identifier else { usage() }
    if command == "type", text == nil { usage() }
    guard let (element, window) = find(identifier: id, in: app) else { fail(5, "no element with identifier \(id)") }

    if command == "focus" {
        // Front the app and raise its window through AX (what System Events'
        // `set frontmost to true` does), then hand the field focus. A process
        // outside the GUI session cannot rely on NSRunningApplication.activate.
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard result == .success else { fail(8, "could not focus \(id): AXError \(result.rawValue)") }
    }

    // Verify before anything is typed: the app must be frontmost and the
    // target field must be what the app reports as focused. Posting keystrokes
    // on a wrong guess would type into another application, or into another
    // row of this dialog, and read as a product defect.
    var frontmost = false
    var focusedID: String?
    for _ in 0 ..< 20 {
        frontmost = (attribute(app, kAXFrontmostAttribute) as? Bool) ?? false
        focusedID = focusedIdentifier(in: app)
        if frontmost, focusedID == id { break }
        usleep(100_000)
    }
    print("frontmost=\(frontmost)")
    print("focused=\(focusedID ?? "")")
    guard frontmost else { fail(6, "the app is not frontmost; refusing to post keystrokes") }
    guard focusedID == id else { fail(6, "focused element is '\(focusedID ?? "")', expected \(id); refusing to post keystrokes") }

    if command == "type", let text {
        // One real key event per character, delivered to the app's event queue.
        // The unicode string carries the character, so no keyboard-layout
        // lookup is needed; the app's field editor turns the keyDown into
        // insertText and NSControl.textDidChange, exactly as a typed key does.
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            var units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { fail(8, "could not create key events") }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.postToPid(pid)
            usleep(15000)
            up.postToPid(pid)
            usleep(60000)
        }
        print("typed=\(text)")

        // Give the app a moment to process, then check it is still there. The
        // defect this drives (issue #700) is a trap on the first keystroke, and
        // a dead app must be reported as that rather than as an AX read error.
        usleep(500_000)
        if running.isTerminated || kill(pid, 0) != 0 {
            fail(7, "the application terminated while being typed into")
        }
        guard let (after, _) = find(identifier: id, in: app) else {
            fail(7, "element \(id) is gone after typing; the application may have terminated")
        }
        print("value=\(string(after, kAXValueAttribute) ?? "")")
    }

default:
    usage()
}
