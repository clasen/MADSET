import Foundation
import Testing
@testable import BlendlineCore

@Suite struct MIDIClockTests {
    /// 120 BPM: a beat every 0.5 s, a clock every 1/48 s.
    private let beatsPerSecond = 2.0
    private let lookahead = 0.03

    /// The playhead at `beat` heard at host time `hostTime`.
    private func position(beat: Double, at hostTime: Double, beatsPerSecond: Double? = nil) -> PlayheadClock.Position {
        PlayheadClock.Position(beat: beat, hostTime: hostTime, beatsPerSecond: beatsPerSecond ?? self.beatsPerSecond)
    }

    private func clockTimes(_ batch: MIDIClockSchedule.Batch) -> [Double] {
        batch.messages.filter { $0.message == .clock }.map(\.time)
    }

    @Test func startsAtTheSetsStartAndClocksOnTheBeats() {
        var schedule = MIDIClockSchedule()
        var times: [Double] = []
        var messages: [MIDIClockSchedule.Message] = []
        // The set starts being heard at 100.01 s; the thread looks every 5 ms for a second.
        for step in 0..<200 {
            let now = 100 + Double(step) * 0.005
            let batch = schedule.advance(to: position(beat: 0, at: 100.01), now: now, lookahead: lookahead)
            #expect(!batch.flush)
            messages += batch.messages.map(\.message)
            times += clockTimes(batch)
        }
        #expect(messages.first == .start)
        #expect(!messages.dropFirst().contains { $0 != .clock })
        #expect(abs(times[0] - 100.01) < 1e-9)
        #expect(abs(times[24] - 100.51) < 1e-9)
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs(b - a - 1.0 / 48) < 1e-9) }
    }

    @Test func resumesMidSetWithStartOnTheNextBar() {
        var schedule = MIDIClockSchedule()
        // Beat 10.1 is heard at 50 s: the next bar starts at beat 12, heard at 50.95 s.
        let playhead = position(beat: 10.1, at: 50)
        #expect(schedule.advance(to: playhead, now: 50, lookahead: lookahead) == MIDIClockSchedule.Batch())
        #expect(!schedule.isRunning)
        let batch = schedule.advance(to: playhead, now: 50.93, lookahead: lookahead)
        #expect(batch.messages.map(\.message) == [.start, .clock])
        #expect(batch.messages.allSatisfy { abs($0.time - 50.95) < 1e-9 })
    }

    @Test func startsOnTheBarOfWhereThePlayheadMovedWhileWaiting() {
        var schedule = MIDIClockSchedule()
        _ = schedule.advance(to: position(beat: 1, at: 10), now: 10, lookahead: lookahead)
        // Before bar 1 (beat 4) comes, the playhead jumps to beat 33, so the start waits for beat 36, heard at 12 s.
        let moved = position(beat: 33, at: 10.5)
        #expect(schedule.advance(to: moved, now: 11.96, lookahead: lookahead) == MIDIClockSchedule.Batch())
        let batch = schedule.advance(to: moved, now: 11.98, lookahead: lookahead)
        #expect(batch.messages.first?.message == .start)
        #expect(abs((batch.messages.first?.time ?? 0) - 12) < 1e-9)
    }

    @Test func stopsWhenPausedAndRestartsAfterAJump() {
        var schedule = MIDIClockSchedule()
        _ = schedule.advance(to: position(beat: 0, at: 0), now: 0, lookahead: lookahead)

        let paused = schedule.advance(to: nil, now: 1, lookahead: lookahead)
        #expect(paused.flush)
        #expect(paused.messages.map(\.message) == [.stop])
        #expect(schedule.advance(to: nil, now: 2, lookahead: lookahead) == MIDIClockSchedule.Batch())

        let resumed = schedule.advance(to: position(beat: 4, at: 3), now: 3, lookahead: lookahead)
        #expect(Array(resumed.messages.prefix(2).map(\.message)) == [.start, .clock])
        // A jump to beat 64.5: Stop now, Start when bar 17 (beat 68) is heard at 4.85 s.
        let jumped = schedule.advance(to: position(beat: 64.5, at: 3.1), now: 3.1, lookahead: lookahead)
        #expect(jumped.flush)
        #expect(jumped.messages.map(\.message) == [.stop])
        let restarted = schedule.advance(to: position(beat: 64.5, at: 3.1), now: 4.84, lookahead: lookahead)
        #expect(restarted.messages.first?.message == .start)
        #expect(abs((restarted.messages.first?.time ?? 0) - 4.85) < 1e-9)
    }

    @Test func goesOnClockingThroughAJumpByWholeBars() {
        var schedule = MIDIClockSchedule()
        var times: [Double] = []
        var messages: [MIDIClockSchedule.Message] = []
        // Heard from beat 0 at 0 s; at 2 s, on the line of bar 1, the playhead goes on from bar 10 (beat 40).
        for step in 0..<800 {
            let now = Double(step) * 0.005
            let playhead = now < 2 ? position(beat: 0, at: 0) : position(beat: 40, at: 2)
            let batch = schedule.advance(to: playhead, now: now, lookahead: lookahead)
            #expect(!batch.flush)
            messages += batch.messages.map(\.message)
            times += clockTimes(batch)
        }
        #expect(messages.first == .start)
        #expect(!messages.dropFirst().contains { $0 != .clock })
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs(b - a - 1.0 / 48) < 1e-9) }
    }

    @Test func followsATempoChangeWithoutRestarting() {
        var schedule = MIDIClockSchedule()
        var times: [Double] = []
        for step in 0..<100 {
            let now = Double(step) * 0.005
            times += clockTimes(schedule.advance(to: position(beat: 0, at: 0), now: now, lookahead: lookahead))
        }
        // At 0.5 s (beat 1) the set goes from 120 to 150 BPM.
        let faster = position(beat: 1, at: 0.5, beatsPerSecond: 2.5)
        var later: [MIDIClockSchedule.Message] = []
        for step in 100..<200 {
            let batch = schedule.advance(to: faster, now: Double(step) * 0.005, lookahead: lookahead)
            #expect(!batch.flush)
            later += batch.messages.map(\.message)
            times += clockTimes(batch)
        }
        #expect(!later.contains { $0 != .clock })
        let afterChange = times.filter { $0 > 0.6 }
        for (a, b) in zip(afterChange, afterChange.dropFirst()) { #expect(abs(b - a - 1.0 / 60) < 1e-9) }
    }
}
