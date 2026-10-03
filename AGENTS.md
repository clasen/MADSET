# MADSET

Native macOS app for building long DJ sets by dragging in many audio files. It analyzes every
track (BPM, beatgrid, kick, phases, key fallback) in parallel and lays the set out on a timeline.
Personal use: runs locally, never distributed, so GPL dependencies are acceptable.

## Stack

- Swift 6.2 tools / Swift 6 language mode, macOS 26+, Apple Silicon.
- SwiftUI for the app shell and list, AppKit (`NSView`) for the timeline, AVFoundation for decoding,
  Accelerate (vDSP) for DSP.
- Swift Package Manager only; no Xcode project. No third-party dependencies yet.

## Commands

```bash
swift build                                      # debug build of everything
swift test                                       # core test suite (Swift Testing)
./scripts/bundle.sh                              # release build wrapped in build/MADSET.app
open build/MADSET.app
swift run -c release madset-bench <folder> [--limit N] [--no-cache] [--detect-key] [--verbose]
```

`madset-bench` analyzes a folder like the app does and compares BPM/key with the Mixed In Key tags.
Use it after touching anything in `Sources/MADSETCore/Analysis`. The reference library is
`/Users/martinclasen/Stuff/MadSky/Discover` (~1000 tracks, MIK-tagged).

## Layout

- `Sources/MADSETCore/` — everything testable: tags, decoding, analysis, cache, scanning.
  - `Config/AppConfig.swift` — the centralized configuration (see below).
  - `Analysis/` — `TrackAnalyzer` orchestrates `BeatTracker`, `StructureAnalyzer`, `KeyDetector`, `WaveformBuilder`.
- `Sources/MADSET/` — the app: `SetStore` (state + analysis queue), list, `Timeline/` canvas.
- `Sources/MADSETBench/` — the benchmark CLI.
- `Tests/MADSETCoreTests/` — tests; `Synth.swift` builds deterministic synthetic tracks.
- Generated: `.build/`, `build/`. Analysis cache lives in `~/Library/Caches/MADSET/analysis`.

## Configuration

Operational settings live in `AppConfig.current` (`Sources/MADSETCore/Config/AppConfig.swift`),
read as `config.analysis.maxConcurrentTracks`. Pass the config (or its section) down; don't read
`AppConfig.current` deep inside the core. Algorithm constants (filter cutoffs, thresholds) stay
next to the algorithm as documented `static let`s.

Bump `AnalysisCache.schemaVersion` whenever `TrackAnalysis` or an analysis algorithm changes.

## Tests

Swift Testing (`import Testing`, `@Test`, `#expect`). Analysis is tested with synthetic audio from
`Synth`, not with files from disk. No mocks: the core is pure functions over arrays and files in
the temporary directory.

## Git

Agents commit only when asked. Branch from `main`; imperative, English commit messages.

## Glossary

- **Set** — the ordered list of tracks being built.
- **Beatgrid** — constant tempo + first downbeat; bars of 4 beats from there.
- **Phrase** — `phraseBars` bars (8); sections are aligned to phrases.
- **Phase** — DJ section label: intro, groove, buildup, drop, breakdown, outro.
- **Kick presence** — per bar, fraction of beats whose sub-band shape matches the track's kick template.
- **MIK** — Mixed In Key; writes key (Camelot) and energy (1–10) into the tags.
- **Camelot** — key notation 1A–12B (A minor, B major).

## Language

Code, identifiers and comments in English. UI strings in Spanish (rioplatense). Responses to the
user in Spanish.
