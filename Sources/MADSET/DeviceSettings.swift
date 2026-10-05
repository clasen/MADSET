import CoreAudio
import CoreMIDI
import Foundation
import MADSETCore
import Observation

/// Where the app plays and what it syncs, chosen in Settings and kept across launches: the main
/// output every player plays through, the monitor output the monitors preview through (each on a
/// pair of its device's channels) and the MIDI destination that gets clock locked to the set's beats.
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
            mainChannel = 0
            applyMainOutput()
        }
    }

    /// First channel (from 0) of the pair of the main output's channels the set plays on.
    var mainChannel: Int {
        didSet {
            UserDefaults.standard.set(mainChannel, forKey: Keys.mainChannel)
            applyMainOutput()
        }
    }

    /// UID of the monitor (pre-cueing) output; nil for none.
    var monitorOutput: String? {
        didSet {
            UserDefaults.standard.set(monitorOutput, forKey: Keys.monitorOutput)
            monitorChannel = 0
            applyMonitorOutput()
        }
    }

    /// First channel (from 0) of the pair of the monitor output's channels the monitors play on.
    var monitorChannel: Int {
        didSet {
            UserDefaults.standard.set(monitorChannel, forKey: Keys.monitorChannel)
            applyMonitorOutput()
        }
    }

    /// Headphones level of the monitor output, 0 to 1.
    var monitorLevel: Double {
        didSet {
            UserDefaults.standard.set(monitorLevel, forKey: Keys.monitorLevel)
            applyLevels()
        }
    }

    /// What the headphones hear, from the monitor alone (0) to the main output alone (1).
    var cueMix: Double {
        didSet {
            UserDefaults.standard.set(cueMix, forKey: Keys.cueMix)
            applyLevels()
        }
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
    @ObservationIgnored private let monitors = NSHashTable<SetPlayer>.weakObjects()
    /// Monitors in monitor mode, whose headphones get the level and the cue mix.
    @ObservationIgnored private let listening = NSHashTable<SetPlayer>.weakObjects()

    private enum Keys {
        static let mainOutput = "mainOutput"
        static let monitorOutput = "monitorOutput"
        static let mainChannel = "mainOutputChannel"
        static let monitorChannel = "monitorOutputChannel"
        static let monitorLevel = "monitorLevel"
        static let cueMix = "cueMix"
        static let clockDestination = "midiClockDestination"
        static let clockOffset = "midiClockOffset"
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.monitorLevel: 1.0, Keys.cueMix: 0.0])
        mainOutput = defaults.string(forKey: Keys.mainOutput)
        monitorOutput = defaults.string(forKey: Keys.monitorOutput)
        mainChannel = defaults.integer(forKey: Keys.mainChannel)
        monitorChannel = defaults.integer(forKey: Keys.monitorChannel)
        monitorLevel = defaults.double(forKey: Keys.monitorLevel)
        cueMix = defaults.double(forKey: Keys.cueMix)
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
        apply(mainTarget, to: player)
    }

    /// Sends clock along `player`'s playhead; called when it starts playing.
    func follow(_ player: SetPlayer) {
        clock?.follow(player.clock)
    }

    /// Plays `monitor` through the monitor output from now on, and through every later choice.
    /// While there is none it stays paused, so a preview never reaches another output.
    func registerMonitor(_ monitor: SetPlayer) {
        monitors.add(monitor)
        applyMonitor(to: monitor)
        applyLevels(to: monitor)
    }

    /// Gives `monitor`'s headphones the level and the cue mix while it is in monitor mode, and
    /// silence otherwise.
    func setListening(_ monitor: SetPlayer, _ isListening: Bool) {
        if isListening { listening.add(monitor) } else { listening.remove(monitor) }
        applyLevels(to: monitor)
    }

    /// Whether the monitor output and its channels are there to preview through.
    var hasMonitorOutput: Bool { monitorTarget != nil }

    /// Whether previews are heard through the main output too, by everyone.
    var monitorIsMainOutput: Bool { monitorTarget == mainTarget }

    /// The connected output with this UID.
    func output(_ uid: String?) -> AudioOutputDevice? {
        outputs.first { $0.uid == uid }
    }

    func clearError() { error = nil }

    /// A device and the first of the pair of its channels a player plays on.
    private struct Target: Equatable {
        let device: AudioDeviceID
        let channel: Int
    }

    /// The chosen main output while it is connected, else the system's default; on its first pair
    /// when the chosen one is gone, since the set must go on.
    private var mainTarget: Target {
        guard let device = output(mainOutput) else { return Target(device: AudioDevices.defaultOutput(), channel: 0) }
        return Target(device: device.id, channel: device.firstChannels.contains(mainChannel) ? mainChannel : 0)
    }

    /// The chosen monitor output and channels while they are there, else nil: a preview never moves
    /// to other channels, where it could reach the audience.
    private var monitorTarget: Target? {
        guard let device = output(monitorOutput), device.firstChannels.contains(monitorChannel) else { return nil }
        return Target(device: device.id, channel: monitorChannel)
    }

    private func applyMainOutput() {
        let target = mainTarget
        for player in players.allObjects { apply(target, to: player) }
    }

    private func applyLevels() {
        for monitor in monitors.allObjects { applyLevels(to: monitor) }
    }

    private func applyLevels(to monitor: SetPlayer) {
        guard listening.contains(monitor) else { return monitor.setLevels(own: 0, reference: 0) }
        let gains = CueMix.gains(level: monitorLevel, mix: cueMix)
        monitor.setLevels(own: gains.own, reference: gains.reference)
    }

    private func applyMonitorOutput() {
        for monitor in monitors.allObjects { applyMonitor(to: monitor) }
    }

    private func applyMonitor(to monitor: SetPlayer) {
        guard let target = monitorTarget else { return monitor.pause() }
        apply(target, to: monitor)
    }

    private func apply(_ target: Target, to player: SetPlayer) {
        do {
            try player.setOutput(target.device, firstChannel: target.channel)
        } catch {
            self.error = String(localized: "Could not switch the output: \(error.localizedDescription)")
        }
    }

    /// A device that comes back takes over again; a main output that goes leaves the default
    /// playing, a monitor output that goes pauses the monitors.
    private func audioDevicesChanged() {
        outputs = AudioDevices.outputs()
        applyMainOutput()
        applyMonitorOutput()
    }

    /// A destination that comes back gets clock again.
    private func midiDevicesChanged() {
        midiDestinations = MIDIDestination.all()
        clock?.send(to: clockDestination)
    }
}
