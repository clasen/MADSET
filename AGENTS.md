# MADSET

Native macOS app for building DJ sets and playing them live. Drag in many audio files: it analyzes
every track (BPM, beatgrid, kick, phases, key and energy fallback) in parallel and lays out a set that's already
mixed on a timeline, which you keep editing while it plays. MIDI clock out syncs a groovebox to the set.
Personal use: runs locally, never distributed, so GPL dependencies are acceptable.

## Stack

- Swift 6.2 tools / Swift 6 language mode, macOS 15+, Apple Silicon.
- SwiftUI for the app shell and list, AppKit (`NSView`) for the timeline, AVFoundation for decoding,
  Accelerate (vDSP) for DSP.
- Swift Package Manager only; no Xcode project.
- Rubber Band Library v4.0.0 (GPL-2.0-or-later) vendored unmodified in `Vendor/RubberBand`, built as the
  `CRubberBand` C++ target through its single-file build. Real-time time-stretching for playback.

## Commands

```bash
swift build                                      # debug build of everything
swift test                                       # core test suite (Swift Testing)
./scripts/bundle.sh                              # release build wrapped in build/MADSET.app
open build/MADSET.app
./scripts/release.sh                             # signed, notarized build/MADSET-<version>.dmg
swift run -c release madset-bench <folder> [--limit N] [--no-cache] [--detect-key] [--verbose]
```

`madset-bench` analyzes a folder like the app does and compares BPM/key with the Mixed In Key tags.
Use it after touching anything in `Sources/MADSETCore/Analysis`. The reference library is
`/Users/martinclasen/Stuff/MadSky/Discover` (~1000 tracks, MIK-tagged).

## Layout

- `Sources/MADSETCore/` — everything testable: tags, decoding, analysis, cache, scanning.
  - `Config/AppConfig.swift` — the centralized configuration (see below).
  - `Analysis/` — `TrackAnalyzer` orchestrates `BeatTracker`, `StructureAnalyzer`, `KeyDetector`, `EnergyEstimator`, `WaveformBuilder`.
  - `Set/` — `SetEntry`/`SetLayout` (arrangement on the set's bar axis, automatic phase-aligned
    transitions) and `SetFile` (the `.madset` JSON format).
  - `Playback/` — `SetRenderer` mixes a layout block by block (stretch, DJ EQ, transition curves);
    `SetPlayer` plays it through AVAudioEngine from a producer thread and a lock-free ring buffer.
- `Sources/MADSET/` — the app: `SetDocument` (SwiftUI `DocumentGroup` document: arrangement, undo,
  analysis queue, playback), list, transport, `Timeline/` canvas.
- `Localization/<lang>.lproj/Localizable.strings` — UI translations, copied into the bundle by `bundle.sh`.
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

Branch from `main`; imperative, English commit messages.

## Glossary

- **Set** — the ordered list of tracks being built.
- **Beatgrid** — constant tempo + first downbeat; bars of 4 beats from there.
- **Phrase** — `phraseBars` bars (8); sections are aligned to phrases.
- **Phase** — DJ section label: intro, groove, buildup, drop, breakdown, outro.
- **Kick presence** — per bar, fraction of beats whose sub-band shape matches the track's kick template.
- **Set tempo** — the global BPM every track is stretched to.
- **Cue in / cue out** — first and last (exclusive) bar of a track that plays in the set.
- **Overlap / transition** — bars a track plays over the previous one; **bass swap** — bar within the
  overlap where the lows switch from the outgoing to the incoming track.
- **MIK** — Mixed In Key; writes key (Camelot) and energy (1–10) into the tags.
- **Camelot** — key notation 1A–12B (A minor, B major).

## Language

Code, identifiers and comments in English. The UI ships in English and Spanish (rioplatense): write UI
strings in English (`Text("…")`, `String(localized:)`) and add the Spanish to
`Localization/es.lproj/Localizable.strings`. To find missing translations, build with
`-Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>` and compare the
keys. Responses to the user in Spanish.
