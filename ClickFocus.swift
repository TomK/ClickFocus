// ClickFocus: when a click activates an app, make sure the window that was
// clicked ends up focused.
//
// Some apps (notably Chrome with several profiles open on different displays)
// respond to activation by restoring their previously focused window, so the
// window under the cursor loses focus to one elsewhere. ClickFocus watches
// left mouse-down events without altering them, and if the app that owns the
// clicked window re-focuses the window that was focused before the click, it
// raises and focuses the clicked window again.

import AppKit
import ApplicationServices

let version = "0.1.0"

// Delays after the mouse-down at which the focused window is checked.
let checkDelays: [TimeInterval] = [0.05, 0.15, 0.35]

struct Options {
    var verbose = false
    var bundleIds: Set<String> = []  // empty = all apps
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "-v", "--verbose":
            options.verbose = true
        case "--apps":
            guard let list = args.next() else { usage(exitCode: 2) }
            options.bundleIds = Set(list.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
        case "--version":
            print(version)
            exit(0)
        case "-h", "--help":
            usage(exitCode: 0)
        default:
            FileHandle.standardError.write("unknown option: \(arg)\n".data(using: .utf8)!)
            usage(exitCode: 2)
        }
    }
    return options
}

func usage(exitCode: Int32) -> Never {
    print("""
    ClickFocus \(version)

    usage: ClickFocus [--apps <bundleId,...>] [--verbose]

      --apps     only act on these apps, e.g. com.google.Chrome (default: all apps)
      --verbose  log every click that is inspected
    """)
    exit(exitCode)
}

let options = parseOptions()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(
        from: Date(), timeZone: .current,
        formatOptions: [.withFullTime, .withFractionalSeconds])
    print("\(stamp) \(message)")
    fflush(stdout)
}

func debug(_ message: @autoclosure () -> String) {
    if options.verbose { log(message()) }
}

// MARK: - Accessibility helpers

let systemWide = AXUIElementCreateSystemWide()

func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value as? T
}

func title(_ window: AXUIElement?) -> String {
    guard let window else { return "<none>" }
    let name: String? = attribute(window, kAXTitleAttribute)
    return "\"\(name ?? "")\""
}

// The standard window containing the element at a screen point, if any.
// Panels, sheets, popovers and menus are excluded so palettes and dialogs
// keep their normal focus behaviour.
func standardWindow(at point: CGPoint) -> AXUIElement? {
    var element: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element)
            == .success, let element else {
        return nil
    }

    var window: AXUIElement? = element
    let role: String? = attribute(element, kAXRoleAttribute)
    if role != kAXWindowRole {
        window = attribute(element, kAXWindowAttribute)
    }
    guard let window else { return nil }

    let subrole: String? = attribute(window, kAXSubroleAttribute)
    return subrole == kAXStandardWindowSubrole ? window : nil
}

func pid(of element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
}

func focusedWindow(of pid: pid_t) -> AXUIElement? {
    attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
}

func focus(_ window: AXUIElement, pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
}

// MARK: - Click handling

// A click that activated an app, and the window that app had focused before it.
struct PendingClick {
    let id: Int
    let pid: pid_t
    let clicked: AXUIElement
    let previous: AXUIElement
}

var clickCount = 0
var latestClickId = 0

func handleMouseDown(at point: CGPoint) {
    // Clicks within the active app are left to it: a window it focuses there
    // is one it chose, such as a newly opened window.
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let clicked = standardWindow(at: point), let pid = pid(of: clicked),
          pid != frontmost else {
        return
    }

    let app = NSRunningApplication(processIdentifier: pid)
    if !options.bundleIds.isEmpty {
        guard let bundleId = app?.bundleIdentifier, options.bundleIds.contains(bundleId) else {
            return
        }
    }

    guard let previous = focusedWindow(of: pid), !CFEqual(previous, clicked) else {
        debug("click in \(title(clicked)): already the app's focused window")
        return
    }

    clickCount += 1
    let click = PendingClick(id: clickCount, pid: pid, clicked: clicked, previous: previous)
    latestClickId = click.id
    debug("click \(click.id) in \(title(clicked)) of \(app?.localizedName ?? "pid \(pid)"), "
        + "previously focused \(title(previous))")

    for delay in checkDelays {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { check(click, after: delay) }
    }
}

func check(_ click: PendingClick, after delay: TimeInterval) {
    // A newer click supersedes this one.
    guard click.id == latestClickId,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == click.pid,
          let focused = focusedWindow(of: click.pid) else {
        return
    }

    if CFEqual(focused, click.previous) {
        log("click \(click.id): app re-focused \(title(focused)) after \(Int(delay * 1000))ms, "
            + "focusing \(title(click.clicked))")
        focus(click.clicked, pid: click.pid)
    } else {
        debug("click \(click.id): focused \(title(focused)) after \(Int(delay * 1000))ms")
    }
}

// MARK: - Event tap

var eventTap: CFMachPort?

let callback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .leftMouseDown:
        handleMouseDown(at: event.location)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        log("event tap disabled, re-enabling")
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
if !trusted {
    log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
    while !AXIsProcessTrusted() { sleep(1) }
}

// Keep a hung app from stalling click handling.
AXUIElementSetMessagingTimeout(systemWide, 0.25)

guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
    callback: callback,
    userInfo: nil
) else {
    log("unable to create event tap")
    exit(1)
}
eventTap = tap
CFRunLoopAddSource(CFRunLoopGetMain(),
    CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

let scope = options.bundleIds.isEmpty ? "all apps" : options.bundleIds.sorted().joined(separator: ", ")
log("ClickFocus \(version) running for \(scope)")
NSApplication.shared.setActivationPolicy(.prohibited)
NSApplication.shared.run()
