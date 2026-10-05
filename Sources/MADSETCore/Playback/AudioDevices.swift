import CoreAudio
import Foundation

/// A sound device that can play audio, identified across launches by its UID.
public struct AudioOutputDevice: Hashable, Sendable, Identifiable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    /// Output channels, counted over all its streams.
    public let channels: Int

    /// First channel (from 0) of each stereo pair a player can play through; a mono device has one channel.
    public var firstChannels: [Int] {
        channels == 1 ? [0] : Array(stride(from: 0, to: channels - 1, by: 2))
    }
}

/// The system's output devices, read from Core Audio.
public enum AudioDevices {
    /// Devices with at least one output channel, in the system's order.
    public static func outputs() -> [AudioOutputDevice] {
        var size: UInt32 = 0
        var address = systemAddress(kAudioHardwarePropertyDevices)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannels(of: id)
            guard channels > 0, let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name, channels: channels)
        }
    }

    /// The device sound goes to when no other is chosen.
    public static func defaultOutput() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        precondition(status == noErr, "Could not read the default output device (\(status))")
        return id
    }

    /// Calls `onChange` on the main queue whenever a device comes or goes, or the default output changes.
    /// Keep the returned observer for as long as the calls are wanted.
    public static func observeChanges(_ onChange: @escaping @MainActor @Sendable () -> Void) -> DeviceObserver {
        DeviceObserver(onChange)
    }

    public final class DeviceObserver {
        private let block: AudioObjectPropertyListenerBlock

        fileprivate init(_ onChange: @escaping @MainActor @Sendable () -> Void) {
            block = { _, _ in MainActor.assumeIsolated { onChange() } }
            for selector in Self.selectors {
                var address = systemAddress(selector)
                AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
        }

        deinit {
            for selector in Self.selectors {
                var address = systemAddress(selector)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            }
        }

        private static let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice]
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = systemAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
