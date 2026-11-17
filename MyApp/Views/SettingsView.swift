import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    // TODO: point these at your repo / privacy page
    private let repoURL = URL(string: "https://github.com/YOUR_USER/YOUR_REPO")!
    private let privacyURL = URL(string: "https://github.com/YOUR_USER/YOUR_REPO/blob/main/PRIVACY.md")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Only list videos over \(model.minSizeMB) MB", value: $model.minSizeMB, in: 20...2000, step: 20)
                } footer: {
                    Text("Edited, slo-mo, time-lapse and shared videos are always skipped so nothing gets lost.")
                }

                Section {
                    if model.report.isEmpty {
                        Text("Compress some videos, then share this report.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.report.prefix(30), id: \.self) { line in
                            Text(line).font(.caption.monospaced())
                        }
                        ShareLink(item: model.reportText) {
                            Label("Share report", systemImage: "square.and.arrow.up")
                        }
                        Button("Clear report", role: .destructive) { model.clearReport() }
                    }
                } header: {
                    Text("Test report")
                } footer: {
                    Text("Size, savings, quality score and time for each video. No video content or location is included.")
                }

                Section("About") {
                    Link("Source code (open source)", destination: repoURL)
                    Link("Privacy policy", destination: privacyURL)
                    if AdService.shared.isEnabled {
                        Button("Ad privacy choices") {
                            Task { await AdService.shared.showPrivacyOptions() }
                        }
                    }
                    LabeledContent("Version",
                                   value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
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
}
