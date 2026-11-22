import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    private let repoURL = URL(string: "https://github.com/canakten15-oss/myapp")!
    private let privacyURL = URL(string: "https://github.com/canakten15-oss/myapp/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Only list videos over \(model.minSizeMB) MB", value: $model.minSizeMB, in: 20...2000, step: 20)
                } footer: {
                    Text("Edited, slo-mo, time-lapse and shared videos are always skipped so nothing gets lost.")
                }

                Section {
                    NavigationLink {
                        ReportView()
                    } label: {
                        LabeledContent("Test report", value: "\(model.report.count)")
                    }
                    .accessibilityIdentifier("testReportLink")
                } footer: {
                    Text("Size, savings, quality score and time for each video. No video content or location.")
                }

                Section("About") {
                    Link("Source code (open source)", destination: repoURL)
                    Link("Privacy policy", destination: privacyURL)
                    if AdService.shared.isEnabled {
                        Button("Ad privacy choices") {
                            Task { await AdService.shared.showPrivacyOptions() }
                        }
                    }
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                        Task { await model.scan() }
                    }
                }
            }
        }
    }

    static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return "\(v) (\(b))"
    }
}

/// The test report as its own page, so a long list doesn't clutter Settings.
struct ReportView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var confirmClear = false

    var body: some View {
        List {
            if model.report.isEmpty {
                Text("Compress some videos, then share this report.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.report.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Test report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !model.report.isEmpty {
                    ShareLink(item: model.reportText) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Share report")
                    Button(role: .destructive) { confirmClear = true } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Clear report")
                }
            }
        }
        .confirmationDialog("Clear the test report?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear report", role: .destructive) { model.clearReport() }
        }
    }
}
