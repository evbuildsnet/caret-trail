import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The apps Caret Trail leaves alone: no effect, and no Accessibility queries at all.
struct IgnoredAppsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.t("Ignored apps")).font(.headline)
            Text(state.t("No effect in these apps, and Caret Trail stops asking them where their caret is."))
                .font(.caption)
                .foregroundStyle(.secondary)

            List(selection: $state.ignoredSelection) {
                ForEach(state.ignoredApps, id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(nsImage: Self.icon(for: id)).resizable().frame(width: 18, height: 18)
                        Text(Self.name(for: id))
                    }
                    .tag(id)
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if state.ignoredApps.isEmpty {
                    Text(state.t("No ignored apps")).foregroundStyle(.secondary)
                }
            }

            HStack {
                Menu {
                    ForEach(Self.runningApps(excluding: state.ignoredApps), id: \.bundleIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") { add(app.bundleIdentifier) }
                    }
                    Divider()
                    Button(state.t("Other…")) { chooseApp() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                Button {
                    state.ignoredApps.removeAll { $0 == state.ignoredSelection }
                    state.ignoredSelection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(state.ignoredSelection == nil)
                Spacer()
                Button(state.t("Done")) { state.showingIgnoredApps = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private func add(_ id: String?) {
        guard let id, !state.ignoredApps.contains(id) else { return }
        state.ignoredApps.append(id)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(Bundle(url: url)?.bundleIdentifier) }
    }

    /// Apps with a Dock icon that are open now, by name, without Caret Trail and those already listed.
    static func runningApps(excluding ignored: [String]) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .filter { $0.bundleIdentifier.map { !ignored.contains($0) } ?? false }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    static func name(for id: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return id
    }

    static func icon(for id: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }
}
