import SwiftData
import SwiftUI

// MARK: - 2 · Your household

/// The family is the Hearth household, the same in every Hearth app: set one up (a household
/// of one is fine), or join the family's from their invitation. Caloma's members come from it
/// (`CalomaHousehold`), so there's no Caloma-only family to fill in.
struct HouseholdStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent
    @Environment(\.modelContext) private var context

    var body: some View {
        HearthHouseholdOnboarding(accent: accent) {
            CalomaHousehold.sync(in: context)
            if flow.familyIsAlreadySetUp(in: context) {
                // Someone else's household (their Caloma comes down by itself), or a family
                // already in iCloud: nothing to set up here.
                flow.finishWithExistingFamily()
            } else {
                flow.next()
            }
        }
    }
}

// MARK: - 3 · What do chores earn?

struct PointsStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent
    @Environment(\.onboardingLayout) private var layout

    @AppStorage(SettingsKey.pointName) private var pointName = PointName.stars.rawValue
    @AppStorage(SettingsKey.customPointName) private var customPointName = ""
    @AppStorage(SettingsKey.approvalsByDefault) private var approvalsByDefault = true
    @AppStorage(SettingsKey.allowanceOn) private var allowanceOn = true
    @AppStorage(SettingsKey.centsPer100) private var centsPer100 = 500
    @AppStorage(SettingsKey.payday) private var payday = 1
    @AppStorage(SettingsKey.splitSpend) private var splitSpend = 70
    @AppStorage(SettingsKey.splitSave) private var splitSave = 20
    @AppStorage(SettingsKey.splitGive) private var splitGive = 10

    /// The four choices: three of Caloma's names, and gems as the family's own word.
    private struct Choice: Identifiable {
        var id: String
        var label: String
        var symbol: String
        var color: Color
        var name: PointName
        var custom: String?
    }

    private var choices: [Choice] {
        [
            Choice(id: "stars", label: "Stars", symbol: "star.fill", color: Brand.star, name: .stars),
            Choice(id: "coins", label: "Coins", symbol: "dollarsign.circle.fill", color: Color(hex: 0xC9A227), name: .coins),
            Choice(id: "points", label: "Points", symbol: "p.circle.fill", color: accent, name: .points),
            Choice(id: "gems", label: "Gems", symbol: "diamond.fill", color: Color(hex: 0x5E5CE6), name: .custom, custom: "gems"),
        ]
    }

    private var words: PointWords {
        let name = PointName(rawValue: pointName) ?? .stars
        if name == .custom {
            let custom = customPointName.trimmingCharacters(in: .whitespaces).lowercased()
            return PointWords(plural: custom.isEmpty ? "points" : custom, symbol: name.symbol)
        }
        return PointWords(plural: name.rawValue, symbol: name.symbol)
    }

    private var selectedChoice: Choice? {
        choices.first { $0.name.rawValue == pointName && ($0.custom == nil || $0.custom == customPointName.lowercased()) }
    }

    var body: some View {
        OnboardingScreen(title: "What do chores earn?", subtitle: "Pick what your family calls points. Kids see it everywhere.") {
            OnboardingSymbolIcon(symbol: "star.fill", color: Brand.star)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(choices) { choice in
                        choiceTile(choice)
                    }
                }

                preview

                Toggle(isOn: $approvalsByDefault) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chores need my OK").font(.headline)
                        Text(approvalsByDefault ? "\(words.title) land after you tap OK" : "\(words.title) land the moment they tap Done")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                }
                .padding(16)
                .onboardingCard()

                allowanceCard
            }
            .animation(.smooth(duration: 0.3), value: allowanceOn)
        } controls: {
            OnboardingPrimaryButton(title: "Continue", action: flow.next)
        }
    }

    private func choiceTile(_ choice: Choice) -> some View {
        let selected = selectedChoice?.id == choice.id
        return Button {
            pointName = choice.name.rawValue
            if let custom = choice.custom { customPointName = custom }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: choice.symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(selected ? choice.color : Color.secondary)
                    .symbolEffect(.bounce, value: selected)
                Text(choice.label)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 82)
            .background(selected ? accent.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
            .onboardingSelection(selected, color: accent, cornerRadius: 18)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// "Make your bed  +10 stars", so they see the word in place.
    private var preview: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "bed.double.fill", color: accent, size: 36)
            Text("Make your bed")
                .font(.body.weight(.semibold))
            Spacer()
            Label("+10 \(words.plural)", systemImage: selectedChoice?.symbol ?? "star.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(selectedChoice?.color ?? Brand.star)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background((selectedChoice?.color ?? Brand.star).opacity(0.14), in: Capsule())
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
        .onboardingCard()
        .animation(.smooth(duration: 0.25), value: pointName)
        .accessibilityElement(children: .combine)
    }

    private var allowanceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $allowanceOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn \(words.plural) into allowance").font(.headline)
                    Text("Paid out on payday, split three ways")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if allowanceOn {
                VStack(spacing: 16) {
                    rateStepper
                    paydayPicker
                    splitBar
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .onboardingCard()
        .clipped()
    }

    private var rateStepper: some View {
        HStack {
            stepButton("minus", label: "Less") { centsPer100 = max(25, centsPer100 - 25) }
                .disabled(centsPer100 <= 25)
            Spacer()
            VStack(spacing: 0) {
                Text((Double(centsPer100) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD")))
                    .font(.title2.bold().monospacedDigit())
                    .contentTransition(.numericText(value: Double(centsPer100)))
                Text("for every 100 \(words.plural)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .animation(.snappy, value: centsPer100)
            .accessibilityElement(children: .combine)
            Spacer()
            stepButton("plus", label: "More") { centsPer100 = min(5000, centsPer100 + 25) }
                .disabled(centsPer100 >= 5000)
        }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private var paydayPicker: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        let names = Calendar.current.standaloneWeekdaySymbols
        return VStack(alignment: .leading, spacing: 8) {
            Text("Payday")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(1...7, id: \.self) { day in
                    let selected = payday == day
                    Button {
                        payday = day
                    } label: {
                        Text(symbols[day - 1])
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(selected ? .white : .primary)
                            .frame(width: 38, height: 38)
                            .background(selected ? accent : Color(.tertiarySystemFill), in: Circle())
                            .frame(maxWidth: .infinity)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Payday \(names[day - 1])")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .animation(.snappy(duration: 0.2), value: payday)
        }
    }

    /// Spend, save, give: how each payday is split. Changed in Profile.
    private var splitBar: some View {
        let parts: [(String, Int, Color)] = [("Spend", splitSpend, accent), ("Save", splitSave, Color(hex: 0x1E9E6A)), ("Give", splitGive, Color(hex: 0xAF52DE))]
        let total = max(parts.map(\.1).reduce(0, +), 1)
        return VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 3) {
                    ForEach(parts, id: \.0) { part in
                        Capsule()
                            .fill(part.2)
                            .frame(width: max(0, (proxy.size.width - 6) * CGFloat(part.1) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 5) {
                        Circle().fill(part.2).frame(width: 8, height: 8)
                        Text("\(part.0) \(part.1)%")
                            .font(.caption.weight(.semibold))
                    }
                }
                Spacer(minLength: 0)
            }
            Text("Change the split any time in Profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 4 · Pick a few chores

struct ChoresStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent

    private var hasKids: Bool { !flow.kidNames.isEmpty }

    private var continueTitle: String {
        guard hasKids else { return "Continue" }
        switch flow.draft.pickedCount {
        case 0: return "Skip for Now"
        case 1: return "Add 1 Chore"
        case let count: return "Add \(count) Chores"
        }
    }

    var body: some View {
        @Bindable var flow = flow
        OnboardingScreen(
            title: hasKids ? "Pick a few chores" : "Chores come later",
            subtitle: hasKids
                ? "Every kid gets these to start. Change who does what, and what each is worth, any time."
                : "Add kids any time in Profile › Household, then pick their chores."
        ) {
            OnboardingSymbolIcon(symbol: "checklist")
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                if hasKids {
                    VStack(spacing: 0) {
                        ForEach(StarterData.chores) { chore in
                            choreRow(chore)
                            if chore.id != StarterData.chores.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                    .onboardingCard()
                }

                Toggle(isOn: $flow.draft.addRewards) {
                    HStack(spacing: 12) {
                        IconTile(symbol: "gift.fill", color: Brand.star, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open the family store").font(.headline)
                            Text("Screen time, outings, cash out and a family goal to save for together")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .onboardingCard()
            }
        } controls: {
            OnboardingPrimaryButton(title: continueTitle, action: flow.next)
        }
    }

    private func choreRow(_ chore: StarterData.StarterChore) -> some View {
        let picked = flow.draft.pickedChores.contains(chore.title)
        return Button {
            if picked { flow.draft.pickedChores.remove(chore.title) } else { flow.draft.pickedChores.insert(chore.title) }
        } label: {
            HStack(spacing: 12) {
                IconTile(symbol: chore.symbol, color: accent, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(chore.title)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.leading)
                    Text(detail(for: chore))
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 8)
                OnboardingCheck(isOn: picked)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 60)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private func detail(for chore: StarterData.StarterChore) -> String {
        var parts: [String] = []
        switch chore.repeatRule {
        case .daily: parts.append("Daily")
        case .weekdays: parts.append("Weekdays")
        case .someDays: parts.append("Tuesdays")
        case .once: parts.append("Once")
        }
        parts.append(PointWords.current().count(chore.points))
        if chore.rotates && flow.kidNames.count > 1 { parts.append("Kids take turns") }
        if chore.upForGrabs { parts.append("Up for grabs") }
        return parts.joined(separator: " · ")
    }
}
