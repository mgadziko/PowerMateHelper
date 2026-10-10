import CoreAudio
import Foundation

final class AudioController {
    private var outputDeviceID: AudioObjectID {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        return status == noErr ? deviceID : AudioObjectID(0)
    }

    func currentVolume() -> Float {
        currentVolume(on: outputDeviceID)
    }

    private func currentVolume(on deviceID: AudioObjectID) -> Float {
        if let master = getVolume(on: deviceID, element: kAudioObjectPropertyElementMain) {
            return master
        }

        let left = getVolume(on: deviceID, element: 1) ?? 0
        let right = getVolume(on: deviceID, element: 2) ?? left
        return (left + right) / 2
    }

    @discardableResult
    func adjustVolume(by delta: Float) -> (previous: Float, current: Float) {
        let deviceID = outputDeviceID
        let previousVolume = currentVolume(on: deviceID)
        let volume = setVolume(previousVolume + delta, on: deviceID)
        if volume > 0 {
            setMuted(false, on: deviceID)
        }
        return (previousVolume, volume)
    }

    @discardableResult
    func setVolume(_ volume: Float) -> Float {
        setVolume(volume, on: outputDeviceID)
    }

    private func setVolume(_ volume: Float, on deviceID: AudioObjectID) -> Float {
        let clamped = max(0, min(1, volume))

        if setVolume(clamped, on: deviceID, element: kAudioObjectPropertyElementMain) {
            return clamped
        }

        _ = setVolume(clamped, on: deviceID, element: 1)
        _ = setVolume(clamped, on: deviceID, element: 2)
        return clamped
    }

    func isMuted() -> Bool {
        isMuted(on: outputDeviceID)
    }

    @discardableResult
    func toggleMute() -> Bool {
        let deviceID = outputDeviceID
        let muted = !isMuted(on: deviceID)
        setMuted(muted, on: deviceID)
        return muted
    }

    private func setMuted(_ muted: Bool, on deviceID: AudioObjectID) {
        var value = UInt32(muted ? 1 : 0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return }
        _ = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
    }

    private func isMuted(on deviceID: AudioObjectID) -> Bool {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    private func getVolume(on deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setVolume(_ volume: Float, on deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var value = Float32(volume)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }
}
