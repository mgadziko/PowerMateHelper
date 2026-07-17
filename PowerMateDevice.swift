import Foundation
import IOKit.hid

struct ConnectedPowerMateStatus {
    let id: UInt64
    let persistentIdentifier: String
    let name: String
    var reportCount = 0
    var rotationCount = 0
    var buttonPressCount = 0
    var debouncedButtonPressCount = 0
    var lastReport = "none"
}

struct PowerMateDeviceStatus {
    var connected = false
    var openResult = "not started"
    var deviceCount = 0
    var devices: [ConnectedPowerMateStatus] = []
    var updatedDeviceID: UInt64?
}

final class PowerMateDevice {
    private let vendorID = 0x077d
    private let productID = 0x0410
    private let reportLength = 6
    private let buttonDebounceInterval: TimeInterval = 0.25

    private var manager: IOHIDManager?
    private var status = PowerMateDeviceStatus()
    private var deviceStates: [UInt64: PowerMateDeviceState] = [:]
    private var recentlyRemovedDeviceKeys: Set<String> = []

    private let onRotate: (Int, UInt64) -> Void
    private let onButtonPress: (UInt64) -> Void
    private let onConnectionChanged: (Bool) -> Void
    private let onStatusChanged: (PowerMateDeviceStatus) -> Void

    init(
        onRotate: @escaping (Int, UInt64) -> Void,
        onButtonPress: @escaping (UInt64) -> Void,
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
            powerMate.recentlyRemovedDeviceKeys.subtract(powerMate.deviceIdentityKeys(for: device))
            powerMate.registerInputReportCallback(for: device)
            powerMate.refreshMatchedDevices()
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let powerMate = Unmanaged<PowerMateDevice>.fromOpaque(context).takeUnretainedValue()
            let removedKeys = powerMate.deviceIdentityKeys(for: device)
            powerMate.recentlyRemovedDeviceKeys.formUnion(removedKeys)
            powerMate.unregisterDevice(matching: removedKeys)
            powerMate.refreshMatchedDevices()
        }, context)

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
        deviceStates.removeAll()
        manager = nil
    }

    private func refreshMatchedDevices() {
        guard let manager else {
            setConnected(false)
            return
        }

        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        let matchedDevices = devices ?? []
        let activeDevices = matchedDevices.filter {
            deviceIdentityKeys(for: $0).isDisjoint(with: recentlyRemovedDeviceKeys)
        }
        let activeDeviceKeys = Set(activeDevices.flatMap { deviceIdentityKeys(for: $0) })
        deviceStates = deviceStates.filter { $0.value.identityKeys.isDisjoint(with: activeDeviceKeys) == false }
        activeDevices.forEach(registerInputReportCallback)
        status.deviceCount = deviceStates.count
        status.devices = sortedDeviceStatuses()
        status.updatedDeviceID = nil
        setConnected(status.openResult == "success" && status.devices.isEmpty == false)
    }

    private func registerInputReportCallback(for device: IOHIDDevice) {
        let id = PowerMateDevice.registryID(for: device)
        guard deviceStates[id] == nil else { return }

        let state = PowerMateDeviceState(
            owner: self,
            deviceID: id,
            identityKeys: deviceIdentityKeys(for: device),
            persistentIdentifier: persistentIdentifier(for: device),
            name: deviceName(for: device),
            reportLength: reportLength
        )
        deviceStates[id] = state

        IOHIDDeviceRegisterInputReportCallback(
            device,
            state.buffer,
            reportLength,
            { context, result, _, _, _, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                let state = Unmanaged<PowerMateDeviceState>.fromOpaque(context).takeUnretainedValue()
                state.owner?.handleInputReport(report, length: reportLength, for: state.deviceID)
            },
            Unmanaged.passUnretained(state).toOpaque()
        )
    }

    private func unregisterDevice(matching identityKeys: Set<String>) {
        deviceStates = deviceStates.filter { $0.value.identityKeys.isDisjoint(with: identityKeys) }
    }

    private func handleInputReport(_ report: UnsafeMutablePointer<UInt8>, length: CFIndex, for deviceID: UInt64) {
        guard length >= 2 else { return }
        guard let state = deviceStates[deviceID] else { return }

        state.status.reportCount += 1
        let bytes = (0..<Int(length)).map { String(format: "%02x", report[$0]) }
        state.status.lastReport = bytes.joined(separator: " ")

        var shouldCallButtonHandler = false
        let buttonDown = report[0] != 0
        if buttonDown && !state.previousButtonDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - state.lastAcceptedButtonPressTime >= buttonDebounceInterval {
                state.lastAcceptedButtonPressTime = now
                state.status.buttonPressCount += 1
                shouldCallButtonHandler = true
            } else {
                state.status.debouncedButtonPressCount += 1
            }
        }
        state.previousButtonDown = buttonDown

        let delta = Int(Int8(bitPattern: report[1]))
        if delta != 0 {
            state.status.rotationCount += 1
        }

        status.devices = sortedDeviceStatuses()
        status.updatedDeviceID = deviceID
        publishStatus()

        if shouldCallButtonHandler {
            callOnMain { [onButtonPress] in
                onButtonPress(deviceID)
            }
        }

        if delta != 0 {
            callOnMain { [onRotate] in
                onRotate(delta, deviceID)
            }
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

    private func sortedDeviceStatuses() -> [ConnectedPowerMateStatus] {
        deviceStates.values
            .map(\.status)
            .sorted { $0.id < $1.id }
            .enumerated()
            .map { index, status in
                var status = status
                status = ConnectedPowerMateStatus(
                    id: status.id,
                    persistentIdentifier: status.persistentIdentifier,
                    name: "PowerMate \(index + 1)",
                    reportCount: status.reportCount,
                    rotationCount: status.rotationCount,
                    buttonPressCount: status.buttonPressCount,
                    debouncedButtonPressCount: status.debouncedButtonPressCount,
                    lastReport: status.lastReport
                )
                return status
            }
    }

    private func deviceName(for device: IOHIDDevice) -> String {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        return product?.isEmpty == false ? product! : "PowerMate"
    }

    private func persistentIdentifier(for device: IOHIDDevice) -> String {
        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
           serial.isEmpty == false {
            return "serial:\(serial)"
        }

        if let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber {
            return "location:\(String(format: "%08x", locationID.uint32Value))"
        }

        return "registry:\(PowerMateDevice.registryID(for: device))"
    }

    private func deviceIdentityKeys(for device: IOHIDDevice) -> Set<String> {
        var keys = Set<String>()
        keys.insert("registry:\(PowerMateDevice.registryID(for: device))")
        keys.insert("cfhash:\(CFHash(device))")

        if let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
           serial.isEmpty == false {
            keys.insert("serial:\(serial)")
        }

        if let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber {
            keys.insert("location:\(String(format: "%08x", locationID.uint32Value))")
        }

        return keys
    }

    private static func registryID(for device: IOHIDDevice) -> UInt64 {
        var entryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        if service != 0, IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
            return entryID
        }
        return UInt64(bitPattern: Int64(CFHash(device)))
    }
}

private final class PowerMateDeviceState {
    weak var owner: PowerMateDevice?
    let deviceID: UInt64
    let identityKeys: Set<String>
    let buffer: UnsafeMutablePointer<UInt8>
    var status: ConnectedPowerMateStatus
    var previousButtonDown = false
    var lastAcceptedButtonPressTime = -Double.infinity

    init(owner: PowerMateDevice, deviceID: UInt64, identityKeys: Set<String>, persistentIdentifier: String, name: String, reportLength: Int) {
        self.owner = owner
        self.deviceID = deviceID
        self.identityKeys = identityKeys
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        self.status = ConnectedPowerMateStatus(id: deviceID, persistentIdentifier: persistentIdentifier, name: name)
        buffer.initialize(repeating: 0, count: reportLength)
    }

    deinit {
        buffer.deallocate()
    }
}
