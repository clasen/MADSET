import AppKit
import CoreMIDI
import BlendlineCore
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Devices", systemImage: "hifispeaker") {
                DevicesSettings(settings: .shared)
            }
        }
        .frame(width: 560)
    }
}

/// The UI language. macOS picks it at launch from `AppleLanguages`, so a change applies on restart.
private struct GeneralSettings: View {
    private static let languageKey = "language"
    private static let launchLanguage = UserDefaults.standard.string(forKey: languageKey)

    /// Language code of a bundled localization; nil follows the system.
    @State private var language = UserDefaults.standard.string(forKey: languageKey)

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("System").tag(String?.none)
                    Divider()
                    ForEach(Set(Bundle.main.localizations).subtracting(["Base"]).sorted(), id: \.self) { code in
                        Text(Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code)
                            .tag(String?.some(code))
                    }
                }
                .onChange(of: language) { _, language in
                    UserDefaults.standard.set(language, forKey: Self.languageKey)
                    UserDefaults.standard.set(language.map { [$0] }, forKey: "AppleLanguages")
                }
            } footer: {
                if language != Self.launchLanguage {
                    HStack {
                        Text("The new language shows after a restart.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now", action: Self.relaunch)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Quits, saving the open sets, and opens the app again once this process has exited.
    private static func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(filePath: "/bin/sh")
        reopen.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; open \"$0\"",
            Bundle.main.bundlePath,
        ]
        try? reopen.run()
        NSApp.terminate(nil)
    }
}

/// Audio outputs and MIDI clock out.
private struct DevicesSettings: View {
    @Bindable var settings: DeviceSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Main Output") {
                    HStack {
                        Picker("Main Output", selection: $settings.mainOutput) {
                            Text("System Default").tag(String?.none)
                            Divider()
                            outputs(keeping: settings.mainOutput)
                        }
                        channels(of: settings.mainOutput, selection: $settings.mainChannel)
                    }
                    .labelsHidden()
                }
                LabeledContent("Monitor Output") {
                    HStack {
                        Picker("Monitor Output", selection: $settings.monitorOutput) {
                            Text("None").tag(String?.none)
                            Divider()
                            outputs(keeping: settings.monitorOutput)
                        }
                        channels(of: settings.monitorOutput, selection: $settings.monitorChannel)
                    }
                    .labelsHidden()
                }
                Group {
                    LabeledContent("Headphones Level") {
                        Slider(value: $settings.monitorLevel, in: 0...1)
                    }
                    LabeledContent("Cue Mix") {
                        HStack {
                            Text("Monitor").foregroundStyle(.secondary)
                            Slider(value: $settings.cueMix, in: 0...1)
                            Text("Main").foregroundStyle(.secondary)
                        }
                    }
                    .help(String(localized: "What the headphones hear in monitor mode: the monitor alone, the main output alone, or both"))
                }
                .disabled(!settings.hasMonitorOutput)
            } header: {
                Text("Audio")
            } footer: {
                if settings.monitorIsMainOutput {
                    Text("The monitor plays through the main output: everyone hears the previews.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("MIDI Clock Out", selection: $settings.clockDestination) {
                    Text("None").tag(MIDIUniqueID?.none)
                    Divider()
                    ForEach(settings.midiDestinations) { Text($0.name).tag(MIDIUniqueID?.some($0.id)) }
                    if let id = settings.clockDestination, !settings.midiDestinations.contains(where: { $0.id == id }) {
                        Text("Disconnected Device").tag(MIDIUniqueID?.some(id))
                    }
                }
                LabeledContent("Offset") {
                    HStack {
                        Slider(value: $settings.clockOffset, in: -settings.maxClockOffset...settings.maxClockOffset)
                        Text("\(Int((settings.clockOffset * 1000).rounded())) ms")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                .disabled(settings.clockDestination == nil)
            } header: {
                Text("Sync")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Device Problem", isPresented: Binding { settings.error != nil } set: { if !$0 { settings.clearError() } }) {
            Button("OK") {}
        } message: {
            Text(settings.error ?? "")
        }
    }

    /// The pair of channels of `uid`'s device to play on, while it is connected and has more than one pair.
    @ViewBuilder private func channels(of uid: String?, selection: Binding<Int>) -> some View {
        if let device = settings.output(uid), device.firstChannels.count > 1 {
            Picker("Channels", selection: selection) {
                ForEach(device.firstChannels, id: \.self) { Text("\($0 + 1)–\($0 + 2)").tag($0) }
                if !device.firstChannels.contains(selection.wrappedValue) {
                    Text("Unavailable").tag(selection.wrappedValue)
                }
            }
            .fixedSize()
        }
    }

    /// The connected outputs, plus `selected` when it is not connected right now.
    @ViewBuilder private func outputs(keeping selected: String?) -> some View {
        ForEach(settings.outputs) { Text($0.name).tag(String?.some($0.uid)) }
        if let selected, !settings.outputs.contains(where: { $0.uid == selected }) {
            Text("Disconnected Device").tag(String?.some(selected))
        }
    }
}
