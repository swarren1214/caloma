import SwiftData
import SwiftUI

/// Needs Your OK as a sheet (iPhone, and from Home).
struct ApprovalsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<ChoreCompletion> { $0.statusRaw == "pending" }, sort: \ChoreCompletion.completedAt) private var pending: [ChoreCompletion]

    var body: some View {
        NavigationStack {
            ScrollView {
                ApprovalsList()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .refreshesFromICloud()
            .navigationTitle("Needs Your OK")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton("Close") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if pending.count > 1 {
                    Button {
                        withAnimation(.snappy) { Family.approveAll(pending, in: context) }
                    } label: {
                        Text("Approve All Chores").frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

/// Needs Your OK beside the chore board on iPad.
struct ApprovalsPanel: View {
    @Query(filter: #Predicate<ChoreCompletion> { $0.statusRaw == "pending" }) private var pending: [ChoreCompletion]
    @Query(filter: #Predicate<Redemption> { $0.statusRaw == "pending" }) private var requests: [Redemption]

    var body: some View {
        let count = pending.count + requests.count
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Needs Your OK").font(.title3.bold())
                Spacer()
                Text("\(count)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, minHeight: 26)
                    .padding(.horizontal, 4)
                    .background(count > 0 ? Brand.late : Color(.systemGray3), in: Capsule())
            }
            .padding(16)
            ScrollView {
                ApprovalsList(compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

/// Finished chores and reward requests, each with Send Back / Approve.
struct ApprovalsList: View {
    var compact = false

    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var rewards: [Reward]
    @Query(filter: #Predicate<ChoreCompletion> { $0.statusRaw == "pending" }, sort: \ChoreCompletion.completedAt) private var pending: [ChoreCompletion]
    @Query(filter: #Predicate<Redemption> { $0.statusRaw == "pending" }, sort: \Redemption.requestedAt) private var requests: [Redemption]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pending.isEmpty && requests.isEmpty {
                allCaughtUp
            }
            if !pending.isEmpty {
                if !compact { header("FINISHED CHORES") }
                ForEach(pending) { completion in
                    choreCard(completion)
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
                }
            }
            if !requests.isEmpty {
                header("REWARD REQUESTS")
                ForEach(requests) { request in
                    rewardCard(request)
                        .transition(.asymmetric(insertion: .opacity, removal: .scale(scale: 0.9).combined(with: .opacity)))
                }
            }
        }
        .animation(.snappy, value: pending.count + requests.count)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 8)
    }

    private var allCaughtUp: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(accent)
                .symbolEffect(.bounce, value: pending.count)
            Text("All caught up").font(.headline)
            Text("Points have landed in each kid's jar.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func choreCard(_ completion: ChoreCompletion) -> some View {
        let kid = members.first { $0.id == completion.memberID }
        let chore = chores.first { $0.id == completion.choreID }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if let kid { MemberAvatar(kid, size: compact ? 36 : 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(chore?.title ?? "Chore").font(.headline)
                    Text("\(kid?.name ?? "Someone") · \(completion.completedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PointsLabel(points: completion.points)
            }
            if let data = completion.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 110 : 170)
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityLabel("Photo \(kid?.name ?? "they") took")
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { Family.sendBack(completion, in: context) }
                } label: {
                    Text("Send Back").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)
                Button {
                    withAnimation(.snappy) { Family.approve(completion, in: context) }
                } label: {
                    Text("Approve").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
            .controlSize(compact ? .regular : .large)
        }
        .padding(14)
        .background(compact ? Color(.tertiarySystemGroupedBackground) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: compact ? 16 : 22))
    }

    private func rewardCard(_ request: Redemption) -> some View {
        let kid = members.first { $0.id == request.memberID }
        let reward = rewards.first { $0.id == request.rewardID }
        let color = Color(hex: reward?.kind.colorHex ?? RewardKind.privilege.colorHex)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: reward?.symbol ?? "gift", color: color, size: compact ? 36 : 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reward?.name ?? "Reward").font(.headline)
                    Text("\(kid?.name ?? "Someone") · \(PointWords.current().count(request.cost))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { Family.decline(request, in: context) }
                } label: {
                    Text("Not Today").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .tint(Color.secondary)
                Button {
                    withAnimation(.snappy) { Family.approve(request, in: context) }
                } label: {
                    Text("Approve").frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
            .controlSize(compact ? .regular : .large)
        }
        .padding(14)
        .background(compact ? Color(.tertiarySystemGroupedBackground) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: compact ? 16 : 22))
    }
}

#Preview {
    ApprovalsView()
        .previewEnvironment()
}
