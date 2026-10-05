import CoreMIDI
import MADSETCore
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Devices", systemImage: "hifispeaker") {
                DevicesSettings(settings: .shared)
            }
        }
        .frame(width: 560)
    }
}

/// Audio outputs and MIDI clock out.
private struct DevicesSettings: View {
    @Bindable var settings: DeviceSettings

    var body: some View {
        Form {
            Section {
                Picker("Main Output", selection: $settings.mainOutput) {
                    Text("System Default").tag(String?.none)
                    Divider()
                    outputs(keeping: settings.mainOutput)
                }
                Picker("Monitor Output", selection: $settings.monitorOutput) {
                    Text("None").tag(String?.none)
                    Divider()
                    outputs(keeping: settings.monitorOutput)
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Nothing is cued to the monitor output yet.")
                    .foregroundStyle(.secondary)
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
            } footer: {
                Text("Sends MIDI clock, start, stop and song position locked to the set's beats and bars, so a groovebox on that port plays in time with the kick. Raise the offset if the groovebox sounds early, lower it if it sounds late.")
                    .foregroundStyle(.secondary)
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

    /// The connected outputs, plus `selected` when it is not connected right now.
    @ViewBuilder private func outputs(keeping selected: String?) -> some View {
        ForEach(settings.outputs) { Text($0.name).tag(String?.some($0.uid)) }
        if let selected, !settings.outputs.contains(where: { $0.uid == selected }) {
            Text("Disconnected Device").tag(String?.some(selected))
        }
    }
}
