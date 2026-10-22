import SwiftData
import SwiftUI

/// Family › Sync Details (TestFlight and Debug builds only): this device's sync, and what's
/// really in iCloud, so two devices that don't match can be compared side by side. Copy puts it
/// all on the clipboard to paste somewhere.
struct SyncDetailsView: View {
    @Environment(\.modelContext) private var context
    @State private var lines: [(String, String)] = []
    @State private var people: [String] = []
    @State private var inICloud: String?
    @State private var checking = false

    var body: some View {
        List {
            Section {
                ForEach(lines, id: \.0) { line in
                    LabeledContent(line.0) {
                        Text(line.1)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("This Device")
            }

            Section {
                Text(people.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Who's Who Here")
            }

            Section {
                if let inICloud {
                    Text(inICloud)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Button(checking ? "Checking…" : "Check What's in iCloud") {
                    Task { await check() }
                }
                .disabled(checking)
                .tint(.primary)
                Button("Download Everything Again") {
                    Task {
                        checking = true
                        await CloudSync.shared.redownloadEverything()
                        reload()
                        checking = false
                    }
                }
                .disabled(checking)
                .tint(.primary)
            } header: {
                Text("In iCloud")
            } footer: {
                Text("Reads the family's Caloma data straight from iCloud. Run it on both devices: they should show the same zone, owner and counts.")
            }
        }
        .navigationTitle("Sync Details")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = report
                }
                .tint(.primary)
            }
        }
        .task { reload() }
        .refreshable {
            await CloudSync.shared.syncNow()
            reload()
        }
    }

    private var report: String {
        let device = "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        let body = lines.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        return "Caloma Sync Details — \(device)\n\(body)\n\n\(people.joined(separator: "\n"))\n\nIn iCloud:\n\(inICloud ?? "Not checked")"
    }

    private func reload() {
        lines = CloudSync.shared.detailLines(in: context)
        people = CloudSync.shared.peopleLines(in: context)
    }

    private func check() async {
        checking = true
        inICloud = await CloudSync.shared.recordsInICloud()
        reload()
        checking = false
    }
}
