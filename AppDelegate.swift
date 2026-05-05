import AppKit
import ServiceManagement

private var powerMateAppDelegate: AppDelegate?

private enum DiagnosticsLog {
    private static var logURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PowerMateMGG.log")
    }

    static func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let logURL else { return }

        if FileManager.default.fileExists(atPath: logURL.path) == false {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
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
    private var ghostOverlayWindow: NSWindow?
    private var ghostOverlayDismissTimer: Timer?
    private var ghostOverlayImages: [String: NSImage] = [:]
    private var lastDiagnosticsLogLine = ""
    private var connectionMenuItem: NSMenuItem?
    private var hidOpenMenuItem: NSMenuItem?
    private var reportMenuItem: NSMenuItem?
    private var eventsMenuItem: NSMenuItem?
    private var audioMenuItem: NSMenuItem?
    private var ledMenuItem: NSMenuItem?
    private var launchAtStartupMenuItem: NSMenuItem?
    private var audioController: AudioController!
    private var powerMate: PowerMateDevice!
    private var isConnected = false
    private var rotateCount = 0
    private var buttonCount = 0
    private var currentHIDStatus = PowerMateDeviceStatus()
    private var ledStatus = "not sent"
    private var lastSentLEDBrightness: UInt16?
    private var didDisableLEDPulse = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticsLog.write("launch begin")
        NSApp.setActivationPolicy(.accessory)

        guard ensureSingleInstance() else {
            DiagnosticsLog.write("exiting because another instance is already running")
            NSApp.terminate(nil)
            return
        }

        removeMainMenu()
        installStatusItem()
        startOriginalPowerMateLaunchObserver()

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
        guard findOriginalPowerMateApp() != nil else {
            return .continueLaunching
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The original PowerMate is currently running. Please quit the original PowerMate and re-launch PowerMateMGG."
        alert.addButton(withTitle: "Quit PowerMateMGG")

        alert.runModal()
        return .quitThisApp
    }

    private func findOriginalPowerMateApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first(where: isOriginalPowerMateApp)
    }

    private func isOriginalPowerMateApp(_ app: NSRunningApplication) -> Bool {
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

    private func startOriginalPowerMateLaunchObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    @objc private func handleApplicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              isOriginalPowerMateApp(app) else {
            return
        }

        let appName = app.localizedName ?? "PowerMate.app"
        DiagnosticsLog.write("\(appName) launched; quitting PowerMateMGG")
        NSApp.terminate(nil)
    }

    private func removeMainMenu() {
        NSApp.mainMenu = NSMenu()
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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        updateLaunchAtStartupMenuItem()
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.white.setStroke()

        let base = NSBezierPath()
        base.move(to: NSPoint(x: 2.0, y: 4.1))
        base.curve(
            to: NSPoint(x: 16.0, y: 4.1),
            controlPoint1: NSPoint(x: 2.0, y: 1.4),
            controlPoint2: NSPoint(x: 16.0, y: 1.4)
        )
        base.lineWidth = 1.4
        base.lineCapStyle = .round
        base.stroke()

        let glowRing = NSBezierPath()
        glowRing.move(to: NSPoint(x: 3.4, y: 4.0))
        glowRing.curve(
            to: NSPoint(x: 14.6, y: 4.0),
            controlPoint1: NSPoint(x: 6.2, y: 2.7),
            controlPoint2: NSPoint(x: 11.8, y: 2.7)
        )
        glowRing.lineWidth = 1.2
        glowRing.lineCapStyle = .round
        glowRing.stroke()

        let leftSide = NSBezierPath()
        leftSide.move(to: NSPoint(x: 4.6, y: 5.0))
        leftSide.line(to: NSPoint(x: 5.2, y: 10.6))
        leftSide.lineWidth = 1.45
        leftSide.lineCapStyle = .round
        leftSide.stroke()

        let rightSide = NSBezierPath()
        rightSide.move(to: NSPoint(x: 13.4, y: 5.0))
        rightSide.line(to: NSPoint(x: 12.8, y: 10.6))
        rightSide.lineWidth = 1.45
        rightSide.lineCapStyle = .round
        rightSide.stroke()

        let top = NSBezierPath(ovalIn: NSRect(x: 5.0, y: 10.2, width: 8.0, height: 4.1))
        top.lineWidth = 1.35
        top.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshRealtimeStatus()
        startStatusRefreshTimer()
    }

    func menuDidClose(_ menu: NSMenu) {
        stopStatusRefreshTimer()
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

    private func stopStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }

    private func handleRotation(_ delta: Int) {
        guard delta != 0 else { return }
        rotateCount += 1
        let volume = audioController.adjustVolume(by: Float(delta) * 0.025)
        refreshLED(volume: volume, muted: false)
        showVolumeOverlay(volume: volume)
    }

    private func toggleMute() {
        buttonCount += 1
        let muted = audioController.toggleMute()
        refreshLED(volume: audioController.currentVolume(), muted: muted)
        showMuteOverlay(isMuted: muted)
    }

    private func refreshLED() {
        let volume = audioController.currentVolume()
        let muted = audioController.isMuted()
        refreshLED(volume: volume, muted: muted)
    }

    private func refreshLED(volume: Float, muted: Bool) {
        let brightness = muted ? 0.05 : max(0.05, min(1.0, Double(volume)))
        let brightnessValue = UInt16((brightness * 255.0).rounded())

        let brightnessOK: Bool
        if lastSentLEDBrightness == brightnessValue {
            brightnessOK = true
        } else {
            brightnessOK = PowerMateUSBLightController.setBrightness(brightness)
            if brightnessOK {
                lastSentLEDBrightness = brightnessValue
            }
        }

        let pulseOK: Bool
        if didDisableLEDPulse {
            pulseOK = true
        } else {
            pulseOK = PowerMateUSBLightController.setPulseEnabled(false)
            didDisableLEDPulse = pulseOK
        }

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
        eventsMenuItem?.title = "Events: \(rotateCount) rotations, \(buttonCount) buttons, \(currentHIDStatus.debouncedButtonPressCount) bounce ignored"
        audioMenuItem?.title = String(
            format: "Audio: volume %.0f%%, %@",
            audioController.currentVolume() * 100.0,
            audioController.isMuted() ? "muted" : "not muted"
        )
        ledMenuItem?.title = "LED: \(ledStatus)"

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

        updateLaunchAtStartupMenuItem()
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

    private func showMuteOverlay(isMuted: Bool) {
        showGhostOverlay(image: makeMuteOverlayImage(isMuted: isMuted), duration: 2.0)
    }

    private func showVolumeOverlay(volume: Float) {
        showGhostOverlay(image: makeVolumeOverlayImage(volume: volume), duration: 0.5)
    }

    private func showGhostOverlay(image: NSImage?, duration: TimeInterval) {
        ghostOverlayDismissTimer?.invalidate()

        let window = ghostOverlayWindow ?? makeGhostOverlayWindow()
        ghostOverlayWindow = window

        if let imageView = window.contentView as? NSImageView {
            imageView.image = image
        }

        centerGhostOverlayWindow(window)
        window.alphaValue = 1.0
        window.orderFrontRegardless()

        let dismissTimer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.hideGhostOverlay()
        }
        RunLoop.main.add(dismissTimer, forMode: .common)
        ghostOverlayDismissTimer = dismissTimer
    }

    private func makeGhostOverlayWindow() -> NSWindow {
        let size = NSSize(width: 190, height: 190)
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: size))
        imageView.imageScaling = .scaleProportionallyUpOrDown

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.contentView = imageView
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.level = .screenSaver
        return window
    }

    private func centerGhostOverlayWindow(_ window: NSWindow) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let size = window.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2.0,
            y: screenFrame.midY - size.height / 2.0
        )
        window.setFrameOrigin(origin)
    }

    private func makeMuteOverlayImage(isMuted: Bool) -> NSImage? {
        isMuted ? makeSpeakerOverlayImage(cacheKey: "mute", waveCount: 0, isMuted: true)
            : makeSpeakerOverlayImage(cacheKey: "waves-2", waveCount: 2, isMuted: false)
    }

    private func makeVolumeOverlayImage(volume: Float) -> NSImage? {
        let clampedVolume = max(0.0, min(1.0, volume))
        let cacheKey: String
        let waveCount: Int
        let isMuted: Bool

        switch clampedVolume {
        case ...0.0:
            cacheKey = "mute"
            waveCount = 0
            isMuted = true
        case ...0.33:
            cacheKey = "waves-1"
            waveCount = 1
            isMuted = false
        case ...0.66:
            cacheKey = "waves-2"
            waveCount = 2
            isMuted = false
        default:
            cacheKey = "waves-3"
            waveCount = 3
            isMuted = false
        }

        return makeSpeakerOverlayImage(cacheKey: cacheKey, waveCount: waveCount, isMuted: isMuted)
    }

    private func makeSpeakerOverlayImage(cacheKey: String, waveCount: Int, isMuted: Bool) -> NSImage? {
        if let cachedImage = ghostOverlayImages[cacheKey] {
            return cachedImage
        }

        let size = NSSize(width: 190, height: 190)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.white.setStroke()
        NSColor.white.setFill()

        let speakerBase = NSBezierPath(roundedRect: NSRect(x: 28, y: 76, width: 28, height: 38), xRadius: 3, yRadius: 3)
        speakerBase.fill()

        let speakerCone = NSBezierPath()
        speakerCone.move(to: NSPoint(x: 58, y: 72))
        speakerCone.line(to: NSPoint(x: 108, y: 34))
        speakerCone.line(to: NSPoint(x: 108, y: 156))
        speakerCone.line(to: NSPoint(x: 58, y: 118))
        speakerCone.close()
        speakerCone.fill()

        if isMuted {
            let circle = NSBezierPath(ovalIn: NSRect(x: 116, y: 62, width: 66, height: 66))
            circle.lineWidth = 7
            circle.stroke()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 128, y: 72))
            slash.line(to: NSPoint(x: 170, y: 118))
            slash.lineWidth = 8
            slash.lineCapStyle = .round
            slash.stroke()
        } else {
            let center = NSPoint(x: 108, y: 95)
            let radii: [CGFloat] = [28, 46, 64]

            for radius in radii.prefix(max(0, min(3, waveCount))) {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: center, radius: radius, startAngle: -45, endAngle: 45, clockwise: false)
                wave.lineWidth = 7
                wave.lineCapStyle = .round
                wave.stroke()
            }
        }

        image.unlockFocus()
        ghostOverlayImages[cacheKey] = image
        return image
    }

    private func hideGhostOverlay() {
        ghostOverlayWindow?.orderOut(nil)
        ghostOverlayDismissTimer?.invalidate()
        ghostOverlayDismissTimer = nil
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
