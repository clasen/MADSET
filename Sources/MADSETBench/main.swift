import Foundation
import MADSETCore

// Usage: madset-bench <folder> [--limit N] [--no-cache] [--detect-key] [--verbose] [--order]
// Analyzes the folder like the app does and compares results with the Mixed In Key tags.
// --order also prints the tracks ordered along the set curve.

let arguments = Array(CommandLine.arguments.dropFirst())
guard let folder = arguments.first else {
    print("usage: madset-bench <folder> [--limit N] [--no-cache] [--detect-key] [--verbose] [--order]")
    exit(2)
}
let limit = arguments.firstIndex(of: "--limit").flatMap { Int(arguments[$0 + 1]) }
let useCache = !arguments.contains("--no-cache")
let forceKeyDetection = arguments.contains("--detect-key")
let verbose = arguments.contains("--verbose")
let printsOrder = arguments.contains("--order")

let config = AppConfig.current
var files = AudioFileScanner.audioFiles(in: [URL(filePath: folder)])
if let limit, limit < files.count {
    let step = Double(files.count) / Double(limit)
    files = (0..<limit).map { files[Int(Double($0) * step)] }
}
let pipeline = AnalysisPipeline(config: config.analysis, cache: useCache ? try AnalysisCache.userCaches(config: config) : nil)

struct Row: Sendable {
    let url: URL
    let tags: TrackTags?
    let result: Result<AnalysisPipeline.Outcome, any Error>
    let seconds: Double
}

let clock = ContinuousClock()
let started = clock.now
var rows: [Row] = []
await forEachConcurrently(files, limit: config.analysis.maxConcurrentTracks, operation: { url -> Row in
    let t0 = ContinuousClock.now
    let tags = try? MIKTags.read(url: url)
    let needsKey = forceKeyDetection || tags?.key == nil
    let result: Result<AnalysisPipeline.Outcome, any Error>
    do { result = .success(try await pipeline.analyze(url: url, needsKey: needsKey)) } catch { result = .failure(error) }
    return Row(url: url, tags: tags, result: result, seconds: (ContinuousClock.now - t0) / .seconds(1))
}, onResult: { _, row in
    rows.append(row)
    if verbose { report(row) }
})
let wall = (clock.now - started) / .seconds(1)

func report(_ row: Row) {
    let name = row.url.deletingPathExtension().lastPathComponent.prefix(60)
    switch row.result {
    case .failure(let error):
        print("FAIL  \(name): \(error)")
    case .success(let outcome):
        let a = outcome.analysis
        let tagBPM = row.tags?.bpm.map { String(format: "%.0f", $0) } ?? "-"
        let phases = a.sections.map { "\($0.phase.rawValue.prefix(4))\($0.endBar - $0.startBar)" }.joined(separator: " ")
        print(String(format: "%6.2fs %@ bpm %7.3f (tag %@) conf %.2f  key %@/%@  | %@ | %@",
                     row.seconds, outcome.fromCache ? "C" : " ", a.grid.bpm, tagBPM, a.grid.confidence,
                     row.tags?.key?.description ?? "-", a.detectedKey?.description ?? "-", phases, String(name)))
    }
}

enum BPMMatch { case exact, octave, mismatch, untagged }
func bpmMatch(_ ours: Double, _ tag: Double?) -> BPMMatch {
    guard let tag else { return .untagged }
    if abs(ours - tag) < 0.6 { return .exact }
    if abs(ours * 2 - tag) < 1 || abs(ours / 2 - tag) < 0.6 { return .octave }
    return .mismatch
}

let successes = rows.compactMap { row -> (Row, TrackAnalysis)? in
    if case .success(let o) = row.result { return (row, o.analysis) }
    return nil
}
let failures = rows.count - successes.count
var matches: [BPMMatch: Int] = [:]
for (row, a) in successes { matches[bpmMatch(a.grid.bpm, row.tags?.bpm), default: 0] += 1 }
let audioSeconds = successes.map { $0.1.duration }.reduce(0, +)

print("")
print(String(format: "tracks %d (failed %d)  wall %.1fs  %.2f tracks/s  audio %.1f h", rows.count, failures, wall, Double(rows.count) / wall, audioSeconds / 3600))
print("bpm vs tag: exact \(matches[.exact, default: 0])  octave \(matches[.octave, default: 0])  mismatch \(matches[.mismatch, default: 0])  untagged \(matches[.untagged, default: 0])")

if forceKeyDetection {
    var exact = 0, relative = 0, neighbor = 0, compared = 0
    for (row, a) in successes {
        guard let tag = row.tags?.key, let detected = a.detectedKey else { continue }
        compared += 1
        if tag == detected { exact += 1 }
        else if tag.number == detected.number { relative += 1 }
        else if tag.mode == detected.mode && (abs(tag.number - detected.number) == 1 || abs(tag.number - detected.number) == 11) { neighbor += 1 }
    }
    print("key vs tag (\(compared)): exact \(exact)  relative \(relative)  fifth \(neighbor)")
}

var phaseCounts: [Phase: Int] = [:]
for (_, a) in successes { for s in a.sections { phaseCounts[s.phase, default: 0] += 1 } }
print("sections: " + Phase.allCases.map { "\($0.rawValue) \(phaseCounts[$0, default: 0])" }.joined(separator: "  "))

let mismatches = successes.filter { bpmMatch($0.1.grid.bpm, $0.0.tags?.bpm) == .mismatch }
if !mismatches.isEmpty {
    print("\nbpm mismatches:")
    for (row, _) in mismatches.prefix(30) { report(row) }
}
for row in rows { if case .failure = row.result { report(row) } }

if printsOrder {
    let items = successes.map { row, a in SetOrder.Item(key: row.tags?.key ?? a.detectedKey, energy: row.tags?.energy, bpm: a.grid.bpm) }
    let t0 = ContinuousClock.now
    let order = SetOrder.order(items, by: .setCurve, after: nil, peakPosition: config.ordering.peakPosition)
    let seconds = (ContinuousClock.now - t0) / .seconds(1)
    print("\nset curve:")
    var steps: [Int: Int] = [:]
    for (position, index) in order.enumerated() {
        let item = items[index]
        var step: Int?
        if position > 0, let from = items[order[position - 1]].key, let to = item.key { step = SetOrder.keyDistance(from, to) }
        if let step { steps[step, default: 0] += 1 }
        print(String(format: "%3d  E%@ %@ %6.2f  %@  %@", position + 1, item.energy.map(String.init) ?? "-", (item.key?.description ?? "-").padding(toLength: 3, withPad: " ", startingAt: 0),
                     item.bpm ?? 0, step.map { "+\($0)" } ?? "  ", String(successes[index].0.url.deletingPathExtension().lastPathComponent.prefix(50))))
    }
    print(String(format: "ordered %d in %.2fs  key steps: ", order.count, seconds) + steps.keys.sorted().map { "\($0): \(steps[$0]!)" }.joined(separator: "  "))
}
