import CoreAudio
import CoreMIDI
import Foundation
import MADSETCore
import Observation

/// Where the app plays and what it syncs, chosen in Settings and kept across launches: the main
/// output every player plays through, the monitor output (stored only, nothing is cued there yet)
/// and the MIDI destination that gets clock locked to the set's beats.
@MainActor
@Observable
final class DeviceSettings {
    static let shared = DeviceSettings()

    private(set) var outputs: [AudioOutputDevice] = []
    private(set) var midiDestinations: [MIDIDestination] = []
    private(set) var error: String?

    /// UID of the main output; nil follows the system's default output.
    var mainOutput: String? {
        didSet {
            UserDefaults.standard.set(mainOutput, forKey: Keys.mainOutput)
            applyMainOutput()
        }
    }

    /// UID of the monitor (pre-cueing) output; nil for none.
    var monitorOutput: String? {
        didSet { UserDefaults.standard.set(monitorOutput, forKey: Keys.monitorOutput) }
    }

    /// Unique ID of the MIDI destination that gets clock; nil sends none.
    var clockDestination: MIDIUniqueID? {
        didSet {
            UserDefaults.standard.set(clockDestination.map { Int($0) }, forKey: Keys.clockDestination)
            clock?.send(to: clockDestination)
        }
    }

    /// Seconds the clock goes out after the audio is heard; negative sends it earlier.
    var clockOffset: TimeInterval {
        didSet {
            UserDefaults.standard.set(clockOffset, forKey: Keys.clockOffset)
            clock?.setOffset(clockOffset)
        }
    }

    let maxClockOffset = AppConfig.current.sync.maxOffset

    @ObservationIgnored private var clock: MIDIClockSender?
    @ObservationIgnored private var deviceObserver: AudioDevices.DeviceObserver?
    @ObservationIgnored private let players = NSHashTable<SetPlayer>.weakObjects()

    private enum Keys {
        static let mainOutput = "mainOutput"
        static let monitorOutput = "monitorOutput"
        static let clockDestination = "midiClockDestination"
        static let clockOffset = "midiClockOffset"
    }

    private init() {
        let defaults = UserDefaults.standard
        mainOutput = defaults.string(forKey: Keys.mainOutput)
        monitorOutput = defaults.string(forKey: Keys.monitorOutput)
        clockDestination = (defaults.object(forKey: Keys.clockDestination) as? Int).map { MIDIUniqueID($0) }
        clockOffset = defaults.double(forKey: Keys.clockOffset)

        outputs = AudioDevices.outputs()
        deviceObserver = AudioDevices.observeChanges { [weak self] in self?.audioDevicesChanged() }
        midiDestinations = MIDIDestination.all()
        do {
            let clock = try MIDIClockSender(config: AppConfig.current.sync) { [weak self] in self?.midiDevicesChanged() }
            clock.send(to: clockDestination)
            clock.setOffset(clockOffset)
            self.clock = clock
        } catch {
            self.error = String(localized: "MIDI is not available: \(error.localizedDescription)")
        }
    }

    /// Plays `player` through the main output from now on, and through every later choice.
    func register(_ player: SetPlayer) {
        players.add(player)
        apply(mainOutputDevice, to: player)
    }

    /// Sends clock along `player`'s playhead; called when it starts playing.
    func follow(_ player: SetPlayer) {
        clock?.follow(player.clock)
    }

    func clearError() { error = nil }

    /// The chosen main output while it is connected, else the system's default.
    private var mainOutputDevice: AudioDeviceID {
        outputs.first { $0.uid == mainOutput }?.id ?? AudioDevices.defaultOutput()
    }

    private func applyMainOutput() {
        let device = mainOutputDevice
        for player in players.allObjects { apply(device, to: player) }
    }

    private func apply(_ device: AudioDeviceID, to player: SetPlayer) {
        do {
            try player.setOutputDevice(device)
        } catch {
            self.error = String(localized: "Could not switch the output: \(error.localizedDescription)")
        }
    }

    /// A device that comes back takes over again; one that goes leaves the default playing.
    private func audioDevicesChanged() {
        outputs = AudioDevices.outputs()
        applyMainOutput()
    }

    /// A destination that comes back gets clock again.
    private func midiDevicesChanged() {
        midiDestinations = MIDIDestination.all()
        clock?.send(to: clockDestination)
    }
}
