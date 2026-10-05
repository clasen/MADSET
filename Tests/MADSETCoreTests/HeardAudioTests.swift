import Testing
@testable import MADSETCore

struct HeardAudioTests {
    private let sampleRate = 1_000.0
    private let frames = 256

    /// Frame n of the written audio has the value n, on both channels.
    private func counting(_ total: Int) -> HeardAudio {
        let heard = HeardAudio(sampleRate: sampleRate, writeAhead: frames)
        let samples = (0..<total).map(Float.init)
        samples.withUnsafeBufferPointer { heard.write(left: $0.baseAddress!, right: $0.baseAddress!, frames: total) }
        return heard
    }

    private func mix(_ heard: HeardAudio, at time: Double, gain: Float = 1, cursor: Int?) -> (samples: [Float], cursor: Int?) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let next = left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                heard.mix(into: l.baseAddress!, r.baseAddress!, frames: frames, heardAt: time, gain: (gain, gain), cursor: cursor)
            }
        }
        return (left, next)
    }

    @Test func mixesWhatIsHeardAtTheSameTime() {
        let heard = counting(1_000)
        heard.publish(frame: 200, heardAt: 10)
        // Half a second after frame 200 is heard, frame 700 is.
        let found = mix(heard, at: 10.5, cursor: nil)
        #expect(found.cursor == 700 + frames)
        // Finding its place, it fades in, then plays the frames as they are.
        #expect(found.samples[0] == 0)
        #expect(Array(found.samples[SetRenderer.declickFrames...]) == (700 + SetRenderer.declickFrames..<700 + frames).map(Float.init))
    }

    @Test func carriesOnThroughDriftAndCatchesUpBeyondIt() {
        let heard = counting(1_000)
        heard.publish(frame: 0, heardAt: 100)
        // The reader's clock says 20 frames later than where it left off: it carries on, no fade.
        let carried = mix(heard, at: 100.3, cursor: 280)
        #expect(carried.cursor == 280 + frames)
        #expect(carried.samples == (280..<280 + frames).map(Float.init))
        // 100 frames off is more than drift: it goes where the time says, fading in.
        let caught = mix(heard, at: 100.3, cursor: 200)
        #expect(caught.cursor == 300 + frames)
        #expect(caught.samples[0] == 0)
    }

    @Test func addsNothingWhileNothingIsHeardOrTheAudioIsNotThere() {
        let heard = counting(1_000)
        #expect(mix(heard, at: 1, cursor: nil).cursor == nil)
        heard.publish(frame: 0, heardAt: 100)
        // Past what has been written.
        #expect(mix(heard, at: 100.9, cursor: nil).cursor == nil)
        heard.silence()
        #expect(mix(heard, at: 100.1, cursor: nil).samples.allSatisfy { $0 == 0 })
    }

    @Test func cueMixGoesFromTheMonitorToTheMainAtEqualPower() {
        #expect(CueMix.gains(level: 1, mix: 0) == (1, 0))
        let main = CueMix.gains(level: 1, mix: 1)
        #expect(abs(main.own) < 1e-6 && main.reference == 1)
        let middle = CueMix.gains(level: 1, mix: 0.5)
        #expect(abs(middle.own * middle.own + middle.reference * middle.reference - 1) < 1e-6)
        #expect(CueMix.gains(level: 0.5, mix: 0) == (0.25, 0))
    }
}
