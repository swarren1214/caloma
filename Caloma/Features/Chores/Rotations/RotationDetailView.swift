import SwiftData
import SwiftUI

/// One rotation: whose turn it is now, the turns coming up, and skipping, swapping or pausing
/// any of them. Works the same for a chore group and a single chore that takes turns.
struct RotationDetailView: View {
    var rotationID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var groups: [ChoreGroup]
    @Query private var chores: [Chore]
    @AppStorage(SettingsKey.rotationMakeUp) private var makeUp = true

    @State private var editingGroup: ChoreGroup?
    @State private var editingChore: Chore?

    /// How many turns to list.
    private let shown = 8

    private var summary: RotationSummary? {
        Rotations.summaries(groups: groups, chores: chores).first { $0.id == rotationID }
    }

    var body: some View {
        Group {
            if let summary {
                content(summary)
            } else {
                ContentUnavailableView("Not Rotating", systemImage: "arrow.triangle.2.circlepath", description: Text("This rotation was removed."))
            }
        }
        .navigationTitle(summary?.name ?? "Rotation")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingGroup) { group in
            ChoreGroupEditor(group: group, roomID: nil)
        }
        .sheet(item: $editingChore) { chore in
            ChoreEditor(chore: chore)
        }
    }

    private func content(_ summary: RotationSummary) -> some View {
        let current = RotationMath.periodIndex(of: .now, rule: summary.rule)
        let tint = summary.tint(accent: accent)
        return List {
            Section {
                header(summary, current: current, tint: tint)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                ForEach(current..<(current + shown), id: \.self) { index in
                    turnRow(summary, index: index, current: current, tint: tint)
                }
            } header: {
                Text("Coming Up")
            } footer: {
                Text(summary.rule.mode == .everyone
                     ? "Everyone does every chore, so there are no turns to change."
                     : "Tap a turn to skip it, swap it with the next one, or pause it while you’re away.")
            }

            if summary.isGroup {
                Section("Chores in This Group") {
                    let inGroup = groupChores(summary)
                    if inGroup.isEmpty {
                        Text("No chores yet. Edit the group to add some.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(inGroup) { chore in
                        Button {
                            editingChore = chore
                        } label: {
                            HStack(spacing: 12) {
                                IconTile(symbol: chore.symbol, color: tint, size: 32)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(chore.title).foregroundStyle(Color.primary)
                                    Text(chore.repeatRule.label).font(.caption).foregroundStyle(Color.secondary)
                                }
                                Spacer()
                                Label("\(chore.points)", systemImage: PointWords.current().symbol)
                                    .font(.subheadline.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Brand.star)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }

            if !summary.rule.adjustments.isEmpty && summary.rule.mode != .everyone {
                Section {
                    Button("Undo All Changes", role: .destructive) {
                        Rotations.setAdjustments(RotationAdjustments(), for: summary, groups: groups, chores: chores)
                        Persistence.save(context)
                    }
                } footer: {
                    Text("Puts every turn back in the plain order.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") {
                    if summary.isGroup {
                        editingGroup = groups.first { $0.id == summary.id }
                    } else {
                        editingChore = chores.first { $0.id == summary.id }
                    }
                }
            }
        }
    }

    // MARK: Now

    private func header(_ summary: RotationSummary, current: Int, tint: Color) -> some View {
        let holder = summary.holder(ofPeriod: current).flatMap(member)
        let next = summary.holder(ofPeriod: current + 1).flatMap(member)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: summary.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.rule.mode.title.uppercased())
                        .font(.caption.weight(.bold))
                        .opacity(0.9)
                    Text(headline(summary, holder: holder))
                        .font(.title2.weight(.heavy))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
                if let holder {
                    MemberAvatar(holder, size: 48)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            Text(subline(summary, current: current, next: next))
                .font(.subheadline.weight(.semibold))
                .opacity(0.95)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [tint, tint.mix(with: .black, by: 0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 26)
        )
        .accessibilityElement(children: .combine)
    }

    private func headline(_ summary: RotationSummary, holder: Member?) -> String {
        switch summary.rule.mode {
        case .turns:
            return RotationText.holderTitle(holder?.name, rule: summary.rule)
        case .split:
            return "Split \(summary.members.count) ways"
        case .everyone:
            return "Everyone does it"
        }
    }

    private func subline(_ summary: RotationSummary, current: Int, next: Member?) -> String {
        let schedule = RotationText.schedule(summary.rule)
        switch summary.rule.mode {
        case .turns:
            return RotationText.handOver(next: next?.name, name: summary.name, index: current, rule: summary.rule) + " " + schedule + "."
        case .split:
            return "Who does which moves along together. \(schedule)."
        case .everyone:
            return "Each person does every chore."
        }
    }

    // MARK: Turns

    @ViewBuilder
    private func turnRow(_ summary: RotationSummary, index: Int, current: Int, tint: Color) -> some View {
        let paused = summary.rule.adjustments.pauses.contains(index)
        let swapped = summary.rule.adjustments.swaps.contains(index) || summary.rule.adjustments.swaps.contains(index - 1)
        let skipped = summary.rule.adjustments.shifts.contains(index)
        let row = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(RotationText.turnName(index, current: current, rule: summary.rule))
                    .font(.body.weight(index == current ? .semibold : .regular))
                if summary.rule.period != .day {
                    Text(RotationText.range(RotationMath.start(ofPeriod: index, rule: summary.rule), RotationMath.end(ofPeriod: index, rule: summary.rule)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if paused {
                tag("Paused", symbol: "pause.fill", color: .secondary)
            } else {
                if swapped { tag("Swapped", symbol: "arrow.left.arrow.right", color: .orange) }
                if skipped { tag("Skipped", symbol: "forward.fill", color: .orange) }
                who(summary, index: index)
            }
        }
        if summary.rule.mode == .everyone {
            row
        } else {
            Menu {
                turnMenu(summary, index: index, paused: paused)
            } label: {
                row.contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .tint(.primary)
        }
    }

    @ViewBuilder
    private func who(_ summary: RotationSummary, index: Int) -> some View {
        switch summary.rule.mode {
        case .turns:
            if let person = summary.holder(ofPeriod: index).flatMap(member) {
                HStack(spacing: 8) {
                    Text(person.name).font(.subheadline.weight(.semibold))
                    MemberAvatar(person, size: 28)
                }
            }
        case .split, .everyone:
            let ids = Array(Set(summary.assignments(ofPeriod: index).flatMap { $0 }))
            MemberStack(members: members.filter { ids.contains($0.id) }, size: 26)
        }
    }

    @ViewBuilder
    private func turnMenu(_ summary: RotationSummary, index: Int, paused: Bool) -> some View {
        let name = RotationText.turnName(index, current: RotationMath.periodIndex(of: .now, rule: summary.rule), rule: summary.rule)
        let holder = summary.holder(ofPeriod: index).flatMap(member)
        let next = summary.holder(ofPeriod: index + 1).flatMap(member)
        if !paused {
            if summary.rule.mode == .turns, let holder, !RotationMath.isTraded(index, adjustments: summary.rule.adjustments) {
                Button(makeUp ? "Skip \(holder.name) (Make It Up Later)" : "Skip \(holder.name)", menuIcon: "forward") {
                    change(summary) { RotationMath.skipping(index, makeUp: makeUp, adjustments: $0) }
                }
            }
            let swapTitle: String = {
                if let holder, let next, holder.id != next.id { return "Swap \(holder.name) and \(next.name)" }
                return "Swap With the Next Turn"
            }()
            if summary.rule.adjustments.swaps.contains(index) || summary.rule.adjustments.swaps.contains(index - 1) {
                let first = summary.rule.adjustments.swaps.contains(index) ? index : index - 1
                Button("Undo Swap", menuIcon: "arrow.uturn.backward") {
                    change(summary) { RotationMath.swapping(first, adjustments: $0) }
                }
            } else if RotationMath.canSwap(index, adjustments: summary.rule.adjustments) {
                Button(swapTitle, menuIcon: "arrow.left.arrow.right") {
                    change(summary) { RotationMath.swapping(index, adjustments: $0) }
                }
            }
            if summary.rule.adjustments.shifts.contains(index) {
                Button("Undo Skip", menuIcon: "arrow.uturn.backward") {
                    change(summary) { adjustments in
                        var copy = adjustments
                        copy.shifts.remove(index)
                        return copy
                    }
                }
            }
        }
        Button(paused ? "Resume \(name)" : "Pause \(name)", menuIcon: paused ? "play" : "pause") {
            change(summary) { RotationMath.pausing(index, adjustments: $0) }
        }
    }

    private func change(_ summary: RotationSummary, _ edit: (RotationAdjustments) -> RotationAdjustments) {
        let current = RotationMath.periodIndex(of: .now, rule: summary.rule)
        let updated = edit(summary.rule.adjustments).trimmed(before: current - 4)
        withAnimation(.smooth) {
            Rotations.setAdjustments(updated, for: summary, groups: groups, chores: chores)
        }
        Persistence.save(context)
    }

    private func tag(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func member(_ id: UUID) -> Member? {
        members.first { $0.id == id }
    }

    private func groupChores(_ summary: RotationSummary) -> [Chore] {
        guard let group = groups.first(where: { $0.id == summary.id }) else { return [] }
        return Rotations.chores(in: group, from: chores)
    }
}
