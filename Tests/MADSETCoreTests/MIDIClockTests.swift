import Foundation
import Testing
@testable import MADSETCore

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
        #expect(Array(messages.prefix(2)) == [.songPosition(0), .start])
        #expect(!messages.dropFirst(2).contains { $0 != .clock })
        #expect(abs(times[0] - 100.01) < 1e-9)
        #expect(abs(times[24] - 100.51) < 1e-9)
        for (a, b) in zip(times, times.dropFirst()) { #expect(abs(b - a - 1.0 / 48) < 1e-9) }
    }

    @Test func resumesMidSetAtTheNextSixteenth() {
        var schedule = MIDIClockSchedule()
        // Beat 10.1 is heard at 50 s: the next sixteenth is beat 10.25, song position 41, heard at 50.075 s.
        let batch = schedule.advance(to: position(beat: 10.1, at: 50), now: 50, lookahead: 0.1)
        #expect(Array(batch.messages.prefix(2).map(\.message)) == [.songPosition(41), .continue])
        #expect(abs(clockTimes(batch)[0] - 50.075) < 1e-9)
    }

    @Test func stopsWhenPausedAndRestartsAfterAJump() {
        var schedule = MIDIClockSchedule()
        _ = schedule.advance(to: position(beat: 0, at: 0), now: 0, lookahead: lookahead)

        let paused = schedule.advance(to: nil, now: 1, lookahead: lookahead)
        #expect(paused.flush)
        #expect(paused.messages.map(\.message) == [.stop])
        #expect(schedule.advance(to: nil, now: 2, lookahead: lookahead) == MIDIClockSchedule.Batch())

        _ = schedule.advance(to: position(beat: 2, at: 3), now: 3, lookahead: lookahead)
        let jumped = schedule.advance(to: position(beat: 64, at: 3.1), now: 3.1, lookahead: lookahead)
        #expect(jumped.flush)
        #expect(Array(jumped.messages.prefix(3).map(\.message)) == [.stop, .songPosition(256), .continue])
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

    @Test func songPositionWrapsEvery1024Bars() {
        var schedule = MIDIClockSchedule()
        let batch = schedule.advance(to: position(beat: 4 * 1_025, at: 0), now: 0, lookahead: lookahead)
        #expect(batch.messages.first?.message == .songPosition(16))
    }
}
