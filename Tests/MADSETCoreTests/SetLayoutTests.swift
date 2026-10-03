import Foundation
import Testing
@testable import MADSETCore

@Suite struct SetLayoutTests {
    private func analysis(bpm: Double = 124, bars: Int, phraseOffset: Int = 0, sections: [Section]) -> TrackAnalysis {
        let grid = BeatGrid(bpm: bpm, firstDownbeat: 0.1, phraseOffsetBars: phraseOffset, confidence: 1)
        return TrackAnalysis(
            duration: 0.1 + Double(bars) * grid.barDuration + 0.5, grid: grid, sections: sections,
            kickPresence: [], detectedKey: nil, waveform: Waveform(pointsPerSecond: 1, low: Data(), mid: Data(), high: Data())
        )
    }

    private func entry(_ id: UUID) -> SetEntry { SetEntry(id: id, file: URL(filePath: "/x/\(id).mp3")) }

    @Test func overlapsOutroWithIntroOnPhraseBoundaries() {
        let a = UUID(), b = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: [Section(phase: .drop, startBar: 0, endBar: 76), Section(phase: .outro, startBar: 76, endBar: 100)]), duration: nil),
            b: .init(analysis: analysis(bars: 120, sections: [Section(phase: .intro, startBar: 0, endBar: 16), Section(phase: .drop, startBar: 16, endBar: 120)]), duration: nil),
        ]
        let layout = SetLayout(bpm: 126, entries: [entry(a), entry(b)], tracks: tracks, phraseBars: 8)

        #expect(layout.entries[0].cueOutBar == 96)  // last phrase boundary of 100 bars
        #expect(layout.entries[1].overlapBars == 16)  // min(outro 20, intro 16) in whole phrases
        #expect(layout.entries[1].startBar == 96 - 16)
        #expect(layout.entries[1].bassSwapBar == 8)
        #expect(layout.entries[1].fadeInBars == 4 && layout.entries[1].fadeOutBars == 4)  // a quarter of the overlap
        #expect(layout.totalBars == 80 + 120)
    }

    @Test func respectsEditedValuesWithinTheTracks() {
        let a = UUID(), b = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 40, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 40, phraseOffset: 3, sections: []), duration: nil),
        ]
        var second = entry(b)
        second.overlapBars = 64
        second.bassSwapBar = 99
        second.fadeInBars = 99
        second.fadeOutBars = -3
        let layout = SetLayout(bpm: 124, entries: [entry(a), second], tracks: tracks, phraseBars: 8)

        #expect(layout.entries[1].cueInBar == 3)
        #expect(layout.entries[1].overlapBars == min(layout.entries[0].lengthBars, layout.entries[1].lengthBars) - 1)
        #expect(layout.entries[1].bassSwapBar == layout.entries[1].overlapBars)
        #expect(layout.entries[1].fadeInBars == layout.entries[1].overlapBars)
        #expect(layout.entries[1].fadeOutBars == 0)
    }

    @Test func movesTheMixInPointKeepingTheTransitionLength() {
        let a = UUID(), b = UUID(), c = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (before.entries[0], before.entries[1])
        let earlier = incoming.mixInBar(after: outgoing) - 24

        entries[0].cueOutBar = incoming.previousCueOut(mixingInAt: earlier, after: outgoing)
        entries[1].overlapBars = incoming.overlapBars
        let after = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)

        #expect(after.entries[1].mixInBar(after: after.entries[0]) == earlier)
        #expect(after.entries[1].overlapBars == incoming.overlapBars)
        #expect(after.entries[1].startBar == incoming.startBar - 24)
        #expect(after.entries[2].startBar == before.entries[2].startBar - 24)
    }

    @Test func keepsTheMixInPointInsideTheOutgoingTrack() {
        let a = UUID(), b = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, phraseOffset: 4, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        let layout = SetLayout(bpm: 124, entries: [entry(a), entry(b)], tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (layout.entries[0], layout.entries[1])

        #expect(incoming.mixInRange(after: outgoing) == 5...(100 - incoming.overlapBars))
        #expect(incoming.previousCueOut(mixingInAt: 500, after: outgoing) == 100)
        #expect(incoming.previousCueOut(mixingInAt: 0, after: outgoing) == 5 + incoming.overlapBars)
    }

    @Test func movesATrackUnderItsTransition() {
        let a = UUID(), b = UUID(), c = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        entries[1].cueInBar = 16
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (before.entries[0], before.entries[1])

        entries[1].cueInBar = incoming.cueIn(movedBy: 8, after: outgoing)
        entries[1].overlapBars = incoming.overlapBars
        let after = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)

        #expect(after.entries[0] == before.entries[0])
        #expect(after.entries[1].cueInBar == 8)
        #expect(after.entries[1].startBar == incoming.startBar)
        #expect(after.entries[1].overlapBars == incoming.overlapBars)
        // The track's audio is 8 bars later in the set, and so is everything after it.
        #expect(after.entries[1].startBar - after.entries[1].cueInBar == incoming.startBar - incoming.cueInBar + 8)
        #expect(after.entries[2].startBar == before.entries[2].startBar + 8)
    }

    @Test func movingATrackUnderItsTransitionKeepsABarOfItsAudioInIt() {
        let a = UUID(), b = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 40, phraseOffset: 4, sections: []), duration: nil),
        ]
        let layout = SetLayout(bpm: 124, entries: [entry(a), entry(b)], tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (layout.entries[0], layout.entries[1])

        // Later: silence before the track fills all but the transition's last bar.
        #expect(incoming.cueIn(movedBy: 1000, after: outgoing) == -(incoming.overlapBars - 1))
        // Earlier: the track keeps a bar of its own after the transition.
        #expect(incoming.cueIn(movedBy: -1000, after: outgoing) == incoming.cueOutBar - 1 - incoming.overlapBars)
    }

    @Test func movesTheTransitionWithoutMovingTheTracks() {
        let a = UUID(), b = UUID(), c = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 96, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (before.entries[0], before.entries[1])
        #expect(outgoing.cueOutBar == outgoing.barCount && incoming.cueInBar == 0)

        // The outgoing track has no audio left, so the moved transition ends in its silence.
        let (cueOut, cueIn) = incoming.movingTransition(by: 8, after: outgoing)
        entries[0].cueOutBar = cueOut
        entries[1].cueInBar = cueIn
        entries[1].overlapBars = incoming.overlapBars
        let after = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)

        #expect(after.entries[0].cueOutBar == 104)
        #expect(after.entries[1].cueInBar == 8)
        #expect(after.entries[1].overlapBars == incoming.overlapBars)
        #expect(after.entries[1].startBar == incoming.startBar + 8)
        // Neither track's audio moves, and nothing after them does.
        #expect(after.entries[0].startBar == outgoing.startBar)
        #expect(after.entries[1].startBar - after.entries[1].cueInBar == incoming.startBar - incoming.cueInBar)
        #expect(after.entries[2].startBar == before.entries[2].startBar)
    }

    @Test func keepsAudioOfBothTracksInAMovedTransition() {
        let a = UUID(), b = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 96, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b)]
        entries[1].overlapBars = 16
        let layout = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (layout.entries[0], layout.entries[1])

        let latest = incoming.movingTransition(by: 1000, after: outgoing)
        #expect(latest.previousCueOut == 96 + 15)
        let earliest = incoming.movingTransition(by: -1000, after: outgoing)
        #expect(earliest.cueIn == -15)
    }

    @Test func resizesTheTransitionOnBothSidesWithoutMovingTheTracks() {
        let a = UUID(), b = UUID(), c = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        entries[0].cueOutBar = 92
        entries[1].cueInBar = 16
        entries[1].overlapBars = 16
        entries[1].bassSwapBar = 8
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (before.entries[0], before.entries[1])

        func apply(_ length: Int) -> SetLayout {
            let resized = incoming.resizingTransition(to: length, after: outgoing)
            var edited = entries
            edited[0].cueOutBar = resized.previousCueOut
            edited[1].cueInBar = resized.cueIn
            edited[1].overlapBars = resized.overlap
            edited[1].bassSwapBar = resized.bassSwap
            return SetLayout(bpm: 124, entries: edited, tracks: tracks, phraseBars: 8)
        }
        func audioStart(_ placed: PlacedEntry) -> Int { placed.startBar - placed.cueInBar }

        // Half on each side.
        let longer = apply(24)
        #expect(longer.entries[0].cueOutBar == 96)
        #expect(longer.entries[1].cueInBar == 12)
        #expect(longer.entries[1].overlapBars == 24)
        // The outgoing track has no audio past bar 100, so the incoming side takes the rest.
        let longest = apply(48)
        #expect(longest.entries[0].cueOutBar == 100)
        #expect(longest.entries[1].cueInBar == 0)
        #expect(longest.entries[1].overlapBars == 16 + 8 + 16)

        for layout in [longer, longest, apply(8), apply(0)] {
            #expect(layout.entries[0].startBar == outgoing.startBar)
            #expect(audioStart(layout.entries[1]) == audioStart(incoming))
            #expect(layout.entries[1].startBar + layout.entries[1].bassSwapBar == incoming.startBar + incoming.bassSwapBar || layout.entries[1].overlapBars < 8)
            #expect(layout.entries[2].startBar == before.entries[2].startBar)
        }
        #expect(incoming.transitionLengths(after: outgoing) == 0...40)
    }

    @Test func trimmingTheStartShortensTheTransitionWithoutMovingAnything() {
        let a = UUID(), b = UUID(), c = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 96, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        entries[1].overlapBars = 32
        entries[1].bassSwapBar = 16
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (before.entries[0], before.entries[1])

        let (cueIn, overlap, swap) = incoming.trimmingStart(by: 8, after: outgoing)
        entries[1].cueInBar = cueIn
        entries[1].overlapBars = overlap
        entries[1].bassSwapBar = swap
        let after = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)

        #expect(after.entries[0] == outgoing)
        #expect(after.entries[1].overlapBars == 24)
        #expect(after.entries[1].startBar == incoming.startBar + 8)
        #expect(after.entries[1].startBar - after.entries[1].cueInBar == incoming.startBar - incoming.cueInBar)
        #expect(after.entries[1].startBar + after.entries[1].bassSwapBar == incoming.startBar + incoming.bassSwapBar)
        #expect(after.entries[2].startBar == before.entries[2].startBar)

        // Past the swap it stays at the transition's start; it never grows into silence before the track.
        #expect(incoming.trimmingStart(by: 24, after: outgoing).bassSwap == 0)
        #expect(incoming.trimmingStart(by: 1000, after: outgoing).overlap == 0)
        #expect(incoming.trimmingStart(by: -1000, after: outgoing).cueIn == 0)
    }

    @Test func trimmingTheEndShortensTheTransitionWithoutMovingAnything() {
        let a = UUID(), b = UUID(), c = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        entries[0].cueOutBar = 96
        entries[1].overlapBars = 32
        entries[1].bassSwapBar = 8
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let (outgoing, incoming) = (before.entries[0], before.entries[1])

        let (cueOut, overlap, swap) = outgoing.trimmingEnd(by: -16, before: incoming)
        entries[0].cueOutBar = cueOut
        entries[1].overlapBars = overlap
        entries[1].bassSwapBar = swap
        let after = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)

        #expect(after.entries[0].cueOutBar == 80)
        #expect(after.entries[1].overlapBars == 16)
        #expect(after.entries[1].startBar == incoming.startBar)
        #expect(after.entries[1].bassSwapBar == 8)
        #expect(after.entries[2].startBar == before.entries[2].startBar)

        // It grows only up to the outgoing track's audio, and can shrink down to playing end to end.
        #expect(outgoing.trimmingEnd(by: 1000, before: incoming).cueOut == 100)
        #expect(outgoing.trimmingEnd(by: -1000, before: incoming).nextOverlap == 0)
        #expect(outgoing.trimmingEnd(by: -24, before: incoming).nextBassSwap == 8)
        #expect(outgoing.trimmingEnd(by: -28, before: incoming).nextBassSwap == 4)
    }

    @Test func trimmingTheLastTrackKeepsItsTransitionIn() {
        let a = UUID(), b = UUID()
        let tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        let layout = SetLayout(bpm: 124, entries: [entry(a), entry(b)], tracks: tracks, phraseBars: 8)
        let last = layout.entries[1]

        #expect(last.trimmingEnd(by: -1000, before: nil).cueOut == last.cueInBar + last.overlapBars + 1)
        #expect(last.trimmingEnd(by: 1000, before: nil).cueOut == last.barCount)
    }

    @Test func splittingATrackKeepsTheSetAsItWas() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 100, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 120, sections: []), duration: nil),
            c: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var entries = [entry(a), entry(b), entry(c)]
        let before = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)
        let whole = before.entries[1]
        let range = try #require(whole.splitRange(before: before.entries[2]))
        #expect(range == (whole.cueInBar + whole.overlapBars + 1)...(whole.cueOutBar - before.entries[2].overlapBars - 1))

        let second = entries[1].split(atBar: 64)
        entries.insert(second, at: 2)
        tracks[second.id] = tracks[b]
        let after = SetLayout(bpm: 124, entries: entries, tracks: tracks, phraseBars: 8)

        let (first, rest) = (after.entries[1], after.entries[2])
        #expect(first.startBar == whole.startBar && first.cueInBar == whole.cueInBar && first.overlapBars == whole.overlapBars)
        #expect(first.cueOutBar == 64 && rest.cueInBar == 64 && rest.cueOutBar == whole.cueOutBar)
        #expect(rest.overlapBars == 0 && rest.startBar == first.endBar)
        #expect(after.entries[0] == before.entries[0])
        #expect(after.entries[3].startBar == before.entries[2].startBar && after.entries[3].overlapBars == before.entries[2].overlapBars)
        #expect(after.totalBars == before.totalBars)
    }

    @Test func splitPartsArrangeLikeTwoTracks() {
        let a = UUID(), b = UUID()
        var tracks: [UUID: SetLayout.TrackInfo] = [
            a: .init(analysis: analysis(bars: 120, sections: []), duration: nil),
            b: .init(analysis: analysis(bars: 80, sections: []), duration: nil),
        ]
        var first = entry(a)
        let second = first.split(atBar: 64)
        tracks[second.id] = tracks[a]
        let layout = SetLayout(bpm: 124, entries: [first, entry(b), second], tracks: tracks, phraseBars: 8)

        #expect(layout.entries[1].overlapBars > 0)
        #expect(layout.entries[2].overlapBars > 0)
        #expect(layout.entries[2].cueInBar == 64)
    }

    @Test func unanalyzedTracksTakeTheirHeaderLength() {
        let a = UUID()
        let layout = SetLayout(bpm: 120, entries: [entry(a)], tracks: [a: .init(analysis: nil, duration: 60)], phraseBars: 8)
        #expect(layout.entries[0].lengthBars == 30)
        #expect(layout.entries[0].grid == nil)
    }

    @Test func suggestsTheMedianTempo() {
        #expect(SetLayout.suggestedBPM([122, 124.3, 126, 140, 118]) == 124.5)
        #expect(SetLayout.suggestedBPM([]) == nil)
    }
}

@Suite struct SetFileTests {
    @Test func roundTripsTheArrangement() throws {
        let file = SetFile(bpm: 126.5, entries: [
            SetEntry(file: URL(filePath: "/Music/a b/one.mp3")),
            SetEntry(file: URL(filePath: "/Music/two.aiff"), cueInBar: 8, cueOutBar: 120, overlapBars: 24, bassSwapBar: 12, fadeInBars: 6, fadeOutBars: 24),
        ])
        #expect(try SetFile.decode(try file.encoded()) == file)
    }

    @Test func rejectsUnknownVersions() throws {
        var json = try JSONSerialization.jsonObject(with: try SetFile(bpm: nil, entries: []).encoded()) as! [String: Any]
        json["version"] = 99
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: SetFile.Failure.unsupportedVersion(99)) { try SetFile.decode(data) }
    }
}
