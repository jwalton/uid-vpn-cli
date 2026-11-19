// uid-vpn: toggle the Ubiquiti UID Enterprise one-click VPN from the command line.
//
// The UID app has no CLI or URL hook for the VPN, so this drives its menu-bar
// popover: it clicks the status item, finds the VPN row in the popover via the
// Accessibility API, and clicks the switch on the right side of that row.
//
// Requires Accessibility permission for the terminal app running it.
//
// Build: swiftc -O -o ~/.local/bin/uid-vpn ~/.local/bin/uid-vpn.swift
// Usage: uid-vpn on|off|toggle|status

import AppKit
import ApplicationServices
import Foundation

let bundleID = "com.ui.uid.desktop"
let vpnProcessNames = ["UIOvpnClient"]

func fail(_ msg: String) -> Never {
    restoreFocus()
    FileHandle.standardError.write("uid-vpn: \(msg)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Focus

/// The app (and its focused window) that was frontmost before we started clicking, so that
/// focus can be handed back afterwards; clicking the UID menu-bar icon activates UID.
struct SavedFocus {
    let app: NSRunningApplication
    let window: AXUIElement?
}

var savedFocus: SavedFocus?

func saveFocus() {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    savedFocus = SavedFocus(app: app, window: attr(axApp, "AXFocusedWindow").map { $0 as! AXUIElement })
}

func restoreFocus() {
    guard let saved = savedFocus else { return }
    savedFocus = nil
    let axApp = AXUIElementCreateApplication(saved.app.processIdentifier)
    AXUIElementSetAttributeValue(axApp, "AXFrontmost" as CFString, kCFBooleanTrue)
    if let w = saved.window {
        AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, "AXRaise" as CFString)
    }
    if NSWorkspace.shared.frontmostApplication != saved.app {
        saved.app.activate()
    }
}

// MARK: - VPN state

func isConnected() -> Bool {
    for name in vpnProcessNames {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 { return true }
    }
    return false
}

func waitFor(_ timeout: TimeInterval, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        usleep(200_000)
    }
    return cond()
}

// MARK: - Accessibility helpers

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func str(_ e: AXUIElement, _ a: String) -> String { attr(e, a) as? String ?? "" }

func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, "AXChildren") as? [AXUIElement] ?? [] }

func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, "AXPosition"), let s = attr(e, "AXSize") else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

func descendants(_ e: AXUIElement) -> [AXUIElement] {
    children(e).flatMap { [$0] + descendants($0) }
}

func click(_ p: CGPoint) {
    let orig = CGEvent(source: nil)?.location
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(50_000)
    }
    if let orig = orig {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: orig, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

// MARK: - UID popover

struct UID {
    let pid: pid_t
    let statusItem: CGRect

    var iconCenter: CGPoint { CGPoint(x: statusItem.midX, y: statusItem.midY) }

    /// The popover isn't listed among the app's windows, so find it by hit-testing just below the icon.
    func popover() -> AXUIElement? {
        var el: AXUIElement?
        let probe = CGPoint(x: statusItem.midX, y: statusItem.maxY + 15)
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(probe.x), Float(probe.y), &el) == .success,
              var e = el else { return nil }
        while true {
            var p: pid_t = 0
            AXUIElementGetPid(e, &p)
            if p != pid { return nil }
            if str(e, "AXRole") == "AXPopover" { return e }
            guard let parent = attr(e, "AXParent") else { return nil }
            e = parent as! AXUIElement
        }
    }

    func openPopover() -> AXUIElement {
        if let p = popover() { return p }
        click(iconCenter)
        var found: AXUIElement?
        _ = waitFor(3) { found = popover(); return found != nil }
        guard let p = found else { fail("could not open the UID menu-bar popover") }
        return p
    }

    func closePopover() {
        if popover() != nil { click(iconCenter) }
    }

    /// The row containing the "network vpn icon" image.
    func vpnRow(in popover: AXUIElement) -> AXUIElement? {
        descendants(popover).first { el in
            str(el, "AXRole") == "AXRow" &&
                descendants(el).contains { str($0, "AXDescription") == "network vpn icon" }
        }
    }
}

func findUID() -> UID {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        fail("UID Enterprise is not running")
    }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    guard let extras = attr(axApp, "AXExtrasMenuBar") else {
        if !AXIsProcessTrusted() {
            fail("Accessibility access is required. Enable your terminal app in System Settings > Privacy & Security > Accessibility, then restart it.")
        }
        fail("could not find the UID menu-bar icon")
    }
    guard let item = children(extras as! AXUIElement).first, let rect = frame(item) else {
        fail("could not find the UID menu-bar icon")
    }
    return UID(pid: app.processIdentifier, statusItem: rect)
}

// MARK: - Main

func setConnected(_ want: Bool) {
    if isConnected() == want {
        print(want ? "already connected" : "already disconnected")
        return
    }
    let uid = findUID()
    saveFocus()
    defer { restoreFocus() }
    let popover = uid.openPopover()
    guard let row = uid.vpnRow(in: popover), let r = frame(row) else {
        uid.closePopover()
        fail("could not find the VPN row in the UID popover")
    }
    // The switch is drawn (not exposed to Accessibility) at the right edge of the row.
    click(CGPoint(x: r.maxX - 36, y: r.midY))

    let ok = waitFor(want ? 30 : 10) { isConnected() == want }
    uid.closePopover()
    if !ok {
        fail(want ? "VPN did not connect within 30s (MFA or reauthentication may be needed in the UID app)"
                  : "VPN did not disconnect within 10s")
    }
    print(want ? "connected" : "disconnected")
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "on", "connect": setConnected(true)
case "off", "disconnect": setConnected(false)
case "toggle": setConnected(!isConnected())
case "status", nil:
    let c = isConnected()
    print(c ? "connected" : "disconnected")
    exit(c ? 0 : 3)
default:
    fail("usage: uid-vpn on|off|toggle|status")
}
