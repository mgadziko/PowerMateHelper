import Foundation
import IOKit.hid

struct PowerMateDeviceStatus {
    var connected = false
    var openResult = "not started"
    var deviceCount = 0
    var reportCount = 0
    var debouncedButtonPressCount = 0
    var lastReport = "none"
}

final class PowerMateDevice {
    private let vendorID = 0x077d
    private let productID = 0x0410
    private let reportLength = 6
    private let buttonDebounceInterval: TimeInterval = 0.25

    private var manager: IOHIDManager?
    private var previousButtonDown = false
    private var lastAcceptedButtonPressTime = -Double.infinity
    private var status = PowerMateDeviceStatus()
    private var reportRegistrations: [Int: ReportRegistration] = [:]

    private let onRotate: (Int) -> Void
    private let onButtonPress: () -> Void
    private let onConnectionChanged: (Bool) -> Void
    private let onStatusChanged: (PowerMateDeviceStatus) -> Void

    init(
        onRotate: @escaping (Int) -> Void,
        onButtonPress: @escaping () -> Void,
        onConnectionChanged: @escaping (Bool) -> Void,
        onStatusChanged: @escaping (PowerMateDeviceStatus) -> Void
    ) {
        self.onRotate = onRotate
        self.onButtonPress = onButtonPress
        self.onConnectionChanged = onConnectionChanged
        self.onStatusChanged = onStatusChanged
    }

    deinit {
        stop()
    }

    func start() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID
        ]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let powerMate = Unmanaged<PowerMateDevice>.fromOpaque(context).takeUnretainedValue()
            powerMate.registerInputReportCallback(for: device)
            powerMate.refreshMatchedDevices()
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let powerMate = Unmanaged<PowerMateDevice>.fromOpaque(context).takeUnretainedValue()
            powerMate.unregisterInputReportCallback(for: device)
            powerMate.refreshMatchedDevices()
        }, context)

        IOHIDManagerRegisterInputReportCallback(
            manager,
            { context, result, _, _, _, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                Unmanaged<PowerMateDevice>.fromOpaque(context).takeUnretainedValue()
                    .handleInputReport(report, length: reportLength)
            },
            context
        )

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        status.openResult = PowerMateDevice.iokitResultDescription(result)

        refreshMatchedDevices()
    }

    func stop() {
        if let manager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        reportRegistrations.removeAll()
        manager = nil
    }

    private func refreshMatchedDevices() {
        guard let manager else {
            setConnected(false)
            return
        }

        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        status.deviceCount = devices?.count ?? 0
        devices?.forEach(registerInputReportCallback)
        setConnected(status.openResult == "success" && status.deviceCount > 0)
    }

    private func registerInputReportCallback(for device: IOHIDDevice) {
        let key = Int(CFHash(device))
        guard reportRegistrations[key] == nil else { return }

        let registration = ReportRegistration(length: reportLength)
        reportRegistrations[key] = registration

        IOHIDDeviceRegisterInputReportCallback(
            device,
            registration.buffer,
            reportLength,
            { context, result, _, _, _, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                Unmanaged<PowerMateDevice>.fromOpaque(context).takeUnretainedValue()
                    .handleInputReport(report, length: reportLength)
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func unregisterInputReportCallback(for device: IOHIDDevice) {
        reportRegistrations.removeValue(forKey: Int(CFHash(device)))
    }

    private func handleInputReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard length >= 2 else { return }

        status.reportCount += 1
        let bytes = (0..<Int(length)).map { String(format: "%02x", report[$0]) }
        status.lastReport = bytes.joined(separator: " ")
        publishStatus()

        let buttonDown = report[0] != 0
        if buttonDown && !previousButtonDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastAcceptedButtonPressTime >= buttonDebounceInterval {
                lastAcceptedButtonPressTime = now
                callOnMain(onButtonPress)
            } else {
                status.debouncedButtonPressCount += 1
                publishStatus()
            }
        }
        previousButtonDown = buttonDown

        let delta = Int(Int8(bitPattern: report[1]))
        guard delta != 0 else { return }

        callOnMain { [onRotate] in
            onRotate(delta)
        }
    }

    private func setConnected(_ connected: Bool) {
        status.connected = connected
        onConnectionChanged(connected)
        publishStatus()
    }

    private func publishStatus() {
        let status = self.status
        callOnMain { [onStatusChanged] in
            onStatusChanged(status)
        }
    }

    private func callOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private static func iokitResultDescription(_ result: IOReturn) -> String {
        if result == kIOReturnSuccess {
            return "success"
        }
        if result == kIOReturnExclusiveAccess {
            return "exclusive access"
        }
        return String(format: "0x%08x", result)
    }
}

private final class ReportRegistration {
    let buffer: UnsafeMutablePointer<UInt8>

    init(length: Int) {
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)
    }

    deinit {
        buffer.deallocate()
    }
}
