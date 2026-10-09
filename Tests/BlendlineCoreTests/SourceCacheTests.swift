import Foundation
import Testing
@testable import BlendlineCore

struct SourceCacheTests {
    /// A full cache of tracks still loading must not evict a track the moment it is decoded for a caller.
    @Test func keepsATrackSomeoneWaitsForWhileOthersLoad() throws {
        let slow = URL(filePath: "/synthetic/slow.wav")
        let wanted = URL(filePath: "/synthetic/wanted.wav")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let sources = SourceCache(capacity: 1, sampleRate: Synth.sampleRate) { url, _ in
            if url == slow { release.wait() }
            return PCMBuffer(channels: [[0], [0]], sampleRate: Synth.sampleRate)
        }

        sources.prefetch(slow)
        let buffer = try sources.buffer(for: wanted)

        #expect(buffer.channels.count == 2)
    }
}
