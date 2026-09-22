import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    private var trailColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: state.trail.color) },
            set: { state.customColor = NSColor($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Caret Trail").font(.title2).bold()
            Text("Keep your place. Enjoy every move. A luminous trail helps your eyes follow the text cursor as you write and edit.")
                .foregroundStyle(.secondary)

            GroupBox("Accessibility permission") {
                HStack {
                    Circle().fill(state.trusted ? Color.green : Color.red).frame(width: 10, height: 10)
                    Text(state.trusted ? "Granted" : "Not granted. Enable Caret Trail in System Settings.")
                    Spacer()
                    if !state.trusted {
                        Button("Open System Settings") {
                            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .padding(4)
            }

            Toggle("Enabled", isOn: $state.enabled)

            VStack(alignment: .leading, spacing: 4) {
                Text("Trail duration: \(Int(state.duration * 1000)) ms")
                Slider(value: $state.duration, in: 0.05...0.4)
            }

            HStack {
                ColorPicker("Trail color", selection: trailColor, supportsOpacity: false)
                    .fixedSize()
                Text(state.customColor == nil ? "Following system accent" : "Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use System Accent") { state.customColor = nil }
                    .disabled(state.customColor == nil)
            }

            GroupBox("Status") {
                Text(state.status)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }

            Spacer()

            Text("Switch to any other app and move the caret with arrows, clicks, or typing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }
}
