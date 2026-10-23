// Boot-animation launcher.
//
// Plays a full-screen boot clip (boot.html in Resources) above everything,
// starts the real app underneath, and fades out once BOTH the clip has reached
// its tail and the real app has put a window on screen — whichever comes second.
//
// Which character and which app come from Info.plist:
//   BootCharacter       key passed to boot.html (?c=...)
//   BootTargetBundleID  the real app to open
//   BootTargetAppNames  fallback .app names, looked up in /Applications and
//                       ~/Applications when the bundle ID is not registered
//                       (vendors ship differently named or regional builds)
//   BootTargetName      shown while waiting for it
//
// `--demo` plays the clip without opening anything, for checking the look.
// `--snapshot <dir>` (with --demo) saves frames at 1.8s and 5s into <dir>, so the
// look can be checked without screen-recording permission.

import Cocoa
import WebKit

private let started = Date()
private func log(_ text: String) {
    print(String(format: "[%.2fs] ", Date().timeIntervalSince(started)) + text)
    fflush(stdout)
}

/// A borderless window can only take key events when it says so.
final class BootWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Launcher: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    private let character: String
    private let targetID: String
    private let targetNames: [String]
    private let targetName: String
    private let demo = CommandLine.arguments.contains("--demo")

    /// The real app on this machine: by bundle ID first, then by file name.
    private lazy var targetURL: URL? = resolveTarget()
    /// The bundle ID of the app actually found, which can differ from the
    /// configured one when it was found by name.
    private var resolvedID: String {
        targetURL.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? targetID
    }

    private var window: BootWindow?
    private var web: WKWebView?
    private var target: NSRunningApplication?
    private var readyTimer: Timer?

    private var atTail = false
    private var appReady = false
    private var leaving = false

    /// After the clip's tail, how long to keep holding for a slow app.
    private let tailGrace: TimeInterval = 12
    /// The screen is decoration: nothing may hold it longer than this.
    private let hardCap: TimeInterval = 30
    private let fade: TimeInterval = 1.8

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        character = info["BootCharacter"] as? String ?? "claude"
        targetID = info["BootTargetBundleID"] as? String ?? ""
        targetNames = info["BootTargetAppNames"] as? [String] ?? []
        targetName = info["BootTargetName"] as? String ?? "App"
        super.init()
    }

    private func resolveTarget() -> URL? {
        if !targetID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetID) {
            return url
        }
        let fm = FileManager.default
        let folders = [URL(fileURLWithPath: "/Applications"),
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for name in targetNames {
            for folder in folders {
                let url = folder.appendingPathComponent(name)
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Already open: this click just means "take me there", not "boot again".
        if !demo {
            let ids = Set([targetID, resolvedID].filter { !$0.isEmpty })
            if let running = ids.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first {
                log("\(targetName) already running; activating")
                running.activate()
                NSApp.terminate(nil)
                return
            }
        }
        guard demo || targetURL != nil else {
            let names = targetNames.isEmpty ? "" : "，也没有找到 " + targetNames.joined(separator: " / ")
            let alert = NSAlert()
            alert.messageText = "找不到 \(targetName)"
            alert.informativeText = "这台电脑上没有安装 \(targetName)（\(targetID)\(names)）。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        showBootWindow()
        if demo {
            appReady = true
            log("demo mode: not opening \(targetName)")
        } else {
            openTarget()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hardCap) { [weak self] in
            log("hard cap reached")
            self?.leave(quick: false)
        }
    }

    // MARK: - Window

    private func showBootWindow() {
        guard let screen = NSScreen.main else { return }
        let win = BootWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the menu bar and the Dock, on whichever Space is current.
        win.level = .screenSaver
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.isReleasedWhenClosed = false

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "boot")
        config.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: config)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        win.contentView = view

        if let page = Bundle.main.url(forResource: "boot", withExtension: "html"),
           let url = URL(string: page.absoluteString + "?c=" + character) {
            view.loadFileURL(url, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            log("boot.html missing from Resources")
        }

        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        NSApp.activate()
        window = win
        web = view

        // Esc works even if the page has not focused yet.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.leave(quick: true); return nil }
            return event
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("page failed: \(error.localizedDescription)")
        leave(quick: true)
    }

    // MARK: - The real app

    private func openTarget() {
        guard let url = targetURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        // Launch behind us: activating now would steal the keyboard from the boot
        // screen. It is brought forward just before the fade.
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    log("could not open \(self.targetName): \(error.localizedDescription)")
                    self.appReady = true
                    self.maybeLeave()
                    return
                }
                log("\(self.targetName) launched, pid \(app?.processIdentifier ?? -1)")
                self.target = app
                self.watchForWindow()
            }
        }
    }

    /// Ready means the app has finished launching AND has a real window on screen.
    private func watchForWindow() {
        readyTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, let app = self.target else { return }
            if app.isTerminated {
                log("\(self.targetName) quit during launch")
                timer.invalidate()
                self.appReady = true
                self.maybeLeave()
                return
            }
            guard app.isFinishedLaunching, Self.hasWindow(pid: app.processIdentifier) else { return }
            timer.invalidate()
            log("\(self.targetName) window is up")
            self.appReady = true
            self.maybeLeave()
        }
    }

    private static func hasWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Width"] ?? 0) > 300 && (bounds["Height"] ?? 0) > 200
        }
    }

    // MARK: - Messages from boot.html

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        switch body {
        case "started":
            log("clip started")
            scheduleSnapshots()
        case "tail":
            log("clip reached its tail")
            atTail = true
            if !appReady {
                web?.evaluateJavaScript("window.bootWaiting && window.bootWaiting('正在打开 \(targetName)…')")
                DispatchQueue.main.asyncAfter(deadline: .now() + tailGrace) { [weak self] in
                    guard let self, !self.leaving else { return }
                    log("\(self.targetName) still not ready after the grace period; leaving anyway")
                    self.leave(quick: false)
                }
            }
            maybeLeave()
        case "skip":
            log("skipped by user")
            leave(quick: true)
        case "error":
            log("an image failed to load")
        default:
            break
        }
    }

    private func scheduleSnapshots() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        for at in [1.8, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                self?.web?.takeSnapshot(with: nil) { image, _ in
                    guard let image, let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    let file = dir.appendingPathComponent(String(format: "frame-%.1fs.png", at))
                    try? png.write(to: file)
                    log("saved \(file.lastPathComponent)")
                }
            }
        }
    }

    // MARK: - Exit

    private func maybeLeave() {
        if atTail && appReady { leave(quick: false) }
    }

    private func leave(quick: Bool) {
        guard !leaving else { return }
        leaving = true
        readyTimer?.invalidate()
        // Bring the real app forward first, still underneath the boot screen, so
        // the dissolve reveals it rather than whatever was on screen before.
        target?.activate()
        let duration = quick ? 0.6 : fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let win = self.window else { NSApp.terminate(nil); return }
            log("fading out over \(duration)s")
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                win.animator().alphaValue = 0
            }, completionHandler: {
                win.orderOut(nil)
                log("done")
                NSApp.terminate(nil)
            })
        }
    }
}

let app = NSApplication.shared
let launcher = Launcher()
app.delegate = launcher
app.setActivationPolicy(.regular)
app.run()
