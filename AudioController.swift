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
        if let master = getVolume(element: kAudioObjectPropertyElementMain) {
            return master
        }

        let left = getVolume(element: 1) ?? 0
        let right = getVolume(element: 2) ?? left
        return (left + right) / 2
    }

    @discardableResult
    func adjustVolume(by delta: Float) -> Float {
        let volume = setVolume(currentVolume() + delta)
        if volume > 0 {
            setMuted(false)
        }
        return volume
    }

    @discardableResult
    func setVolume(_ volume: Float) -> Float {
        let clamped = max(0, min(1, volume))

        if setVolume(clamped, element: kAudioObjectPropertyElementMain) {
            return clamped
        }

        _ = setVolume(clamped, element: 1)
        _ = setVolume(clamped, element: 2)
        return clamped
    }

    func isMuted() -> Bool {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &muted)
        return status == noErr && muted != 0
    }

    @discardableResult
    func toggleMute() -> Bool {
        let muted = !isMuted()
        setMuted(muted)
        return muted
    }

    private func setMuted(_ muted: Bool) {
        var value = UInt32(muted ? 1 : 0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(outputDeviceID, &address) else { return }
        _ = AudioObjectSetPropertyData(
            outputDeviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &value
        )
    }

    private func getVolume(element: AudioObjectPropertyElement) -> Float? {
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(outputDeviceID, &address) else { return nil }
        let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setVolume(_ volume: Float, element: AudioObjectPropertyElement) -> Bool {
        var value = Float32(volume)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )

        guard AudioObjectHasProperty(outputDeviceID, &address) else { return false }
        let status = AudioObjectSetPropertyData(
            outputDeviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &value
        )
        return status == noErr
    }
}
