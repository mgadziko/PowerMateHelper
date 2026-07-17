import AppKit
import ApplicationServices
import ServiceManagement

private var powerMateAppDelegate: AppDelegate?

private enum DiagnosticsLog {
    private static var logURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PowerMate Helper.log")
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

enum AccessibilityPermissionController {
    private static var didRequestPrompt = false

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func requestIfNeeded(reason: String) -> Bool {
        if isTrusted {
            return true
        }

        if didRequestPrompt == false {
            didRequestPrompt = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        DiagnosticsLog.write("\(reason) requires Accessibility permission")
        return false
    }
}

@main
private enum PowerMateHelperMain {
    static func main() {
        DiagnosticsLog.write("explicit main begin")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        powerMateAppDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}

private enum PowerMateFunction: String {
    case volume
    case screenBrightness
    case horizontalScrolling
    case verticalScrolling
    case horizontalMouseMovement
    case verticalMouseMovement
    case applicationSwitching

    var title: String {
        switch self {
        case .volume:
            return "Audio Volume"
        case .screenBrightness:
            return "Screen Brightness"
        case .horizontalScrolling:
            return "Horizontal Scrolling"
        case .verticalScrolling:
            return "Vertical Scrolling"
        case .horizontalMouseMovement:
            return "Horizontal Mouse Movement"
        case .verticalMouseMovement:
            return "Vertical Mouse Movement"
        case .applicationSwitching:
            return "Application Switching"
        }
    }
}

private final class PowerMateFunctionMenuAction: NSObject {
    let deviceID: UInt64
    let function: PowerMateFunction

    init(deviceID: UInt64, function: PowerMateFunction) {
        self.deviceID = deviceID
        self.function = function
    }
}

private struct PowerMateDeviceMenuSignature: Equatable {
    let id: UInt64
    let name: String
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let functionPreferencesKey = "PowerMateFunctionsByPersistentIdentifier"
    private let showDockIconPreferenceKey = "ShowDockIcon"
    private let muteFeedbackPreferenceKey = "MutePowerMateHelperFeedback"
    private let menuIndent = "    "
    private let volumeClickFeedback = VolumeClickFeedback()
    private let scrollController = VerticalScrollController()
    private let mouseMovementController = MouseMovementController()
    private let applicationSwitcherController = ApplicationSwitcherController()
    private let ledController = LEDController()
    private var statusItem: NSStatusItem?
    private var statusRefreshTimer: Timer?
    private var ghostOverlayWindow: NSWindow?
    private var ghostOverlayDismissTimer: Timer?
    private var ghostOverlayImages: [String: NSImage] = [:]
    private var lastDiagnosticsLogLine = ""
    private var connectionMenuItem: NSMenuItem?
    private var deviceStatusHeadingMenuItem: NSMenuItem?
    private var hidOpenMenuItem: NSMenuItem?
    private var reportMenuItem: NSMenuItem?
    private var eventsMenuItem: NSMenuItem?
    private var audioMenuItem: NSMenuItem?
    private var ledMenuItem: NSMenuItem?
    private var displayMenuItem: NSMenuItem?
    private var launchAtStartupMenuItem: NSMenuItem?
    private var muteFeedbackMenuItem: NSMenuItem?
    private var dockIconMenuItem: NSMenuItem?
    private var deviceMenuItems: [NSMenuItem] = []
    private var deviceMenuSignature: [PowerMateDeviceMenuSignature] = []
    private var audioController: AudioController!
    private var displayBrightnessController: DisplayBrightnessController!
    private var powerMate: PowerMateDevice!
    private var isConnected = false
    private var rotateCount = 0
    private var buttonCount = 0
    private var currentHIDStatus = PowerMateDeviceStatus()
    private var selectedPowerMateDeviceID: UInt64?
    private var displayedPowerMateStatus: ConnectedPowerMateStatus?
    private var ledStatus = "not sent"
    private var displayedLEDStatus = "not sent"
    private var ledStatusesByDeviceID: [UInt64: String] = [:]
    private var functionsByDeviceID: [UInt64: PowerMateFunction] = [:]
    private var functionsByPersistentIdentifier: [String: PowerMateFunction] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticsLog.write("launch begin")
        applyDockIconPreference()
        applyFeedbackMutePreference()

        switch handleExistingPowerMateHelperIfNeeded() {
        case .continueLaunching:
            break
        case .quitThisApp:
            DiagnosticsLog.write("exiting because another PowerMate Helper instance is already running")
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
        displayBrightnessController = DisplayBrightnessController()
        loadFunctionPreferences()
        powerMate = PowerMateDevice(
            onRotate: { [weak self] delta, deviceID in
                self?.handleRotation(delta, deviceID: deviceID)
            },
            onButtonPress: { [weak self] deviceID in
                self?.toggleMute(deviceID: deviceID)
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

    private enum ExistingInstanceDecision {
        case continueLaunching
        case quitThisApp
    }

    private func handleExistingPowerMateHelperIfNeeded() -> ExistingInstanceDecision {
        guard let existingInstance = findExistingPowerMateHelperApp() else {
            return .continueLaunching
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PowerMate Helper is already running."
        alert.informativeText = "You can quit this launch, or force quit the already-running version and continue opening this one."
        alert.addButton(withTitle: "Quit This Launch")
        alert.addButton(withTitle: "Force Quit Already-Running App")

        if alert.runModal() == .alertFirstButtonReturn {
            existingInstance.activate(options: [])
            return .quitThisApp
        }

        DiagnosticsLog.write("force quitting already-running PowerMate Helper pid \(existingInstance.processIdentifier)")
        existingInstance.forceTerminate()

        if waitForTermination(of: existingInstance, timeout: 2.0) {
            DiagnosticsLog.write("already-running PowerMate Helper terminated")
            return .continueLaunching
        }

        let failureAlert = NSAlert()
        failureAlert.alertStyle = .critical
        failureAlert.messageText = "PowerMate Helper could not quit the already-running app."
        failureAlert.informativeText = "Please quit the already-running version manually, then open PowerMate Helper again."
        failureAlert.addButton(withTitle: "Quit This Launch")
        failureAlert.runModal()

        return .quitThisApp
    }

    private func findExistingPowerMateHelperApp() -> NSRunningApplication? {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleID = Bundle.main.bundleIdentifier

        return NSWorkspace.shared.runningApplications.first { app in
            app.processIdentifier != currentPID
                && app.bundleIdentifier == currentBundleID
                && app.isTerminated == false
        }
    }

    private func waitForTermination(of app: NSRunningApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while app.isTerminated == false && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return app.isTerminated
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
        alert.messageText = "The original PowerMate is currently running. Please quit the original PowerMate and re-launch PowerMate Helper."
        alert.addButton(withTitle: "Quit PowerMate Helper")

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
              appName != "powermate helper",
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
        DiagnosticsLog.write("\(appName) launched; quitting PowerMate Helper")
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
            button.toolTip = "PowerMate Helper"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "About PowerMate Helper", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        connectionMenuItem = NSMenuItem(title: "Devices Connected: starting", action: nil, keyEquivalent: "")
        connectionMenuItem?.isEnabled = false
        deviceStatusHeadingMenuItem = NSMenuItem(title: "Device Status", action: nil, keyEquivalent: "")
        deviceStatusHeadingMenuItem?.isEnabled = false
        hidOpenMenuItem = NSMenuItem(title: "\(menuIndent)HID open: not started", action: nil, keyEquivalent: "")
        reportMenuItem = NSMenuItem(title: "\(menuIndent)Last report: none", action: nil, keyEquivalent: "")
        eventsMenuItem = NSMenuItem(title: "\(menuIndent)Events: 0 rotations, 0 buttons", action: nil, keyEquivalent: "")
        audioMenuItem = NSMenuItem(title: "\(menuIndent)Audio: starting", action: nil, keyEquivalent: "")
        ledMenuItem = NSMenuItem(title: "\(menuIndent)LED: not sent", action: nil, keyEquivalent: "")
        displayMenuItem = NSMenuItem(title: "\(menuIndent)Display: not checked", action: nil, keyEquivalent: "")

        [
            connectionMenuItem,
            deviceStatusHeadingMenuItem,
            hidOpenMenuItem,
            reportMenuItem,
            eventsMenuItem,
            ledMenuItem,
            displayMenuItem,
            audioMenuItem
        ].compactMap { $0 }.forEach(menu.addItem)

        menu.addItem(.separator())
        launchAtStartupMenuItem = NSMenuItem(title: "Launch on Startup", action: #selector(toggleLaunchAtStartup), keyEquivalent: "")
        menu.addItem(launchAtStartupMenuItem!)
        muteFeedbackMenuItem = NSMenuItem(title: "Mute PowerMate Helper", action: #selector(toggleFeedbackMute), keyEquivalent: "")
        menu.addItem(muteFeedbackMenuItem!)
        dockIconMenuItem = NSMenuItem(title: "Show Dock Icon", action: #selector(toggleDockIcon), keyEquivalent: "")
        menu.addItem(dockIconMenuItem!)
        menu.addItem(NSMenuItem(title: "Quit PowerMate Helper", action: #selector(quit), keyEquivalent: ""))
        item.menu = menu
        statusItem = item
        updateLaunchAtStartupMenuItem()
        updateFeedbackMuteMenuItem()
        updateDockIconMenuItem()
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
        leftSide.line(to: NSPoint(x: 5.2, y: 8.2))
        leftSide.lineWidth = 1.45
        leftSide.lineCapStyle = .round
        leftSide.stroke()

        let rightSide = NSBezierPath()
        rightSide.move(to: NSPoint(x: 13.4, y: 5.0))
        rightSide.line(to: NSPoint(x: 12.8, y: 8.2))
        rightSide.lineWidth = 1.45
        rightSide.lineCapStyle = .round
        rightSide.stroke()

        let top = NSBezierPath(ovalIn: NSRect(x: 5.0, y: 7.8, width: 8.0, height: 2.7))
        top.lineWidth = 1.35
        top.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateDockIconMenuItem()
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

    private func handleRotation(_ delta: Int, deviceID: UInt64) {
        guard delta != 0 else { return }
        rotateCount += 1

        switch function(for: deviceID) {
        case .volume:
            let previousVolume = audioController.currentVolume()
            let volume = audioController.adjustVolume(by: Float(delta) * 0.025)
            volumeClickFeedback.playIfVolumeChanged(from: previousVolume, to: volume)
            refreshLED(level: volume, label: "volume", muted: false, sourceDeviceID: deviceID)
            showVolumeOverlay(volume: volume)
        case .screenBrightness:
            let previousBrightness = displayBrightnessController.currentBrightness()
            let brightness = displayBrightnessController.adjustBrightness(by: Float(delta) * 0.025)
            if displayBrightnessController.lastWriteSucceeded {
                volumeClickFeedback.playQuietlyIfValueChanged(from: previousBrightness, to: brightness)
            }
            DiagnosticsLog.write("display brightness \(Int((brightness * 100.0).rounded()))%, \(displayBrightnessController.lastStatus)")
            refreshLED(level: brightness, label: "screen brightness", muted: false, sourceDeviceID: deviceID)
        case .horizontalScrolling:
            if scrollController.scrollHorizontally(by: delta) {
                volumeClickFeedback.playQuietly()
            }
            refreshLED(level: 0.5, label: "horizontal scrolling", muted: false, sourceDeviceID: deviceID)
        case .verticalScrolling:
            if scrollController.scrollVertically(by: delta) {
                volumeClickFeedback.playQuietly()
            }
            refreshLED(level: 0.5, label: "vertical scrolling", muted: false, sourceDeviceID: deviceID)
        case .horizontalMouseMovement:
            mouseMovementController.moveHorizontally(by: delta)
            refreshLED(level: 0.5, label: "horizontal mouse", muted: false, sourceDeviceID: deviceID)
        case .verticalMouseMovement:
            mouseMovementController.moveVertically(by: delta)
            refreshLED(level: 0.5, label: "vertical mouse", muted: false, sourceDeviceID: deviceID)
        case .applicationSwitching:
            if applicationSwitcherController.rotate(by: delta) {
                volumeClickFeedback.playQuietly()
            }
            refreshLED(level: 0.5, label: "app switching", muted: false, sourceDeviceID: deviceID)
        }
    }

    private func toggleMute(deviceID: UInt64) {
        buttonCount += 1

        switch function(for: deviceID) {
        case .volume:
            let muted = audioController.toggleMute()
            volumeClickFeedback.playQuietly()
            refreshLED(level: audioController.currentVolume(), label: "volume", muted: muted, sourceDeviceID: deviceID)
            showMuteOverlay(isMuted: muted)
        case .screenBrightness:
            let previousBrightness = displayBrightnessController.currentBrightness()
            let brightness = displayBrightnessController.setBrightnessWithSystemKeys(0.5)
            if displayBrightnessController.lastWriteSucceeded {
                volumeClickFeedback.playQuietlyIfValueChanged(from: previousBrightness, to: brightness)
            }
            DiagnosticsLog.write("display brightness restored to 50%, \(displayBrightnessController.lastStatus)")
            refreshLED(level: brightness, label: "screen brightness", muted: false, sourceDeviceID: deviceID)
        case .horizontalScrolling:
            break
        case .verticalScrolling:
            break
        case .horizontalMouseMovement:
            mouseMovementController.clickPrimaryButton()
            refreshLED(level: 0.5, label: "horizontal mouse", muted: false, sourceDeviceID: deviceID)
        case .verticalMouseMovement:
            mouseMovementController.clickPrimaryButton()
            refreshLED(level: 0.5, label: "vertical mouse", muted: false, sourceDeviceID: deviceID)
        case .applicationSwitching:
            if applicationSwitcherController.activateSelection() {
                volumeClickFeedback.playQuietly()
            }
            refreshLED(level: 0.5, label: "app switching", muted: false, sourceDeviceID: deviceID)
        }
    }

    private func refreshLED() {
        let volume = audioController.currentVolume()
        let muted = audioController.isMuted()
        refreshLED(level: volume, label: "volume", muted: muted)
    }

    private func refreshLED(level: Float, label: String, muted: Bool, sourceDeviceID: UInt64? = nil) {
        let brightness = ledBrightness(level: level, muted: muted)

        ledController.setBrightness(brightness) { [weak self] success in
            let newLEDStatus = String(
                format: "%@ %.0f%%, %@",
                label,
                brightness * 100.0,
                success ? "success" : "failed"
            )
            self?.updateLEDStatus(newLEDStatus, sourceDeviceID: sourceDeviceID)
        }
    }

    private func updateLEDStatus(_ newLEDStatus: String, sourceDeviceID: UInt64?) {
        ledStatus = newLEDStatus
        if let sourceDeviceID {
            ledStatusesByDeviceID[sourceDeviceID] = newLEDStatus
        }
        if sourceDeviceID == nil || sourceDeviceID == selectedPowerMateDeviceID {
            displayedLEDStatus = newLEDStatus
        }
        updateDiagnosticsMenu()
    }

    private func refreshRealtimeStatus() {
        guard audioController != nil else { return }
        updateDiagnosticsMenu()
    }

    private func ledBrightness(level: Float, muted: Bool) -> Double {
        muted ? 0.0 : max(0.0, min(1.0, Double(level)))
    }

    private func updateStatusTitle(connected: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isConnected = connected
            self?.statusItem?.button?.toolTip = connected ? "PowerMate Helper: connected" : "PowerMate Helper: not connected"
            self?.updateDiagnosticsMenu()
        }
    }

    private func updateHIDStatus(_ status: PowerMateDeviceStatus) {
        currentHIDStatus = status
        updateSelectedPowerMateDevice()
        updateDisplayedPowerMateStatus()
        updateDiagnosticsMenu()
    }

    private func updateDiagnosticsMenu() {
        guard audioController != nil else { return }

        updateSelectedPowerMateDevice()
        updateDisplayedPowerMateStatus()
        refreshDeviceMenuItems()

        connectionMenuItem?.title = currentHIDStatus.connected || isConnected
            ? "Devices Connected: \(currentHIDStatus.deviceCount)"
            : "Devices Connected: none"
        hidOpenMenuItem?.title = indentedMenuTitle("HID open: \(currentHIDStatus.openResult)")
        reportMenuItem?.title = indentedMenuTitle("Last report: \(displayedPowerMateStatus?.lastReport ?? "none")")
        eventsMenuItem?.title = displayedPowerMateStatus.map {
            indentedMenuTitle("Events: \($0.rotationCount) rotations, \($0.buttonPressCount) buttons, \($0.debouncedButtonPressCount) bounce ignored")
        } ?? indentedMenuTitle("Events: 0 rotations, 0 buttons, 0 bounce ignored")
        audioMenuItem?.title = String(
            format: "\(menuIndent)Audio: volume %.0f%%, %@",
            audioController.currentVolume() * 100.0,
            audioController.isMuted() ? "muted" : "not muted"
        )
        ledMenuItem?.title = indentedMenuTitle("LED: \(displayedLEDStatus)")
        displayMenuItem?.title = String(
            format: "\(menuIndent)Display: brightness %.0f%%, %@",
            displayBrightnessController.peekBrightness() * 100.0,
            displayBrightnessController.lastStatus
        )

        let diagnosticsLine = [
            connectionMenuItem?.title,
            hidOpenMenuItem?.title,
            reportMenuItem?.title,
            eventsMenuItem?.title,
            ledMenuItem?.title,
            displayMenuItem?.title,
            audioMenuItem?.title
        ].compactMap { $0 }.joined(separator: " | ")

        if diagnosticsLine != lastDiagnosticsLogLine {
            lastDiagnosticsLogLine = diagnosticsLine
            DiagnosticsLog.write(diagnosticsLine)
        }
    }

    private func updateSelectedPowerMateDevice() {
        let deviceIDs = Set(currentHIDStatus.devices.map(\.id))
        functionsByDeviceID = functionsByDeviceID.filter { deviceIDs.contains($0.key) }
        ledStatusesByDeviceID = ledStatusesByDeviceID.filter { deviceIDs.contains($0.key) }
        restoreFunctionPreferencesForConnectedDevices()

        if let selectedPowerMateDeviceID, deviceIDs.contains(selectedPowerMateDeviceID) {
            return
        }
        selectedPowerMateDeviceID = currentHIDStatus.devices.first?.id
        displayedPowerMateStatus = selectedPowerMateStatus()
        displayedLEDStatus = selectedPowerMateDeviceID
            .flatMap { ledStatusesByDeviceID[$0] } ?? "not sent"
    }

    private func selectedPowerMateStatus() -> ConnectedPowerMateStatus? {
        guard let selectedPowerMateDeviceID else { return currentHIDStatus.devices.first }
        return currentHIDStatus.devices.first { $0.id == selectedPowerMateDeviceID }
    }

    private func updateDisplayedPowerMateStatus() {
        guard let selectedPowerMateDeviceID else {
            displayedPowerMateStatus = nil
            return
        }

        guard let selectedStatus = selectedPowerMateStatus() else {
            displayedPowerMateStatus = nil
            return
        }

        guard displayedPowerMateStatus?.id == selectedPowerMateDeviceID else {
            displayedPowerMateStatus = selectedStatus
            return
        }

        if currentHIDStatus.updatedDeviceID == selectedPowerMateDeviceID {
            displayedPowerMateStatus = selectedStatus
        }
    }

    private func refreshDeviceMenuItems() {
        guard let menu = statusItem?.menu,
              let connectionMenuItem,
              let connectionIndex = menu.items.firstIndex(of: connectionMenuItem) else {
            return
        }

        let newSignature = currentHIDStatus.devices.map {
            PowerMateDeviceMenuSignature(id: $0.id, name: $0.name)
        }

        if newSignature == deviceMenuSignature && deviceMenuItems.isEmpty == false {
            updateDeviceMenuItemStates()
            return
        }

        deviceMenuItems.forEach(menu.removeItem)
        deviceMenuItems.removeAll()
        deviceMenuSignature = newSignature

        if currentHIDStatus.devices.isEmpty {
            let item = NSMenuItem(title: indentedMenuTitle("No PowerMate devices"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            deviceMenuItems.append(item)
        } else {
            deviceMenuItems = currentHIDStatus.devices.map { device in
                let item = NSMenuItem(
                    title: indentedMenuTitle(device.name),
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = NSNumber(value: device.id)
                item.state = device.id == selectedPowerMateDeviceID ? .on : .off
                item.submenu = makeDeviceFunctionMenu(for: device)
                return item
            }
        }

        for (offset, item) in deviceMenuItems.enumerated() {
            menu.insertItem(item, at: connectionIndex + 1 + offset)
        }
    }

    private func indentedMenuTitle(_ title: String) -> String {
        "\(menuIndent)\(title)"
    }

    private func updateDeviceMenuItemStates() {
        for item in deviceMenuItems {
            guard let deviceID = (item.representedObject as? NSNumber)?.uint64Value else { continue }

            item.state = deviceID == selectedPowerMateDeviceID ? .on : .off

            item.submenu?.items.forEach { submenuItem in
                if let submenuDeviceID = (submenuItem.representedObject as? NSNumber)?.uint64Value {
                    submenuItem.state = submenuDeviceID == selectedPowerMateDeviceID ? .on : .off
                } else if let action = submenuItem.representedObject as? PowerMateFunctionMenuAction {
                    submenuItem.state = action.function == function(for: action.deviceID) ? .on : .off
                }
            }
        }
    }

    @objc private func selectPowerMateDevice(_ sender: NSMenuItem) {
        guard let deviceID = (sender.representedObject as? NSNumber)?.uint64Value else { return }
        selectedPowerMateDeviceID = deviceID
        displayedPowerMateStatus = selectedPowerMateStatus()
        displayedLEDStatus = ledStatusesByDeviceID[deviceID] ?? "not sent"
        updateDiagnosticsMenu()
    }

    private func makeDeviceFunctionMenu(for device: ConnectedPowerMateStatus) -> NSMenu {
        let submenu = NSMenu()

        let showStatusItem = NSMenuItem(
            title: "Show Device Status for This PowerMate",
            action: #selector(selectPowerMateDevice(_:)),
            keyEquivalent: ""
        )
        showStatusItem.target = self
        showStatusItem.representedObject = NSNumber(value: device.id)
        showStatusItem.state = device.id == selectedPowerMateDeviceID ? .on : .off
        submenu.addItem(showStatusItem)

        submenu.addItem(.separator())

        let functionGroups: [[PowerMateFunction]] = [
            [.applicationSwitching, .volume, .screenBrightness],
            [.horizontalScrolling, .verticalScrolling],
            [.horizontalMouseMovement, .verticalMouseMovement]
        ]

        for (groupIndex, functions) in functionGroups.enumerated() {
            if groupIndex > 0 {
                submenu.addItem(.separator())
            }

            for function in functions {
            let item = NSMenuItem(
                title: function.title,
                action: #selector(selectPowerMateFunction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = PowerMateFunctionMenuAction(deviceID: device.id, function: function)
            item.state = function == self.function(for: device.id) ? .on : .off
            submenu.addItem(item)
            }
        }

        return submenu
    }

    @objc private func selectPowerMateFunction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PowerMateFunctionMenuAction else { return }

        functionsByDeviceID[action.deviceID] = action.function
        persistFunctionPreference(action.function, for: action.deviceID)
        selectedPowerMateDeviceID = action.deviceID
        displayedPowerMateStatus = selectedPowerMateStatus()
        displayedLEDStatus = ledStatusesByDeviceID[action.deviceID] ?? "not sent"
        DiagnosticsLog.write("PowerMate \(action.deviceID) function set to \(action.function.title)")
        refreshLEDForCurrentState(of: action.function, sourceDeviceID: action.deviceID)
        updateDiagnosticsMenu()
    }

    private func function(for deviceID: UInt64) -> PowerMateFunction {
        functionsByDeviceID[deviceID] ?? .volume
    }

    private func loadFunctionPreferences() {
        let storedFunctions = UserDefaults.standard.dictionary(forKey: functionPreferencesKey) as? [String: String] ?? [:]
        functionsByPersistentIdentifier = storedFunctions.reduce(into: [:]) { result, entry in
            guard let function = PowerMateFunction(rawValue: entry.value) else { return }
            result[entry.key] = function
        }
    }

    private func saveFunctionPreferences() {
        let storedFunctions = functionsByPersistentIdentifier.mapValues(\.rawValue)
        UserDefaults.standard.set(storedFunctions, forKey: functionPreferencesKey)
    }

    private func restoreFunctionPreferencesForConnectedDevices() {
        for device in currentHIDStatus.devices {
            guard functionsByDeviceID[device.id] == nil,
                  let function = functionsByPersistentIdentifier[device.persistentIdentifier] else {
                continue
            }
            functionsByDeviceID[device.id] = function
        }
    }

    private func persistFunctionPreference(_ function: PowerMateFunction, for deviceID: UInt64) {
        guard let device = currentHIDStatus.devices.first(where: { $0.id == deviceID }) else { return }
        functionsByPersistentIdentifier[device.persistentIdentifier] = function
        saveFunctionPreferences()
    }

    private func refreshLEDForCurrentState(of function: PowerMateFunction, sourceDeviceID: UInt64) {
        switch function {
        case .volume:
            refreshLED(
                level: audioController.currentVolume(),
                label: "volume",
                muted: audioController.isMuted(),
                sourceDeviceID: sourceDeviceID
            )
        case .screenBrightness:
            refreshLED(
                level: displayBrightnessController.currentBrightness(),
                label: "screen brightness",
                muted: false,
                sourceDeviceID: sourceDeviceID
            )
        case .horizontalScrolling, .verticalScrolling:
            refreshLED(
                level: 0.5,
                label: function == .horizontalScrolling ? "horizontal scrolling" : "vertical scrolling",
                muted: false,
                sourceDeviceID: sourceDeviceID
            )
        case .horizontalMouseMovement:
            refreshLED(
                level: 0.5,
                label: "horizontal mouse",
                muted: false,
                sourceDeviceID: sourceDeviceID
            )
        case .verticalMouseMovement:
            refreshLED(
                level: 0.5,
                label: "vertical mouse",
                muted: false,
                sourceDeviceID: sourceDeviceID
            )
        case .applicationSwitching:
            refreshLED(
                level: 0.5,
                label: "app switching",
                muted: false,
                sourceDeviceID: sourceDeviceID
            )
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

    @objc private func toggleFeedbackMute() {
        let shouldMute = UserDefaults.standard.bool(forKey: muteFeedbackPreferenceKey) == false
        UserDefaults.standard.set(shouldMute, forKey: muteFeedbackPreferenceKey)
        applyFeedbackMutePreference()
        updateFeedbackMuteMenuItem()
        DiagnosticsLog.write(shouldMute ? "PowerMate Helper feedback muted" : "PowerMate Helper feedback unmuted")
    }

    private func applyFeedbackMutePreference() {
        volumeClickFeedback.isMuted = UserDefaults.standard.bool(forKey: muteFeedbackPreferenceKey)
    }

    private func updateFeedbackMuteMenuItem() {
        guard let muteFeedbackMenuItem else { return }

        muteFeedbackMenuItem.title = "Mute PowerMate Helper"
        muteFeedbackMenuItem.state = UserDefaults.standard.bool(forKey: muteFeedbackPreferenceKey) ? .on : .off
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "PowerMate Helper™ app"
        alert.informativeText = "©2026 Mark Gadzikowski. All Rights Reserved Worldwide.\nGriffin PowerMate® is a registered trademark of Griffin Technology, LLC.\n\nContact: powermatehelper@quantumpenguin.net"
        alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 1))
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleDockIcon() {
        let shouldShowDockIcon = UserDefaults.standard.bool(forKey: showDockIconPreferenceKey) == false
        UserDefaults.standard.set(shouldShowDockIcon, forKey: showDockIconPreferenceKey)
        applyDockIconPreference()
        updateDockIconMenuItem()
        DiagnosticsLog.write(shouldShowDockIcon ? "dock icon shown" : "dock icon hidden")
    }

    private func applyDockIconPreference() {
        let shouldShowDockIcon = UserDefaults.standard.bool(forKey: showDockIconPreferenceKey)
        NSApp.setActivationPolicy(shouldShowDockIcon ? .regular : .accessory)
    }

    private func updateDockIconMenuItem() {
        guard let dockIconMenuItem else { return }

        let shouldShowDockIcon = UserDefaults.standard.bool(forKey: showDockIconPreferenceKey)
        dockIconMenuItem.title = "Show Dock Icon"
        dockIconMenuItem.state = shouldShowDockIcon ? .on : .off
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

        let outlineColor = NSColor.black.withAlphaComponent(0.70)
        let foregroundColor = NSColor.white

        let speakerBase = NSBezierPath(roundedRect: NSRect(x: 28, y: 76, width: 28, height: 38), xRadius: 3, yRadius: 3)
        speakerBase.lineWidth = 5
        foregroundColor.setFill()
        speakerBase.fill()
        outlineColor.setStroke()
        speakerBase.stroke()

        let speakerCone = NSBezierPath()
        speakerCone.move(to: NSPoint(x: 58, y: 72))
        speakerCone.line(to: NSPoint(x: 108, y: 34))
        speakerCone.line(to: NSPoint(x: 108, y: 156))
        speakerCone.line(to: NSPoint(x: 58, y: 118))
        speakerCone.close()
        speakerCone.lineWidth = 5
        foregroundColor.setFill()
        speakerCone.fill()
        outlineColor.setStroke()
        speakerCone.stroke()

        if isMuted {
            let circle = NSBezierPath(ovalIn: NSRect(x: 116, y: 62, width: 66, height: 66))
            outlineColor.setStroke()
            circle.lineWidth = 13
            circle.stroke()
            foregroundColor.setStroke()
            circle.lineWidth = 7
            circle.stroke()

            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 128, y: 72))
            slash.line(to: NSPoint(x: 170, y: 118))
            outlineColor.setStroke()
            slash.lineWidth = 14
            slash.lineCapStyle = .round
            slash.stroke()
            foregroundColor.setStroke()
            slash.lineWidth = 8
            slash.lineCapStyle = .round
            slash.stroke()
        } else {
            let center = NSPoint(x: 108, y: 95)
            let radii: [CGFloat] = [28, 46, 64]

            for radius in radii.prefix(max(0, min(3, waveCount))) {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: center, radius: radius, startAngle: -45, endAngle: 45, clockwise: false)
                outlineColor.setStroke()
                wave.lineWidth = 13
                wave.lineCapStyle = .round
                wave.stroke()
                foregroundColor.setStroke()
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

private final class VolumeClickFeedback {
    private let clickSound = NSSound(named: NSSound.Name("Tink"))
    private var lastClickTime: TimeInterval = 0
    private let minimumClickInterval: TimeInterval = 0.035
    private let normalVolume: Float = 0.45
    private let quietVolume: Float = 0.18
    var isMuted = false

    func playIfVolumeChanged(from previousVolume: Float, to currentVolume: Float) {
        guard abs(currentVolume - previousVolume) > 0.0001 else { return }
        play(volume: normalVolume)
    }

    func playQuietlyIfValueChanged(from previousValue: Float, to currentValue: Float) {
        guard abs(currentValue - previousValue) > 0.0001 else { return }
        playQuietly()
    }

    func play() {
        play(volume: normalVolume)
    }

    func playQuietly() {
        play(volume: quietVolume)
    }

    private func play(volume: Float) {
        guard isMuted == false else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastClickTime >= minimumClickInterval else { return }
        lastClickTime = now

        clickSound?.stop()
        clickSound?.volume = volume
        clickSound?.play()
    }
}

private final class LEDController {
    private let minimumSendInterval: TimeInterval = 0.05
    private var lastSentBrightness: UInt16?
    private var lastSendTime: TimeInterval = 0
    private var didDisablePulse = false
    private var pendingRequest: LEDRequest?
    private var sendTimer: Timer?

    func setBrightness(_ brightness: Double, completion: @escaping (Bool) -> Void) {
        let clamped = max(0.0, min(1.0, brightness))
        pendingRequest = LEDRequest(brightness: clamped, completion: completion)

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSendTime
        if elapsed >= minimumSendInterval {
            sendPendingRequest()
            return
        }

        sendTimer?.invalidate()
        let timer = Timer(timeInterval: minimumSendInterval - elapsed, repeats: false) { [weak self] _ in
            self?.sendPendingRequest()
        }
        RunLoop.main.add(timer, forMode: .common)
        sendTimer = timer
    }

    private func sendPendingRequest() {
        sendTimer?.invalidate()
        sendTimer = nil

        guard let request = pendingRequest else { return }
        pendingRequest = nil

        let brightnessValue = UInt16((request.brightness * 255.0).rounded())

        let brightnessOK: Bool
        if lastSentBrightness == brightnessValue {
            brightnessOK = true
        } else {
            brightnessOK = PowerMateUSBLightController.setBrightness(request.brightness)
            if brightnessOK {
                lastSentBrightness = brightnessValue
            }
        }

        let pulseOK: Bool
        if didDisablePulse {
            pulseOK = true
        } else {
            pulseOK = PowerMateUSBLightController.setPulseEnabled(false)
            didDisablePulse = pulseOK
        }

        lastSendTime = ProcessInfo.processInfo.systemUptime
        request.completion(brightnessOK && pulseOK)
    }

    private struct LEDRequest {
        let brightness: Double
        let completion: (Bool) -> Void
    }
}

private final class VerticalScrollController {
    private let scrollMultiplier = 4

    @discardableResult
    func scrollHorizontally(by delta: Int) -> Bool {
        guard AccessibilityPermissionController.requestIfNeeded(reason: "horizontal scrolling") else {
            return false
        }

        let wheelDelta = Int32(delta * scrollMultiplier)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: 0,
            wheel2: wheelDelta,
            wheel3: 0
        ) else {
            DiagnosticsLog.write("horizontal scroll event creation failed")
            return false
        }

        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    func scrollVertically(by delta: Int) -> Bool {
        guard AccessibilityPermissionController.requestIfNeeded(reason: "vertical scrolling") else {
            return false
        }

        let wheelDelta = Int32(-delta * scrollMultiplier)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: wheelDelta,
            wheel2: 0,
            wheel3: 0
        ) else {
            DiagnosticsLog.write("vertical scroll event creation failed")
            return false
        }

        event.post(tap: .cghidEventTap)
        return true
    }
}

private final class MouseMovementController {
    private let movementMultiplier: CGFloat = 10
    private let displayBoundsCacheLifetime: TimeInterval = 2.0
    private var cachedDisplayBounds: [CGRect] = []
    private var cachedDisplayBoundsTime: TimeInterval = 0

    func moveHorizontally(by delta: Int) {
        moveBy(dx: CGFloat(delta) * movementMultiplier, dy: 0)
    }

    func moveVertically(by delta: Int) {
        moveBy(dx: 0, dy: -CGFloat(delta) * movementMultiplier)
    }

    func clickPrimaryButton() {
        let current = currentMouseLocation()
        for eventType in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: eventType,
                mouseCursorPosition: current,
                mouseButton: .left
            ) else {
                DiagnosticsLog.write("primary mouse click event creation failed")
                return
            }

            event.post(tap: .cghidEventTap)
        }
        DiagnosticsLog.write("primary mouse click posted at \(Int(current.x)),\(Int(current.y))")
    }

    private func moveBy(dx: CGFloat, dy: CGFloat) {
        let current = currentMouseLocation()
        let bounds = displayBounds(containing: current)
        let target = CGPoint(
            x: min(max(current.x + dx, bounds.minX), bounds.maxX - 1),
            y: min(max(current.y + dy, bounds.minY), bounds.maxY - 1)
        )
        warpMouse(to: target)
    }

    private func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func displayBounds(containing point: CGPoint) -> CGRect {
        for bounds in activeDisplayBounds() {
            if bounds.contains(point) {
                return bounds
            }
        }

        return CGDisplayBounds(CGMainDisplayID())
    }

    private func warpMouse(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
    }

    private func activeDisplayBounds() -> [CGRect] {
        let now = ProcessInfo.processInfo.systemUptime
        if cachedDisplayBounds.isEmpty == false,
           now - cachedDisplayBoundsTime < displayBoundsCacheLifetime {
            return cachedDisplayBounds
        }

        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            cachedDisplayBounds = [CGDisplayBounds(CGMainDisplayID())]
            cachedDisplayBoundsTime = now
            return cachedDisplayBounds
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            cachedDisplayBounds = [CGDisplayBounds(CGMainDisplayID())]
            cachedDisplayBoundsTime = now
            return cachedDisplayBounds
        }

        cachedDisplayBounds = displays
            .prefix(Int(displayCount))
            .map(CGDisplayBounds)
        cachedDisplayBoundsTime = now
        return cachedDisplayBounds
    }
}

private final class ApplicationSwitcherController {
    private let overlayDuration: TimeInterval = 3.0
    private let overlayWidth: CGFloat = 420
    private let rowHeight: CGFloat = 48
    private let verticalPadding: CGFloat = 24
    private let preferredVisibleRows = 7
    private let detentsPerSelectionStep = 2
    private var candidates: [NSRunningApplication] = []
    private var selectedIndex = 0
    private var pendingRotationDelta = 0
    private var window: NSWindow?
    private var stackView: NSStackView?
    private var rowViews: [AppSwitcherRowView] = []
    private var dismissTimer: Timer?

    @discardableResult
    func rotate(by delta: Int) -> Bool {
        guard delta != 0 else { return false }

        if window == nil || candidates.isEmpty {
            reloadCandidates()
        }

        guard candidates.isEmpty == false else {
            hide()
            return false
        }

        pendingRotationDelta += delta
        let selectionSteps = pendingRotationDelta / detentsPerSelectionStep
        guard selectionSteps != 0 else {
            showOverlay()
            scheduleDismissal()
            return false
        }

        pendingRotationDelta -= selectionSteps * detentsPerSelectionStep
        selectedIndex = wrappedIndex(selectedIndex + selectionSteps)
        showOverlay()
        scheduleDismissal()
        return true
    }

    @discardableResult
    func activateSelection() -> Bool {
        guard candidates.indices.contains(selectedIndex) else {
            hide()
            return false
        }

        let app = candidates[selectedIndex]
        hide()

        let activated = app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
        DiagnosticsLog.write(
            activated
                ? "activated app switch selection \(app.localizedName ?? app.bundleIdentifier ?? "unknown")"
                : "failed to activate app switch selection \(app.localizedName ?? app.bundleIdentifier ?? "unknown")"
        )
        return activated
    }

    private func reloadCandidates() {
        let ownBundleID = Bundle.main.bundleIdentifier
        let workspace = NSWorkspace.shared
        let regularApps = workspace.runningApplications.filter { app in
            app.activationPolicy == .regular &&
                app.isTerminated == false &&
                app.bundleIdentifier != ownBundleID
        }

        let frontmost = workspace.frontmostApplication
        let frontmostApp = regularApps.first { app in
            app.processIdentifier == frontmost?.processIdentifier
        }
        let remainingApps = regularApps
            .filter { app in app.processIdentifier != frontmostApp?.processIdentifier }
            .sorted { lhs, rhs in
                let lhsName = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let rhsName = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
            }

        candidates = [frontmostApp].compactMap { $0 } + remainingApps
        selectedIndex = candidates.count > 1 ? 1 : 0
    }

    private func showOverlay() {
        let window = self.window ?? makeWindow()
        self.window = window

        rebuildRows()
        updateSelection()
        center(window)
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hasShadow = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        window.contentView = container
        stackView = stack
        return window
    }

    private func rebuildRows() {
        guard let stackView else { return }

        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let visibleItems = visibleCandidateItems()
        rowViews = visibleItems.map { item in
            let row = AppSwitcherRowView()
            row.configure(
                icon: item.app.icon,
                title: item.app.localizedName ?? item.app.bundleIdentifier ?? "Unknown App"
            )
            stackView.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
            row.isHighlighted = item.index == selectedIndex
            return row
        }

        let height = CGFloat(max(visibleItems.count, 1)) * rowHeight + verticalPadding
        window?.setContentSize(NSSize(width: overlayWidth, height: height))
    }

    private func updateSelection() {
        rebuildRows()
    }

    private func center(_ window: NSWindow) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.midY - frame.height / 2
        ))
    }

    private func scheduleDismissal() {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: overlayDuration, repeats: false) { [weak self] _ in
            self?.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }

    private func hide() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        window?.orderOut(nil)
        candidates = []
        selectedIndex = 0
        pendingRotationDelta = 0
    }

    private func wrappedIndex(_ index: Int) -> Int {
        guard candidates.isEmpty == false else { return 0 }

        if index < 0 {
            return candidates.count - 1
        }
        if index >= candidates.count {
            return 0
        }
        return index
    }

    private func visibleCandidateItems() -> [(index: Int, app: NSRunningApplication)] {
        guard candidates.isEmpty == false else { return [] }

        let visibleCount = visibleRowCount()
        let halfWindow = visibleCount / 2
        let offsets = (-halfWindow)..<(-halfWindow + visibleCount)

        return offsets.map { offset in
            let index = wrappedIndex(selectedIndex + offset)
            return (index: index, app: candidates[index])
        }
    }

    private func visibleRowCount() -> Int {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 600)
        let rowsThatFit = max(1, Int((screenFrame.height - 120 - verticalPadding) / rowHeight))
        let boundedCount = min(preferredVisibleRows, rowsThatFit, candidates.count)

        if boundedCount <= 1 {
            return 1
        }
        return boundedCount.isMultiple(of: 2) ? boundedCount - 1 : boundedCount
    }
}

private final class AppSwitcherRowView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    var isHighlighted = false {
        didSet {
            layer?.backgroundColor = isHighlighted
                ? NSColor.systemBlue.withAlphaComponent(0.82).cgColor
                : NSColor.clear.cgColor
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func configure(icon: NSImage?, title: String) {
        iconView.image = icon
        titleField.stringValue = title
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.textColor = .white
        titleField.font = .systemFont(ofSize: 18, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}
