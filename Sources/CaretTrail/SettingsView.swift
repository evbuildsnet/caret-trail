import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    var onTestCaretMoved: (CGRect, CGRect) -> Void = { _, _ in }

    private var trailColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: state.trail.color) },
            set: { state.customColor = NSColor($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 18) {
                Toggle("Enabled", isOn: $state.enabled)
                    .font(.headline)
                Spacer()
                permission("Accessibility", granted: state.trusted, needed: true, pane: "Privacy_Accessibility")
                permission("Screen Recording", granted: state.screenAccess, needed: state.maskCaret, pane: "Privacy_ScreenCapture")
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    section("Look") {
                        Picker("Effect", selection: $state.glide) {
                            Text("Comet trail").tag(false)
                            Text("Glide (comet in terminals)").tag(true)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        HStack {
                            Text("Duration")
                            Slider(value: $state.duration, in: 0.05...0.6, step: 0.05)
                            Text("\(Int((state.duration * 1000).rounded())) ms")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        HStack {
                            ColorPicker("Color", selection: trailColor, supportsOpacity: false)
                                .fixedSize()
                            Button("Use accent") { state.customColor = nil }
                                .disabled(state.customColor == nil)
                        }
                        Toggle("Glow (Comet trail) / Halo (Glide)", isOn: $state.glow)
                    }
                    section("Glide") {
                        Toggle("Fast start, soft landing", isOn: $state.wordCurve)
                        Toggle("Hide the real caret (needs Screen Recording)", isOn: $state.maskCaret)
                    }
                    .disabled(!state.glide)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 14) {
                    section("Behaviour") {
                        Toggle("No effect on mouse clicks", isOn: $state.ignoreClicks)
                        Toggle("No effect on line breaks", isOn: $state.noLineBreaks)
                        Toggle("Ignore hidden cursor jumps in terminals", isOn: $state.terminalFix)
                        Button("Ignored apps… (\(state.ignoredApps.count))") { state.showingIgnoredApps = true }
                    }
                    section("App") {
                        Toggle("Open at login", isOn: $state.openAtLogin)
                        Picker("Show in", selection: $state.placement) {
                            Text("Dock").tag("dock")
                            Text("Menu bar").tag("menuBar")
                            Text("Both").tag("both")
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Try it here").font(.caption).foregroundStyle(.secondary)
                CaretTestField(state: state, onCaretMoved: onTestCaretMoved)
                    .frame(height: 56)
                Text(state.status)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .sheet(isPresented: $state.showingIgnoredApps) { IgnoredAppsView(state: state) }
        .padding(20)
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Text(title.uppercased()).font(.caption).bold().foregroundStyle(.secondary)
        }
    }

    /// Green when granted, red when missing and needed (with a way to fix it), grey when unused.
    private func permission(_ name: String, granted: Bool, needed: Bool, pane: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : needed ? Color.red : Color.gray)
                .frame(width: 9, height: 9)
            Text(name).font(.callout)
            if needed && !granted {
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .controlSize(.small)
            }
        }
        .help(granted ? "\(name): granted" : needed ? "\(name): missing. Grant it in System Settings, then quit and reopen Caret Trail." : "\(name): not used by the current settings")
    }
}
