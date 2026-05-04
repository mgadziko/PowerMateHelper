import AppKit

private var powerMateAppDelegate: AppDelegate?

private enum DiagnosticsLog {
    static let path = "/tmp/PowerMateMGG.log"

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

@main
private enum PowerMateMGGMain {
    static func main() {
        DiagnosticsLog.write("explicit main begin")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        powerMateAppDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var diagnosticLabels: [String: NSTextField] = [:]
    private var statusRefreshTimer: Timer?
    private var lastDiagnosticsLogLine = ""
    private var connectionMenuItem: NSMenuItem?
    private var hidOpenMenuItem: NSMenuItem?
    private var reportMenuItem: NSMenuItem?
    private var eventsMenuItem: NSMenuItem?
    private var audioMenuItem: NSMenuItem?
    private var ledMenuItem: NSMenuItem?
    private var audioController: AudioController!
    private var powerMate: PowerMateDevice!
    private var isConnected = false
    private var rotateCount = 0
    private var buttonCount = 0
    private var currentHIDStatus = PowerMateDeviceStatus()
    private var ledStatus = "not sent"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticsLog.write("launch begin")
        NSApp.setActivationPolicy(.regular)

        guard ensureSingleInstance() else {
            DiagnosticsLog.write("exiting because another instance is already running")
            NSApp.terminate(nil)
            return
        }

        installMainMenu()
        installStatusItem()
        installDiagnosticsWindow()

        switch handleOriginalPowerMateIfNeeded() {
        case .continueLaunching:
            break
        case .quitThisApp:
            NSApp.terminate(nil)
            return
        }

        audioController = AudioController()
        powerMate = PowerMateDevice(
            onRotate: { [weak self] delta in
                self?.handleRotation(delta)
            },
            onButtonPress: { [weak self] in
                self?.toggleMute()
            },
            onConnectionChanged: { [weak self] connected in
                self?.updateStatusTitle(connected: connected)
            },
            onStatusChanged: { [weak self] status in
                self?.updateHIDStatus(status)
            }
        )

        powerMate.start()
        refreshLED()
        startStatusRefreshTimer()
        NSApp.activate(ignoringOtherApps: true)
        showDiagnostics()
        DiagnosticsLog.write("launch complete")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        showDiagnostics()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDiagnostics()
        return true
    }

    private func ensureSingleInstance() -> Bool {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleID = Bundle.main.bundleIdentifier

        let existingInstance = NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != currentPID
                && app.bundleIdentifier == currentBundleID
                && app.isTerminated == false
        }

        if let existingInstance {
            existingInstance.activate(options: [])
            return false
        }

        return true
    }

    private enum LaunchDecision {
        case continueLaunching
        case quitThisApp
    }

    private func handleOriginalPowerMateIfNeeded() -> LaunchDecision {
        guard let originalApp = findOriginalPowerMateApp() else {
            return .continueLaunching
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PowerMate.app is already running"
        alert.informativeText = """
        The original Griffin PowerMate app may already have access to the PowerMate hardware. Close it before starting PowerMateMGG, or continue anyway if you want to try launching both.
        """
        alert.addButton(withTitle: "Quit PowerMate.app and Continue")
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Quit PowerMateMGG")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            quitOriginalPowerMateApp(originalApp)
            return .continueLaunching
        case .alertSecondButtonReturn:
            return .continueLaunching
        default:
            return .quitThisApp
        }
    }

    private func findOriginalPowerMateApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                return false
            }

            let bundleIdentifier = app.bundleIdentifier?.lowercased() ?? ""
            let appName = app.localizedName?.lowercased() ?? ""
            let bundlePath = app.bundleURL?.path.lowercased() ?? ""

            guard bundleIdentifier != Bundle.main.bundleIdentifier?.lowercased(),
                  appName != "powermatemgg",
                  bundlePath.hasSuffix("/powermatemgg.app") == false else {
                return false
            }

            return bundleIdentifier == "com.griffintechnology.powermate"
                || bundleIdentifier == "com.griffintechnology.powermateapp"
                || appName == "powermate"
                || bundlePath.hasSuffix("/powermate.app")
        }
    }

    private func quitOriginalPowerMateApp(_ app: NSRunningApplication) {
        guard app.isTerminated == false else { return }

        app.terminate()

        let deadline = Date().addingTimeInterval(3.0)
        while app.isTerminated == false && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu(title: "PowerMateMGG")
        appMenu.addItem(NSMenuItem(title: "Show Diagnostics", action: #selector(showDiagnostics), keyEquivalent: "d"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit PowerMateMGG", action: #selector(quit), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = "PowerMate"
            button.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "PowerMate")
            button.imagePosition = .imageLeading
            button.toolTip = "PowerMateMGG"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "PowerMateMGG", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        connectionMenuItem = NSMenuItem(title: "Device: starting", action: nil, keyEquivalent: "")
        hidOpenMenuItem = NSMenuItem(title: "HID open: not started", action: nil, keyEquivalent: "")
        reportMenuItem = NSMenuItem(title: "Last report: none", action: nil, keyEquivalent: "")
        eventsMenuItem = NSMenuItem(title: "Events: 0 rotations, 0 buttons", action: nil, keyEquivalent: "")
        audioMenuItem = NSMenuItem(title: "Audio: starting", action: nil, keyEquivalent: "")
        ledMenuItem = NSMenuItem(title: "LED: not sent", action: nil, keyEquivalent: "")

        [
            connectionMenuItem,
            hidOpenMenuItem,
            reportMenuItem,
            eventsMenuItem,
            audioMenuItem,
            ledMenuItem
        ].compactMap { $0 }.forEach(menu.addItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshRealtimeStatus()
    }

    private func startStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshRealtimeStatus()
        }
        statusRefreshTimer?.tolerance = 0.1
    }

    private func installDiagnosticsWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
            styleMask: [.titled, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PowerMateMGG Diagnostics"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "PowerMateMGG")
        title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)

        [
            ("device", "Device: starting"),
            ("hid", "HID open: not started"),
            ("report", "Last report: none"),
            ("events", "Events: 0 rotations, 0 buttons"),
            ("audio", "Audio: starting"),
            ("led", "LED: not sent")
        ].forEach { key, text in
            let label = NSTextField(labelWithString: text)
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            diagnosticLabels[key] = label
            stack.addArrangedSubview(label)
        }

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        stack.addArrangedSubview(quitButton)

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22)
        ])
        window.contentView = contentView
        self.window = window
        showDiagnostics()
        DiagnosticsLog.write("diagnostics window installed")
    }

    private func handleRotation(_ delta: Int) {
        guard delta != 0 else { return }
        rotateCount += 1
        audioController.adjustVolume(by: Float(delta) * 0.025)
        updateDiagnosticsMenu()
        refreshLED()
    }

    private func toggleMute() {
        buttonCount += 1
        audioController.toggleMute()
        updateDiagnosticsMenu()
        refreshLED()
    }

    private func refreshLED() {
        let volume = audioController.currentVolume()
        let muted = audioController.isMuted()
        let brightness = muted ? 0.05 : max(0.05, min(1.0, Double(volume)))
        let brightnessOK = PowerMateUSBLightController.setBrightness(brightness)
        let pulseOK = PowerMateUSBLightController.setPulseEnabled(false)
        ledStatus = String(
            format: "brightness %.0f%%, %@",
            brightness * 100.0,
            brightnessOK && pulseOK ? "success" : "failed"
        )
        updateDiagnosticsMenu()
    }

    private func refreshRealtimeStatus() {
        guard audioController != nil else { return }
        updateLEDStatusFromCurrentAudio()
        updateDiagnosticsMenu()
    }

    private func updateLEDStatusFromCurrentAudio() {
        let volume = audioController.currentVolume()
        let muted = audioController.isMuted()
        let brightness = muted ? 0.05 : max(0.05, min(1.0, Double(volume)))
        ledStatus = String(
            format: "brightness %.0f%%, %@",
            brightness * 100.0,
            "last set"
        )
    }

    private func updateStatusTitle(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
            self?.statusItem?.button?.title = connected ? "PowerMate" : "PowerMate?"
            self?.updateDiagnosticsMenu()
        }
    }

    private func updateHIDStatus(_ status: PowerMateDeviceStatus) {
        currentHIDStatus = status
        updateDiagnosticsMenu()
    }

    private func updateDiagnosticsMenu() {
        guard audioController != nil else { return }

        connectionMenuItem?.title = currentHIDStatus.connected || isConnected
            ? "Device: connected (\(currentHIDStatus.deviceCount) matched)"
            : "Device: not connected (\(currentHIDStatus.deviceCount) matched)"
        hidOpenMenuItem?.title = "HID open: \(currentHIDStatus.openResult)"
        reportMenuItem?.title = "Last report: \(currentHIDStatus.lastReport)"
        eventsMenuItem?.title = "Events: \(rotateCount) rotations, \(buttonCount) buttons"
        audioMenuItem?.title = String(
            format: "Audio: volume %.0f%%, %@",
            audioController.currentVolume() * 100.0,
            audioController.isMuted() ? "muted" : "not muted"
        )
        ledMenuItem?.title = "LED: \(ledStatus)"

        diagnosticLabels["device"]?.stringValue = connectionMenuItem?.title ?? "Device: unknown"
        diagnosticLabels["hid"]?.stringValue = hidOpenMenuItem?.title ?? "HID open: unknown"
        diagnosticLabels["report"]?.stringValue = reportMenuItem?.title ?? "Last report: unknown"
        diagnosticLabels["events"]?.stringValue = eventsMenuItem?.title ?? "Events: unknown"
        diagnosticLabels["audio"]?.stringValue = audioMenuItem?.title ?? "Audio: unknown"
        diagnosticLabels["led"]?.stringValue = ledMenuItem?.title ?? "LED: unknown"

        let diagnosticsLine = [
            connectionMenuItem?.title,
            hidOpenMenuItem?.title,
            reportMenuItem?.title,
            eventsMenuItem?.title,
            audioMenuItem?.title,
            ledMenuItem?.title
        ].compactMap { $0 }.joined(separator: " | ")

        if diagnosticsLine != lastDiagnosticsLogLine {
            lastDiagnosticsLogLine = diagnosticsLine
            DiagnosticsLog.write(diagnosticsLine)
        }
    }

    @objc private func showDiagnostics() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
