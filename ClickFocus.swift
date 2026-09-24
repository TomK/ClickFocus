// ClickFocus: when a click activates an app, make sure the window that was
// clicked ends up focused.
//
// Some apps (notably Chrome with several profiles open on different displays)
// respond to activation by restoring their previously focused window, so the
// window under the cursor loses focus to one elsewhere. ClickFocus watches
// left mouse-down events without altering them, and if the app that owns the
// clicked window focuses one of its other existing windows instead, it raises
// and focuses the clicked window again.

import AppKit
import ApplicationServices

let version = "0.4.0"

// How long after a mouse-down the clicked app's focused window is watched,
// and how often it is checked. Polling needs no setup when the click lands;
// registering for focused-window-changed notifications then waits on the app
// while it is busy activating.
let watchDuration: TimeInterval = 0.5
let pollInterval: TimeInterval = 0.01

// Corrections allowed per click, so an app that keeps switching back cannot
// start a focus fight.
let maxCorrections = 3

// Internal flag for the relaunches made while waiting for permission.
let awaitingPermissionFlag = "--awaiting-permission"

struct Options {
    var verbose = false
    var awaitingPermission = false
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
        case awaitingPermissionFlag:
            options.awaitingPermission = true
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

// Undocumented, but stable for years and used by most window managers.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowID(of window: AXUIElement) -> CGWindowID? {
    var id: CGWindowID = 0
    return _AXUIElementGetWindow(window, &id) == .success ? id : nil
}

// A window as the window server reports it. Reading windows from the window
// server involves no request to their app, which is busy handling the click.
struct ServerWindow {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
}

// Normal-level windows, frontmost first. Menus, the Dock, popovers and the
// like sit at higher levels.
func serverWindows(_ option: CGWindowListOption) -> [ServerWindow] {
    let list = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { info in
        guard info[kCGWindowLayer as String] as? Int == 0,
              let id = info[kCGWindowNumber as String] as? CGWindowID,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo) else {
            return nil
        }
        return ServerWindow(id: id, pid: pid, bounds: bounds)
    }
}

func serverWindow(at point: CGPoint) -> ServerWindow? {
    serverWindows([.optionOnScreenOnly, .excludeDesktopElements]).first { $0.bounds.contains(point) }
}

// The app's accessibility element for a window server window.
func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
    let windows: [AXUIElement] = attribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) ?? []
    return windows.first { windowID(of: $0) == id }
}

func isStandard(_ window: AXUIElement) -> Bool {
    let subrole: String? = attribute(window, kAXSubroleAttribute)
    return subrole == kAXStandardWindowSubrole
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

// A click that activated an app, and the windows that app had at the time.
// The app's focused window is not recorded: the click reaches the app while
// it is being handled here, so the app may already report the clicked window
// as focused before it restores its previous one.
final class PendingClick {
    let id: Int
    let pid: pid_t
    let clickedId: CGWindowID
    let existingIds: Set<CGWindowID>
    let start: Date
    var clicked: AXUIElement?
    var timer: Timer?
    var corrections = 0
    var lastState = ""
    var events: [ClickEvent] = []

    init(id: Int, pid: pid_t, clickedId: CGWindowID, existingIds: Set<CGWindowID>, start: Date) {
        self.id = id
        self.pid = pid
        self.clickedId = clickedId
        self.existingIds = existingIds
        self.start = start
    }

    var elapsed: TimeInterval { Date().timeIntervalSince(start) }
    var elapsedText: String { "\(Int(elapsed * 1000))ms" }
    var clickedTitle: String { title(clicked ?? axWindow(pid: pid, id: clickedId)) }
}

// Something that happened while a click was watched. Messages are built when
// the click stops being watched: reading a window title waits on its app,
// which is busy activating straight after the click.
struct ClickEvent {
    let elapsed: String
    let always: Bool
    let message: () -> String
}

var clickCount = 0
var pending: PendingClick?

func handleMouseDown(at point: CGPoint) {
    let received = Date()
    let target = serverWindow(at: point)

    // Another click on the watched window, such as the second half of a
    // double-click, keeps it watched. Any other click supersedes it.
    if let pending, pending.clickedId == target?.id { return }
    stopWatching()

    // Clicks within the active app are left to it: a window it focuses there
    // is one it chose.
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    guard let target, target.pid != frontmost else { return }

    let app = NSRunningApplication(processIdentifier: target.pid)
    if !options.bundleIds.isEmpty {
        guard let bundleId = app?.bundleIdentifier, options.bundleIds.contains(bundleId) else {
            return
        }
    }

    let existingIds = Set(serverWindows(.optionAll)
        .filter { $0.pid == target.pid && $0.id != target.id }
        .map(\.id))
    guard !existingIds.isEmpty else { return }

    clickCount += 1
    let click = PendingClick(id: clickCount, pid: target.pid, clickedId: target.id,
        existingIds: existingIds, start: received)
    pending = click
    let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in check(click) }
    RunLoop.main.add(timer, forMode: .common)
    click.timer = timer

    let appName = app?.localizedName ?? "pid \(target.pid)"
    note(click, "click") { "clicked \(click.clickedTitle) of \(appName)" }
}

func stopWatching() {
    guard let click = pending else { return }
    click.timer?.invalidate()
    pending = nil
    for event in click.events where event.always || options.verbose {
        log("click \(click.id): \(event.message()) at \(event.elapsed)")
    }
}

func check(_ click: PendingClick) {
    guard pending === click else { return }
    guard click.elapsed < watchDuration else {
        note(click, "done") { "done" }
        stopWatching()
        return
    }

    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == click.pid else {
        note(click, "inactive") { "app not active" }
        return
    }
    guard let focused = focusedWindow(of: click.pid), let focusedId = windowID(of: focused) else {
        return
    }

    // A window the click opened is not in the existing list, so it keeps focus.
    guard click.existingIds.contains(focusedId) else {
        note(click, focusedId == click.clickedId ? "clicked" : "other") {
            "focused \(title(focused))"
        }
        return
    }

    // Only a switch between standard windows is undone, so palettes, sheets
    // and dialogs keep their normal focus behaviour.
    if click.clicked == nil { click.clicked = axWindow(pid: click.pid, id: click.clickedId) }
    guard let clicked = click.clicked, isStandard(clicked), isStandard(focused) else {
        note(click, "not standard") { "app focused \(title(focused)), not a switch between standard windows" }
        stopWatching()
        return
    }

    guard click.corrections < maxCorrections else {
        note(click, "gave up", always: true) {
            "app focused \(title(focused)), giving up after \(maxCorrections) corrections"
        }
        stopWatching()
        return
    }

    click.corrections += 1
    focus(clicked, pid: click.pid)
    note(click, "correction \(click.corrections)", always: true) {
        "app focused \(title(focused)), focused \(title(clicked))"
    }
}

// Records an event for a click when its state differs from the last one recorded.
func note(_ click: PendingClick, _ state: String, always: Bool = false,
          _ message: @escaping () -> String) {
    guard state != click.lastState else { return }
    click.lastState = state
    click.events.append(ClickEvent(elapsed: click.elapsedText, always: always, message: message))
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

// Ask for permission once, then wait for it. A running process does not see
// the permission being granted, so ClickFocus re-executes itself to check
// again, keeping its pid for launchd.
if !AXIsProcessTrusted() {
    if !options.awaitingPermission {
        log("waiting for Accessibility permission (System Settings > Privacy & Security > Accessibility)")
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }
    sleep(3)
    var args = CommandLine.arguments
    if !options.awaitingPermission { args.append(awaitingPermissionFlag) }
    let path = Bundle.main.executablePath ?? args[0]
    var argv = args.map { strdup($0) } + [nil]
    execv(path, &argv)
    log("unable to relaunch \(path): \(String(cString: strerror(errno)))")
    exit(1)
}
if options.awaitingPermission { log("Accessibility permission granted") }

// Keep a hung app from stalling click handling.
AXUIElementSetMessagingTimeout(systemWide, 0.1)

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
