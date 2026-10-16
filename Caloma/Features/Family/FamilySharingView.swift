import CloudKit
import SwiftUI

/// Family › Family Sharing: invite the other parent (on their own Apple Account) so you both
/// see and change the same family, see who's joined, and how syncing is going.
struct FamilySharingView: View {
    @Environment(\.accent) private var accent
    @AppStorage(SettingsKey.familyName) private var familyName = ""
    @State private var share: CKShare?
    @State private var loading = false
    @State private var error: String?
    @State private var confirmsLeave = false
    private let sync = CloudSync.shared

    private var title: String {
        let name = familyName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Our Family" : name
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "person.2.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(accent)
                    Text(sync.role == .participant ? "You're in \(share?[CKShare.SystemFieldKey.title] as? String ?? "a shared family")" : "Share with your family")
                        .font(.title3.bold())
                    Text(sync.role == .participant
                         ? "Chores, rewards, points, home care and the calendar all stay in step with the family."
                         : "Invite your partner so you both see and change the same chores, rewards, points, home care and calendar, each on your own Apple Account.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            if sync.role != .participant {
                Section {
                    TextField("Family name", text: $familyName, prompt: Text("Our Family"))
                    Button {
                        Task { await invite() }
                    } label: {
                        HStack {
                            Label("Invite Family", systemImage: "person.badge.plus")
                            if loading {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(loading || !canSync)
                    if share != nil {
                        Button {
                            Task { await manage() }
                        } label: {
                            Label("Manage People", systemImage: "person.2")
                        }
                        .disabled(loading || !canSync)
                    }
                } footer: {
                    Text("Send the invitation in Messages or Mail. When they tap it, Caloma asks them to join, and their phone switches to this family.")
                }
            }

            if let share, !share.participants.isEmpty {
                Section("People") {
                    ForEach(share.participants, id: \.self) { participant in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name(of: participant))
                                Text(participant.role == .owner ? "Set up the family" : status(of: participant))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if participant.acceptanceStatus == .accepted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(accent)
                            }
                        }
                    }
                }
            }

            Section {
                // The same iCloud Sync card as Family › iCloud, so sync status reads one way everywhere.
                HearthSyncCard(
                    app: .caloma,
                    snapshot: sync.syncSnapshot,
                    summary: "The family’s chores, calendar and rewards"
                ) {
                    await sync.syncNow()
                }
                .hearthSyncCardRow()
            } header: {
                Text("Sync")
            } footer: {
                Text("Kids can use Kid View on a parent's iPhone, or on an iPad signed in to a parent's Apple Account.")
            }

            if sync.role == .participant {
                Section {
                    Button("Leave Family", role: .destructive) { confirmsLeave = true }
                } footer: {
                    Text("The family's data comes off this iPhone. It stays with everyone else.")
                }
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(Brand.late)
                }
            }
        }
        .refreshesFromICloud()
        .navigationTitle("Family Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .task { share = await sync.fetchShare() }
        .alert("Leave the family?", isPresented: $confirmsLeave) {
            Button("Leave Family", role: .destructive) {
                Task { await sync.leaveFamily() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Caloma starts fresh on this iPhone. You can join again with a new invitation.")
        }
    }

    private var canSync: Bool {
        AppConfig.cloudSyncEnabled && sync.status != .noAccount
    }

    private func invite() async {
        loading = true
        defer { loading = false }
        do {
            try await sync.presentInvite(familyName: title)
            share = await sync.fetchShare()
            error = nil
        } catch {
            self.error = (error as? CKError).map { CloudSync.describe($0) } ?? error.localizedDescription
        }
    }

    private func manage() async {
        loading = true
        defer { loading = false }
        do {
            try await sync.presentSharing(familyName: title)
            share = await sync.fetchShare()
            error = nil
        } catch {
            self.error = (error as? CKError).map { CloudSync.describe($0) } ?? error.localizedDescription
        }
    }

    private func name(of participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            let name = components.formatted(.name(style: .medium))
            if !name.isEmpty { return name }
        }
        return participant.userIdentity.lookupInfo?.emailAddress ?? participant.userIdentity.lookupInfo?.phoneNumber ?? "Invited"
    }

    private func status(of participant: CKShare.Participant) -> String {
        switch participant.acceptanceStatus {
        case .accepted: "Joined"
        case .pending: "Invited"
        case .removed: "Removed"
        default: "Unknown"
        }
    }
}
