import AppKit
import Foundation
import CoreGraphics
import Darwin
import IOKit
import IOKit.graphics

final class DisplayBrightnessController {
    private typealias CGDisplayIOServicePortFunction = @convention(c) (CGDirectDisplayID) -> io_service_t
    private typealias DisplayServicesGetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DisplayServicesSetBrightnessFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let brightnessKey = kIODisplayBrightnessKey as NSString
    private lazy var displayServicePort: CGDisplayIOServicePortFunction? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let symbol = dlsym(handle, "CGDisplayIOServicePort") else {
            return nil
        }

        return unsafeBitCast(symbol, to: CGDisplayIOServicePortFunction.self)
    }()
    private lazy var displayServicesGetBrightness: DisplayServicesGetBrightnessFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            return nil
        }

        return unsafeBitCast(symbol, to: DisplayServicesGetBrightnessFunction.self)
    }()
    private lazy var displayServicesSetBrightness: DisplayServicesSetBrightnessFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let symbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            return nil
        }

        return unsafeBitCast(symbol, to: DisplayServicesSetBrightnessFunction.self)
    }()

    private(set) var lastStatus = "not checked"
    private(set) var lastWriteSucceeded = false
    private var cachedBrightness: Float?
    private var cachedBrightnessTime: TimeInterval = 0
    private let brightnessCacheLifetime: TimeInterval = 1.0
    private var cachedOnlineDisplays: [CGDirectDisplayID] = []
    private var cachedOnlineDisplaysTime: TimeInterval = 0
    private let onlineDisplaysCacheLifetime: TimeInterval = 2.0

    func currentBrightness() -> Float {
        readBrightness(updateStatus: true, allowCache: false)
    }

    func peekBrightness() -> Float {
        readBrightness(updateStatus: false, allowCache: true)
    }

    private func readBrightness(updateStatus: Bool, allowCache: Bool) -> Float {
        if allowCache,
           let cachedBrightness,
           ProcessInfo.processInfo.systemUptime - cachedBrightnessTime < brightnessCacheLifetime {
            return cachedBrightness
        }

        if let brightness = readDisplayServicesBrightness(updateStatus: updateStatus) {
            cacheBrightness(brightness)
            return brightness
        }

        for service in displayServices() {
            defer { IOObjectRelease(service) }

            var brightness: Float = 0
            let result = IODisplayGetFloatParameter(
                service,
                IOOptionBits(0),
                brightnessKey,
                &brightness
            )

            if result == kIOReturnSuccess {
                let clamped = max(0, min(1, brightness))
                if updateStatus {
                    lastStatus = "read success"
                }
                cacheBrightness(clamped)
                return clamped
            }
        }

        if updateStatus {
            lastStatus = "no readable display brightness"
        }
        let fallbackBrightness = cachedBrightness ?? 0.5
        cacheBrightness(fallbackBrightness)
        return fallbackBrightness
    }

    @discardableResult
    func adjustBrightness(by delta: Float) -> Float {
        let previousBrightness = currentBrightness()
        let stepCount = max(1, Int((abs(delta) / 0.025).rounded()))

        if postSystemBrightnessKey(increasing: delta > 0, repeatCount: stepCount) {
            let estimatedBrightness = max(0, min(1, previousBrightness + delta))
            cacheBrightness(estimatedBrightness)
            lastWriteSucceeded = true
            lastStatus = delta > 0
                ? "posted brightness up key \(stepCount)x"
                : "posted brightness down key \(stepCount)x"
            return estimatedBrightness
        }

        return setBrightness(previousBrightness + delta)
    }

    @discardableResult
    func setBrightness(_ brightness: Float) -> Float {
        let clamped = max(0, min(1, brightness))
        if setDisplayServicesBrightness(clamped) {
            cacheBrightness(clamped)
            return clamped
        }

        var writeCount = 0
        var lastResult: kern_return_t = kIOReturnNotFound

        for service in displayServices() {
            defer { IOObjectRelease(service) }

            let result = IODisplaySetFloatParameter(
                service,
                IOOptionBits(0),
                brightnessKey,
                clamped
            )

            lastResult = result
            if result == kIOReturnSuccess {
                writeCount += 1
            }
        }

        lastWriteSucceeded = writeCount > 0
        lastStatus = lastWriteSucceeded
            ? "wrote \(writeCount) display brightness value(s)"
            : "display brightness write failed: 0x\(String(UInt32(bitPattern: lastResult), radix: 16))"

        if lastWriteSucceeded {
            cacheBrightness(clamped)
        }
        return clamped
    }

    @discardableResult
    func setBrightnessWithSystemKeys(_ brightness: Float) -> Float {
        let clamped = max(0, min(1, brightness))
        let totalSteps = 16
        let targetSteps = Int((clamped * Float(totalSteps)).rounded())

        if postSystemBrightnessKey(increasing: false, repeatCount: totalSteps),
           postSystemBrightnessKey(increasing: true, repeatCount: targetSteps) {
            cacheBrightness(clamped)
            lastWriteSucceeded = true
            lastStatus = "reset brightness to \(Int((clamped * 100.0).rounded()))% with system keys"
            return clamped
        }

        let current = currentBrightness()
        let delta = clamped - current
        let stepCount = max(1, Int((abs(delta) / 0.025).rounded()))

        if abs(delta) > 0.001,
           postSystemBrightnessKey(increasing: delta > 0, repeatCount: stepCount) {
            cacheBrightness(clamped)
            lastWriteSucceeded = true
            lastStatus = delta > 0
                ? "posted brightness up key \(stepCount)x"
                : "posted brightness down key \(stepCount)x"
            return clamped
        }

        return setBrightness(clamped)
    }

    private func readDisplayServicesBrightness(updateStatus: Bool) -> Float? {
        guard let displayServicesGetBrightness else { return nil }

        var readCount = 0
        var lastBrightness: Float?

        for displayID in onlineDisplays() {
            var brightness: Float = 0
            let result = displayServicesGetBrightness(displayID, &brightness)
            if result == 0 {
                readCount += 1
                lastBrightness = max(0, min(1, brightness))
            }
        }

        if let lastBrightness {
            if updateStatus {
                lastStatus = "DisplayServices read \(readCount) display(s)"
            }
            cacheBrightness(lastBrightness)
            return lastBrightness
        }

        return nil
    }

    private func setDisplayServicesBrightness(_ brightness: Float) -> Bool {
        guard let displayServicesSetBrightness else { return false }

        var writeCount = 0
        var lastResult: Int32 = -1

        for displayID in onlineDisplays() {
            let result = displayServicesSetBrightness(displayID, brightness)
            lastResult = result
            if result == 0 {
                writeCount += 1
            }
        }

        lastWriteSucceeded = writeCount > 0
        if lastWriteSucceeded {
            lastStatus = "DisplayServices wrote \(writeCount) display(s)"
            cacheBrightness(brightness)
        } else {
            lastStatus = "DisplayServices write failed: \(lastResult)"
        }
        return lastWriteSucceeded
    }

    private func cacheBrightness(_ brightness: Float) {
        cachedBrightness = max(0, min(1, brightness))
        cachedBrightnessTime = ProcessInfo.processInfo.systemUptime
    }

    private func postSystemBrightnessKey(increasing: Bool, repeatCount: Int) -> Bool {
        let keyType: Int32 = increasing ? 2 : 3
        var posted = false

        for _ in 0..<max(1, repeatCount) {
            posted = postSystemBrightnessKey(keyType: keyType) || posted
        }

        return posted
    }

    private func postSystemBrightnessKey(keyType: Int32) -> Bool {
        var posted = false

        for keyState in [0xA, 0xB] {
            let data1 = (keyType << 16) | (Int32(keyState) << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xA00),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(data1),
                data2: -1
            )?.cgEvent else {
                continue
            }

            event.post(tap: .cghidEventTap)
            posted = true
        }

        return posted
    }

    private func onlineDisplays() -> [CGDirectDisplayID] {
        let now = ProcessInfo.processInfo.systemUptime
        if cachedOnlineDisplays.isEmpty == false,
           now - cachedOnlineDisplaysTime < onlineDisplaysCacheLifetime {
            return cachedOnlineDisplays
        }

        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetOnlineDisplayList(displayCount, &displays, &displayCount) == .success else {
            return []
        }

        cachedOnlineDisplays = Array(displays.prefix(Int(displayCount)))
        cachedOnlineDisplaysTime = now
        return cachedOnlineDisplays
    }

    private func displayServices() -> [io_service_t] {
        let activeServices = activeDisplayServices()
        if activeServices.isEmpty == false {
            return activeServices
        }

        return registryDisplayServices()
    }

    private func activeDisplayServices() -> [io_service_t] {
        guard let displayServicePort else { return [] }

        return onlineDisplays().compactMap { displayID in
            let service = displayServicePort(displayID)
            guard service != 0 else { return nil }
            return service
        }
    }

    private func registryDisplayServices() -> [io_service_t] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )

        guard result == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            services.append(service)
        }

        return services
    }
}
