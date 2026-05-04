import AppKit
import ServiceManagement

private var powerMateAppDelegate: AppDelegate?

private enum DefaultsKey {
    static let dockIconVisible = "dockIconVisible"
}

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
    private var statusRefreshTimer: Timer?
    private var lastDiagnosticsLogLine = ""
    private var connectionMenuItem: NSMenuItem?
    private var hidOpenMenuItem: NSMenuItem?
    private var reportMenuItem: NSMenuItem?
    private var eventsMenuItem: NSMenuItem?
    private var audioMenuItem: NSMenuItem?
    private var ledMenuItem: NSMenuItem?
    private var launchAtStartupMenuItem: NSMenuItem?
    private var dockIconMenuItem: NSMenuItem?
    private var audioController: AudioController!
    private var powerMate: PowerMateDevice!
    private var isConnected = false
    private var isDockIconVisible = true
    private var rotateCount = 0
    private var buttonCount = 0
    private var currentHIDStatus = PowerMateDeviceStatus()
    private var ledStatus = "not sent"

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticsLog.write("launch begin")
        loadDockIconPreference()
        applyDockIconVisibility()

        guard ensureSingleInstance() else {
            DiagnosticsLog.write("exiting because another instance is already running")
            NSApp.terminate(nil)
            return
        }

        removeMainMenu()
        installStatusItem()

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
        DiagnosticsLog.write("launch complete")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
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

    private func removeMainMenu() {
        NSApp.mainMenu = NSMenu()
    }

    private func loadDockIconPreference() {
        guard UserDefaults.standard.object(forKey: DefaultsKey.dockIconVisible) != nil else {
            isDockIconVisible = true
            return
        }

        isDockIconVisible = UserDefaults.standard.bool(forKey: DefaultsKey.dockIconVisible)
    }

    private func persistDockIconPreference() {
        UserDefaults.standard.set(isDockIconVisible, forKey: DefaultsKey.dockIconVisible)
    }

    private func applyDockIconVisibility() {
        NSApp.setActivationPolicy(isDockIconVisible ? .regular : .accessory)
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
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
        launchAtStartupMenuItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleLaunchAtStartup), keyEquivalent: "")
        menu.addItem(launchAtStartupMenuItem!)
        dockIconMenuItem = NSMenuItem(title: "Hide Dock Icon", action: #selector(toggleDockIcon), keyEquivalent: "")
        menu.addItem(dockIconMenuItem!)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        NSColor(calibratedRed: 0.08, green: 0.38, blue: 0.95, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshRealtimeStatus()
    }

    private func startStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshRealtimeStatus()
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        statusRefreshTimer = timer
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
            self?.statusItem?.button?.toolTip = connected ? "PowerMateMGG: connected" : "PowerMateMGG: not connected"
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
        updateLaunchAtStartupMenuItem()
        dockIconMenuItem?.title = isDockIconVisible ? "Hide Dock Icon" : "Show Dock Icon"

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

    @objc private func toggleDockIcon() {
        isDockIconVisible.toggle()
        persistDockIconPreference()
        applyDockIconVisibility()
        if isDockIconVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
        updateDiagnosticsMenu()
    }

    @objc private func toggleLaunchAtStartup() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                DiagnosticsLog.write("launch at startup disabled")
            } else {
                try SMAppService.mainApp.register()
                DiagnosticsLog.write("launch at startup enabled")
            }
        } catch {
            DiagnosticsLog.write("launch at startup toggle failed: \(error.localizedDescription)")
            showLaunchAtStartupError(error)
        }

        updateDiagnosticsMenu()
    }

    private func updateLaunchAtStartupMenuItem() {
        guard let launchAtStartupMenuItem else { return }

        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtStartupMenuItem.title = "Launch on Startup"
            launchAtStartupMenuItem.state = .on
        case .requiresApproval:
            launchAtStartupMenuItem.title = "Launch on Startup (Approval Required)"
            launchAtStartupMenuItem.state = .mixed
        default:
            launchAtStartupMenuItem.title = "Launch on Startup"
            launchAtStartupMenuItem.state = .off
        }
    }

    private func showLaunchAtStartupError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not update Launch on Startup"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
