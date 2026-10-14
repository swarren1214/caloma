import SwiftUI

/// Home Care: what's late or due in the next few days, soonest first, each with Mark Done.
struct HomeCarePage: View {
    @Environment(PhoneLink.self) private var link
    @State private var justDone: String?

    var body: some View {
        let items = link.snapshot.homeCare
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageLabel(title: "Home care", color: items.first.map { $0.isLate() ? .red : .orange } ?? .accentColor)
                if let justDone {
                    Label("\(justDone) done", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }
                if items.isEmpty {
                    Text("Nothing due this week.")
                        .font(.headline)
                    Text("The next jobs show up here a few days ahead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        HomeCareRow(item: item) {
                            link.perform(.homeTaskDone(item.id))
                            withAnimation(.snappy) { justDone = item.name }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                withAnimation(.snappy) { justDone = nil }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Home Care")
        .containerBackground((items.first?.isLate() == true ? Color.red : Color.orange).gradient.opacity(0.25), for: .tabView)
        .sensoryFeedback(.success, trigger: justDone) { _, new in new != nil }
    }
}

private struct HomeCareRow: View {
    var item: WatchSnapshot.HomeCareItem
    var markDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(item.name, systemImage: item.symbol)
                .font(.headline)
                .lineLimit(2)
            Text([item.dueLabel(), item.location].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(item.isLate() ? .red : .secondary)
            Button(action: markDone) {
                Label("Mark Done", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .tint(.green)
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 14))
    }
}
