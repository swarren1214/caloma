import SwiftData
import SwiftUI

/// New Reward and editing one: a live preview of the store tile, then name, icon, kind, cost,
/// limits and who can get it.
struct RewardEditor: View {
    var reward: Reward?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var points: [PointEntry]

    @State private var name = ""
    @State private var note = ""
    @State private var symbol = "gift"
    @State private var kind: RewardKind = .experience
    @State private var cost = 100
    @State private var limit: RewardLimit = .oncePerWeek
    @State private var eligible: Set<UUID> = []
    @State private var needsApproval = true
    @State private var isFamilyGoal = false
    @State private var loaded = false
    @State private var confirmsDelete = false

    private var kids: [Member] { members.filter { $0.isKid && !$0.isArchived } }
    private var color: Color { Color(hex: kind.colorHex) }
    private var words: PointWords { PointWords.current() }
    private var isValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && cost > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    preview
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Reward name", text: $name)
                        .font(.title3)
                    TextField("A short note (optional)", text: $note)
                }

                Section("Icon") {
                    SymbolGrid(symbols: SymbolSets.rewards, selection: $symbol, color: color)
                        .padding(.vertical, 4)
                }

                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(RewardKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Kind")
                } footer: {
                    Text(kind.hint)
                }

                Section {
                    Stepper(value: $cost, in: 5...10_000, step: cost < 100 ? 5 : (cost < 1000 ? 10 : 50)) {
                        HStack(spacing: 6) {
                            Image(systemName: words.symbol).foregroundStyle(Brand.star)
                            Text(words.count(cost))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    if !isFamilyGoal {
                        Picker("Limit", selection: $limit) {
                            ForEach(RewardLimit.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } header: {
                    Text(isFamilyGoal ? "Goal" : "Cost and Limits")
                } footer: {
                    Text(effortHint)
                }

                if !isFamilyGoal && !kids.isEmpty {
                    Section {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(kids) { kid in
                                    Chip(title: kid.name, color: kid.color.color, isOn: eligible.isEmpty || eligible.contains(kid.id)) {
                                        toggle(kid.id)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .scrollIndicators(.hidden)
                    } header: {
                        Text("Who Can Get It")
                    }
                }

                Section {
                    if !isFamilyGoal {
                        Toggle("Needs a Parent's OK", isOn: $needsApproval)
                    }
                    Toggle(isOn: $isFamilyGoal) {
                        VStack(alignment: .leading) {
                            Text("Make It a Family Goal")
                            Text("Kids pool \(words.plural) together").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text(isFamilyGoal ? "Kids chip in from their own \(words.plural) in Kid View. There's one family goal at a time." : "Without an OK, \(words.plural) are spent the moment a kid taps Get it.")
                }

                if reward != nil {
                    Section {
                        Button("Remove from Store", role: .destructive) { confirmsDelete = true }
                    }
                }
            }
            .navigationTitle(reward == nil ? "New Reward" : "Edit Reward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm) { save() }
                        .disabled(!isValid)
                }
            }
            .confirmationDialog("Remove \(name)?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Remove from Store", role: .destructive) {
                    reward?.isArchived = true
                    Persistence.save(context)
                    dismiss()
                }
            } message: {
                Text("Kids won't see it anymore. What they've already spent stays in their history.")
            }
            .onAppear(perform: load)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                IconTile(symbol: symbol, color: color, size: 44)
                Spacer()
                TagLabel(text: isFamilyGoal ? "Family Goal" : kind.label, color: color)
            }
            Text(name.isEmpty ? "Reward name" : name)
                .font(.headline)
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .lineLimit(2)
            PointsLabel(points: cost, font: .subheadline.bold())
        }
        .padding(16)
        .frame(width: 190, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
        .animation(.snappy, value: kind)
        .animation(.snappy, value: symbol)
    }

    /// "About 4 days of chores for Max at his usual pace."
    private var effortHint: String {
        let since = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
        let paces = kids.map { kid in (kid, Double(ChoreMath.earned(by: kid.id, since: since, entries: points.map(\.record))) / 14) }
        guard let slowest = paces.filter({ $0.1 > 0 }).min(by: { $0.1 < $1.1 }),
              let days = RewardMath.daysOfChores(cost: isFamilyGoal ? cost / max(kids.count, 1) : cost, pointsPerDay: slowest.1) else {
            return "Set it so it takes a few days of chores, not a few months."
        }
        let kid = slowest.0
        let span = days == 1 ? "a day" : "\(days) days"
        return isFamilyGoal ? "About \(span) of everyone's chores." : "About \(span) of chores for \(kid.name) at the usual pace."
    }

    private func toggle(_ id: UUID) {
        // Empty means everyone. Tapping one kid when everyone's on narrows it to the others.
        if eligible.isEmpty {
            eligible = Set(kids.map(\.id))
        }
        if eligible.contains(id) { eligible.remove(id) } else { eligible.insert(id) }
        if eligible.count == kids.count { eligible = [] }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let reward else { return }
        name = reward.name
        note = reward.note
        symbol = reward.symbol
        kind = reward.kind
        cost = reward.cost
        limit = reward.limit
        eligible = Set(reward.eligibleIDs)
        needsApproval = reward.needsApproval
        isFamilyGoal = reward.isFamilyGoal
    }

    private func save() {
        let target: Reward
        if let reward {
            target = reward
        } else {
            target = Reward(name: name, symbol: symbol, kind: kind, cost: cost, sortOrder: Int(Date.now.timeIntervalSince1970))
            context.insert(target)
        }
        // One family goal at a time: making this one the goal retires the old one.
        if isFamilyGoal && !target.isFamilyGoal {
            let others = (try? context.fetch(FetchDescriptor<Reward>(predicate: #Predicate { $0.isFamilyGoal && !$0.isArchived }))) ?? []
            for other in others where other.id != target.id { other.isArchived = true }
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.note = note.trimmingCharacters(in: .whitespaces)
        target.symbol = symbol
        target.kind = kind
        target.cost = cost
        target.limit = isFamilyGoal ? .none : limit
        target.eligibleIDs = kids.map(\.id).filter { eligible.contains($0) }
        target.needsApproval = isFamilyGoal ? false : needsApproval
        target.isFamilyGoal = isFamilyGoal
        Persistence.save(context)
        dismiss()
    }
}

#Preview {
    RewardEditor(reward: nil)
        .previewEnvironment()
}
