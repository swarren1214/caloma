import SwiftUI

/// My Chores: today's chores assigned to this parent. Tap one to tick it off, tap again to take
/// it back. Shown only when there's something on the list.
struct MyChoresPage: View {
    @Environment(PhoneLink.self) private var link
    @State private var lastTicked: UUID?

    var body: some View {
        let chores = link.snapshot.myChores ?? []
        let left = chores.filter { !$0.done }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PageLabel(title: left == 0 ? "All done today" : "\(left) left today", color: .accentColor)
                ForEach(chores) { chore in
                    Button {
                        link.perform(chore.done ? .choreUndone(chore.choreID) : .choreDone(chore.choreID))
                        lastTicked = chore.done ? nil : chore.choreID
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: chore.done ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(chore.done ? Color.green : Color.secondary)
                                .contentTransition(.symbolEffect(.replace))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(chore.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                    .strikethrough(chore.done)
                                    .foregroundStyle(chore.done ? .secondary : .primary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: chore.symbol)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(chore.title)
                    .accessibilityValue(chore.done ? "Done" : "Not done")
                    .accessibilityHint(chore.done ? "Double-tap to take it back" : "Double-tap to mark it done")
                }
            }
        }
        .navigationTitle("My Chores")
        .containerBackground(Color.accentColor.gradient.opacity(0.25), for: .tabView)
        .sensoryFeedback(.success, trigger: lastTicked) { _, new in new != nil }
    }
}
