import SwiftUI
import UIKit

/// Needs Your OK: the oldest request first, with its photo, Approve and Send Back (or Decline
/// for a reward). After a tap, a check or an arrow for a moment, then the next one.
struct ApprovalsPage: View {
    @Environment(PhoneLink.self) private var link
    @State private var result: Result?

    private struct Result: Equatable {
        var approved: Bool
        var title: String
        var detail: String
    }

    var body: some View {
        let snapshot = link.snapshot
        Group {
            if let result {
                ResultBadge(
                    symbol: result.approved ? "checkmark" : "arrow.uturn.backward",
                    color: result.approved ? .green : .orange,
                    title: result.title,
                    detail: result.detail
                )
            } else if let approval = snapshot.approvals.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        PageLabel(title: "Needs your OK", color: .accentColor)
                        ApprovalCard(approval: approval, snapshot: snapshot) { approve in
                            respond(to: approval, approve: approve, remaining: snapshot.approvals.count - 1, snapshot: snapshot)
                        }
                        if snapshot.approvals.count > 1 {
                            Text("\(snapshot.approvals.count - 1) more waiting")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                    Text("All caught up")
                        .font(.headline)
                    Text("Nothing needs your OK.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Needs Your OK")
        .containerBackground(Color.accentColor.gradient.opacity(0.35), for: .tabView)
        .sensoryFeedback(trigger: result) { _, new in
            guard let new else { return nil }
            return new.approved ? .success : .impact
        }
    }

    private func respond(to approval: WatchSnapshot.Approval, approve: Bool, remaining: Int, snapshot: WatchSnapshot) {
        let more = remaining > 0 ? " \(remaining) more waiting." : ""
        let next: Result
        switch (approval.kind, approve) {
        case (.chore, true):
            link.perform(.approve(approval.id))
            next = Result(approved: true, title: "Approved", detail: "\(snapshot.points(approval.points)) to \(approval.kidName).\(more)")
        case (.chore, false):
            link.perform(.sendBack(approval.id))
            next = Result(approved: false, title: "Sent back", detail: "It's back on \(approval.kidName)'s list.\(more)")
        case (.reward, true):
            link.perform(.approve(approval.id))
            next = Result(approved: true, title: "Approved", detail: "\(approval.kidName) gets \(approval.title).\(more)")
        case (.reward, false):
            link.perform(.decline(approval.id))
            next = Result(approved: false, title: "Declined", detail: "\(approval.kidName) keeps the \(snapshot.pointWord).\(more)")
        }
        withAnimation(.snappy) { result = next }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { result = nil }
        }
    }
}

private struct ApprovalCard: View {
    var approval: WatchSnapshot.Approval
    var snapshot: WatchSnapshot
    var respond: (Bool) -> Void

    var body: some View {
        let color = Color(rgb: approval.kidColor)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                InitialBadge(name: approval.kidName, color: color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(approval.kind == .chore ? "\(approval.kidName) finished" : "\(approval.kidName) wants")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(approval.title)
                        .font(.headline)
                        .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)

            if let data = approval.photo, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityLabel("Photo \(approval.kidName) took")
            }

            Button {
                respond(true)
            } label: {
                Label(approval.kind == .chore ? "Approve · +\(approval.points)" : "Approve · \(approval.points)", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)

            Button(approval.kind == .chore ? "Send Back" : "Decline") {
                respond(false)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
