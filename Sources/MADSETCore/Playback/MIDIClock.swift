import CoreMIDI
import Foundation
import Synchronization

/// A Core MIDI destination (a USB groovebox, a synth, an IAC bus), identified across launches by its unique ID.
public struct MIDIDestination: Hashable, Sendable, Identifiable {
    public let id: MIDIUniqueID
    public let name: String

    /// The destinations connected now.
    public static func all() -> [MIDIDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { index in
            let endpoint = MIDIGetDestination(index)
            var id: MIDIUniqueID = 0
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr,
                  MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name else { return nil }
            return MIDIDestination(id: id, name: name.takeRetainedValue() as String)
        }
    }
}

/// MIDI beat clock that follows the set: 24 clocks per beat, started on a bar of the set, so a
/// receiver's bars and kick land on the set's. A paused set sends Stop; playing it, or a jump of the
/// playhead, sends Start on the next bar. A jump by whole bars that keeps the beat, as moving the
/// playhead while it plays does, goes on clocking without a break. Start rather than Song Position
/// and Continue, which many receivers ignore; a pattern longer than a bar therefore restarts on that bar.
/// Times are host seconds. Pure, so it is tested without Core MIDI.
public struct MIDIClockSchedule: Sendable {
    public enum Message: Equatable, Sendable {
        case clock, start, stop
    }

    public struct Timed: Equatable, Sendable {
        public var message: Message
        public var time: Double
    }

    public struct Batch: Equatable, Sendable {
        /// Messages scheduled earlier but not sent yet are void.
        public var flush = false
        public var messages: [Timed] = []
    }

    static let clocksPerBeat = 24
    static let clocksPerBar = 4 * clocksPerBeat
    /// A receiver further than this many clocks from the playhead is restarted where the playhead is.
    static let jumpTolerance = 2.0

    /// The next clock to schedule, counted from the set's start; nil while the receiver is stopped.
    private var nextClock: Int?

    public init() {}

    public var isRunning: Bool { nextClock != nil }

    /// What to send for the playhead at `position` (nil while paused) so the receiver is scheduled
    /// up to `lookahead` seconds past `now`.
    public mutating func advance(to position: PlayheadClock.Position?, now: Double, lookahead: Double) -> Batch {
        var batch = Batch()
        guard let position else {
            if nextClock != nil {
                nextClock = nil
                batch.flush = true
                batch.messages.append(Timed(message: .stop, time: now))
            }
            return batch
        }
        let secondsPerClock = 1 / (position.beatsPerSecond * Double(Self.clocksPerBeat))
        let anchorClock = position.beat * Double(Self.clocksPerBeat)
        let currentClock = anchorClock + (now - position.hostTime) / secondsPerClock
        func time(of clock: Int) -> Double { position.hostTime + (Double(clock) - anchorClock) * secondsPerClock }

        func isInStep(_ clock: Int) -> Bool {
            let clock = Double(clock)
            return clock >= currentClock - Self.jumpTolerance && clock <= currentClock + lookahead / secondsPerClock + Self.jumpTolerance
        }
        if let next = nextClock, !isInStep(next) {
            // The clocks already sent fall on the same beats in the bars the playhead jumped to.
            let bars = Int(((currentClock - Double(next)) / Double(Self.clocksPerBar)).rounded())
            if isInStep(next + bars * Self.clocksPerBar) {
                nextClock = next + bars * Self.clocksPerBar
            } else {
                nextClock = nil
                batch.flush = true
                batch.messages.append(Timed(message: .stop, time: now))
            }
        }
        var next: Int
        if let nextClock {
            next = nextClock
        } else {
            next = max(0, Int((currentClock / Double(Self.clocksPerBar)).rounded(.up))) * Self.clocksPerBar
            guard time(of: next) <= now + lookahead else { return batch }
            batch.messages.append(Timed(message: .start, time: time(of: next)))
        }
        while time(of: next) <= now + lookahead {
            batch.messages.append(Timed(message: .clock, time: max(now, time(of: next))))
            next += 1
        }
        nextClock = next
        return batch
    }
}

/// Sends MIDI clock to one destination, following the playhead of whichever player it is given.
/// A thread schedules the messages a little ahead with Core MIDI timestamps, so their timing does
/// not depend on when the thread runs. Releasing the sender stops the thread.
public final class MIDIClockSender: Sendable {
    private struct Target {
        var destination: MIDIEndpointRef = 0
        var offset: TimeInterval = 0
        var clock: PlayheadClock?
    }

    /// What the thread shares with the sender; the thread holds only this.
    private final class Shared: Sendable {
        let target = Mutex(Target())
        let running = Atomic<Bool>(true)
    }

    private let shared = Shared()
    private let client: MIDIClientRef
    private let port: MIDIPortRef

    /// `onSetupChange` runs on the main actor whenever MIDI devices come or go.
    public init(config: AppConfig.Sync, onSetupChange: @escaping @MainActor @Sendable () -> Void) throws {
        precondition(config.clockLookahead > 2 * config.clockPollInterval, "MIDI clock lookahead must cover the poll interval")
        var client: MIDIClientRef = 0
        try Self.check(MIDIClientCreateWithBlock("MADSET" as CFString, &client) { notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { onSetupChange() } }
        })
        var port: MIDIPortRef = 0
        try Self.check(MIDIOutputPortCreate(client, "Clock" as CFString, &port))
        self.client = client
        self.port = port

        let thread = Thread { [shared, port] in Self.run(shared, port: port, config: config) }
        thread.qualityOfService = .userInteractive
        thread.name = "MADSET MIDI clock"
        thread.start()
    }

    deinit {
        shared.running.store(false, ordering: .releasing)
        MIDIClientDispose(client)
    }

    /// Sends clock to the destination with `id`, or to none. The previous destination gets Stop.
    public func send(to id: MIDIUniqueID?) {
        var endpoint: MIDIObjectRef = 0
        var type = MIDIObjectType.destination
        if let id, MIDIObjectFindByUniqueID(id, &endpoint, &type) != noErr || type != .destination { endpoint = 0 }
        shared.target.withLock { $0.destination = endpoint }
    }

    /// Seconds the clock is sent after the audio is heard; negative sends it earlier.
    public func setOffset(_ seconds: TimeInterval) {
        shared.target.withLock { $0.offset = seconds }
    }

    /// Follows the playhead of the player that owns `clock`.
    public func follow(_ clock: PlayheadClock) {
        shared.target.withLock { $0.clock = clock }
    }

    private static func run(_ shared: Shared, port: MIDIPortRef, config: AppConfig.Sync) {
        var schedule = MIDIClockSchedule()
        var destination: MIDIEndpointRef = 0
        while shared.running.load(ordering: .acquiring) {
            let current = shared.target.withLock { $0 }
            if current.destination != destination {
                if destination != 0, schedule.isRunning {
                    MIDIFlushOutput(destination)
                    send([.init(message: .stop, time: HostTime.now)], through: port, to: destination)
                }
                schedule = MIDIClockSchedule()
                destination = current.destination
            }
            if destination != 0 {
                var position = current.clock?.position
                position?.hostTime += current.offset
                let batch = schedule.advance(to: position, now: HostTime.now, lookahead: config.clockLookahead)
                if batch.flush { MIDIFlushOutput(destination) }
                send(batch.messages, through: port, to: destination)
            }
            Thread.sleep(forTimeInterval: config.clockPollInterval)
        }
        if destination != 0, schedule.isRunning {
            MIDIFlushOutput(destination)
            send([.init(message: .stop, time: HostTime.now)], through: port, to: destination)
        }
    }

    /// One event list per message, as a MIDI 1.0 system message in a Universal MIDI Packet.
    private static func send(_ messages: [MIDIClockSchedule.Timed], through port: MIDIPortRef, to destination: MIDIEndpointRef) {
        for timed in messages {
            var word = umpWord(timed.message)
            var list = MIDIEventList()
            let packet = MIDIEventListInit(&list, ._1_0)
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, HostTime.ticks(timed.time), 1, &word)
            MIDISendEventList(port, destination, &list)
        }
    }

    private static func umpWord(_ message: MIDIClockSchedule.Message) -> UInt32 {
        let systemMessage: UInt32 = 0x1 << 28
        switch message {
        case .clock: return systemMessage | 0xF8 << 16
        case .start: return systemMessage | 0xFA << 16
        case .stop: return systemMessage | 0xFC << 16
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
