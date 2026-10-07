import Testing
@testable import MADSETCore

struct PhaseAlignmentTests {
    /// 120 BPM at 44.1 kHz.
    private let framesPerBeat = 22_050.0

    @Test func startMovesAheadToTheReferencesPlaceInTheBar() {
        // Bar 10 at 0.5 s per beat is beat 40; the reference is about to play the third beat of a bar.
        let start = PhaseAlignment.start(20, beatDuration: 0.5, inPhaseWith: 6)
        #expect(start == 21)
        #expect(PhaseAlignment.start(20, beatDuration: 0.5, inPhaseWith: 8) == 20)
        // Never moves back, never a bar or more ahead.
        #expect(PhaseAlignment.start(20.25, beatDuration: 0.5, inPhaseWith: 3) == 21.5)
    }

    @Test func startsWithinTheBufferWhereTheReferenceReachesTheSamePlaceInTheBar() {
        let frames = 512
        // The reference is 100 frames short of beat 7; starting at beat 43 (third beat of a bar) matches it there.
        let referenceBeat = 7 - 100 / framesPerBeat
        #expect(PhaseAlignment.offset(startBeat: 43, referenceBeat: referenceBeat, framesPerBeat: framesPerBeat, frames: frames) == 100)
        // On the downbeat of another bar it is a beat away: wait.
        #expect(PhaseAlignment.offset(startBeat: 40, referenceBeat: referenceBeat, framesPerBeat: framesPerBeat, frames: frames) == nil)
    }

    @Test func aStartThatJustWentBySkipsAheadInsteadOfWaitingABar() {
        let referenceBeat = 7 + 200 / framesPerBeat
        #expect(PhaseAlignment.offset(startBeat: 43, referenceBeat: referenceBeat, framesPerBeat: framesPerBeat, frames: 512) == -200)
        #expect(PhaseAlignment.offset(startBeat: 43, referenceBeat: 7 + 600 / framesPerBeat, framesPerBeat: framesPerBeat, frames: 512) == nil)
    }
}
