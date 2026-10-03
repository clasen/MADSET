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
        let layout = SetLayout(bpm: 124, entries: [entry(a), second], tracks: tracks, phraseBars: 8)

        #expect(layout.entries[1].cueInBar == 3)
        #expect(layout.entries[1].overlapBars == min(layout.entries[0].lengthBars, layout.entries[1].lengthBars) - 1)
        #expect(layout.entries[1].bassSwapBar == layout.entries[1].overlapBars)
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
            SetEntry(file: URL(filePath: "/Music/two.aiff"), cueInBar: 8, cueOutBar: 120, overlapBars: 24, bassSwapBar: 12),
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
