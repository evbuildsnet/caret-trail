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
                Toggle(state.t("Enabled"), isOn: $state.enabled)
                    .font(.headline)
                Spacer()
                permission(state.t("Accessibility"), granted: state.trusted, needed: true, pane: "Privacy_Accessibility")
                permission(state.t("Screen Recording"), granted: state.screenAccess, needed: state.maskCaret, pane: "Privacy_ScreenCapture")
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    section(state.t("Look")) {
                        Picker(state.t("Effect"), selection: $state.glide) {
                            Text(state.t("Comet trail")).tag(false)
                            Text(state.t("Glide (comet in terminals)")).tag(true)
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .fixedSize()
                        HStack {
                            Text(state.t("Duration"))
                            Slider(value: $state.duration, in: 0.05...0.6, step: 0.05)
                            Text("\(Int((state.duration * 1000).rounded())) ms")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        HStack {
                            Text(state.t("Tail length"))
                            Slider(value: $state.tailLength, in: 0.5...4, step: 0.5)
                            Text(String(format: "%.1f×", state.tailLength))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        .disabled(state.glide)
                        HStack {
                            ColorPicker(state.t("Color"), selection: trailColor, supportsOpacity: false)
                                .fixedSize()
                            Button(state.t("Use system accent color")) { state.customColor = nil }
                            .tint(.white)
                                .disabled(state.customColor == nil)
                        }
                        Toggle(state.t("Glow (Comet trail) / Halo (Glide)"), isOn: $state.glow)
                    }
                    section(state.t("Glide")) {
                        Toggle(state.t("Fast start, soft landing"), isOn: $state.wordCurve)
                        Toggle(state.t("Hide the real caret (needs Screen Recording)"), isOn: $state.maskCaret)
                    }
                    .disabled(!state.glide)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 14) {
                    section(state.t("Behaviour")) {
                        Toggle(state.t("No effect on mouse clicks"), isOn: $state.ignoreClicks)
                        Toggle(state.t("No effect on line breaks"), isOn: $state.noLineBreaks)
                        Toggle(state.t("Ignore hidden cursor jumps in terminals"), isOn: $state.terminalFix)
                        Button(state.t("Ignored apps…") + " (\(state.ignoredApps.count))") { state.showingIgnoredApps = true }
                            .tint(.white)
                    }
                    section(state.t("App")) {
                        Toggle(state.t("Open at login"), isOn: $state.openAtLogin)
                        Toggle(state.t("Keep this window on top"), isOn: $state.keepOnTop)
                        Picker(state.t("Show in"), selection: $state.placement) {
                            Text(state.t("Dock")).tag("dock")
                            Text(state.t("Menu bar")).tag("menuBar")
                            Text(state.t("Both")).tag("both")
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(state.t("Try it here")).font(.caption).foregroundStyle(.white.opacity(0.85))
                    NeonMark(color: neon).frame(width: 30, height: 18)
                }
                CaretTestField(state: state, onCaretMoved: onTestCaretMoved)
                    .frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(neon.opacity(0.2), lineWidth: 1))
                    .shadow(color: neon.opacity(0.06), radius: 8)
                HStack {
                    Text(state.t(state.status))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    languageMenu
                }
            }
        }
        .sheet(isPresented: $state.showingIgnoredApps) {
            IgnoredAppsView(state: state)
                .tint(NeonTheme.controlTint(state.trail.color))
                .background(NeonTheme.background(state.trail.color))
                .environment(\.colorScheme, .dark)
        }
        .padding(20)
        .frame(width: 760)
        .tint(NeonTheme.controlTint(state.trail.color))
        .background(NeonTheme.background(state.trail.color))
        .environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Small and quiet, bottom right: Auto follows the macOS language.
    private var languageMenu: some View {
        // The globe sits outside the menu button: inside it, AppKit draws image and title on
        // different baselines. Side by side in an HStack, their centres line up.
        HStack(spacing: 3) {
            Image(systemName: "globe")
            Menu {
                Button((state.language == "auto" ? "✓ " : "    ") + "Auto (\(L10n.systemLanguage.uppercased()))") { state.language = "auto" }
                Divider()
                ForEach(L10n.languages, id: \.self) { code in
                    Button((state.language == code ? "✓ " : "    ") + (L10n.names[code] ?? code)) { state.language = code }
                }
            } label: {
                Text(state.lang.uppercased())
            }
            .menuStyle(.borderlessButton)
            .tint(.white)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var neon: Color { Color(nsColor: state.trail.color) }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NeonSection(title: title, color: neon) { content() }
    }

    /// Green when granted, red when missing and needed (with a way to fix it), grey when unused.
    private func permission(_ name: String, granted: Bool, needed: Bool, pane: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(granted ? Color.green : needed ? Color.red : Color.gray)
                .frame(width: 9, height: 9)
            Text(name).font(.callout)
            if needed && !granted {
                Button(state.t("Open Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
                .controlSize(.small)
            }
        }
        .help("\(name): " + state.t(granted ? "granted" : needed ? "missing: grant it in System Settings, then quit and reopen Caret Trail." : "not used by the current settings"))
    }
}
