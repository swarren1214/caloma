import SwiftData
import SwiftUI

/// Family: who's in it, how points work, allowance, reminders, the accent color and data.
struct FamilyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var allMembers: [Member]
    @Query private var points: [PointEntry]
    @Query(filter: #Predicate<Room> { !$0.isArchived }) private var rooms: [Room]

    @AppStorage(SettingsKey.pointName) private var pointName = PointName.stars.rawValue
    @AppStorage(SettingsKey.customPointName) private var customPointName = ""
    @AppStorage(SettingsKey.approvalsByDefault) private var approvalsByDefault = true
    @AppStorage(SettingsKey.streakBonus) private var streakBonus = true
    @AppStorage(SettingsKey.allowanceOn) private var allowanceOn = true
    @AppStorage(SettingsKey.centsPer100) private var centsPer100 = 500
    @AppStorage(SettingsKey.payday) private var payday = 1
    @AppStorage(SettingsKey.splitSpend) private var splitSpend = 70
    @AppStorage(SettingsKey.splitSave) private var splitSave = 20
    @AppStorage(SettingsKey.splitGive) private var splitGive = 10
    @AppStorage(SettingsKey.accentHex) private var accentHex = hexString(Brand.defaultAccentHex)
    @AppStorage(SettingsKey.homeReminders) private var homeReminders = false
    @AppStorage(SettingsKey.approvalAlerts) private var approvalAlerts = true

    @State private var addingRole: MemberRole?
    @State private var payingOut = false
    @State private var confirmsErase = false

    private var members: [Member] { allMembers.filter { !$0.isArchived } }

    var body: some View {
        Form {
            Section {
                ForEach(members) { member in
                    NavigationLink {
                        MemberEditor(member: member, role: member.role)
                    } label: {
                        HStack(spacing: 12) {
                            MemberAvatar(member, size: 38)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.name)
                                Text(member.role.label)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if member.isKid {
                                PointsLabel(points: ChoreMath.balance(of: member.id, entries: points.map(\.record)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Menu {
                    Button("Add a Kid", systemImage: "figure.child") { addingRole = .kid }
                    Button("Add a Parent", systemImage: "person") { addingRole = .parent }
                } label: {
                    Label("Add Family Member", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Members")
            } footer: {
                Text("Kids can use Kid View on a parent's phone or on a shared iPad.")
            }

            Section {
                NavigationLink {
                    FamilySharingView()
                } label: {
                    LabeledContent {
                        Text(sharingSummary)
                    } label: {
                        Label("Family Sharing", systemImage: "person.2.badge.gearshape")
                    }
                }
            } footer: {
                Text("Share with your partner so you both run the same family from your own phones.")
            }

            Section {
                NavigationLink {
                    RoomsView()
                } label: {
                    LabeledContent {
                        Text(rooms.isEmpty ? "None yet" : "\(rooms.count)")
                    } label: {
                        Label("Rooms", systemImage: "door.left.hand.open")
                    }
                }
            } header: {
                Text("House")
            } footer: {
                Text("Optional. Put chores in rooms so kids know where to go, and see the board one room at a time.")
            }

            Section {
                Picker("Call Them", selection: $pointName) {
                    ForEach(PointName.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if pointName == PointName.custom.rawValue {
                    TextField("Your word (acorns, gems)", text: $customPointName)
                        .textInputAutocapitalization(.never)
                }
                Toggle(isOn: $approvalsByDefault) {
                    settingLabel("Parents Approve Chores", "New chores wait for an OK before \(PointWords.current().plural) land")
                }
                Toggle(isOn: $streakBonus) {
                    settingLabel("Streak Bonus", "+10 for every 7 days in a row")
                }
            } header: {
                Text("Points")
            } footer: {
                Text("Each chore sets its own value.")
            }

            Section {
                Toggle(isOn: $allowanceOn) {
                    settingLabel("Convert to Allowance", "Turn \(PointWords.current().plural) into money on payday")
                }
                if allowanceOn {
                    Stepper(value: $centsPer100, in: 25...5000, step: centsPer100 < 100 ? 25 : 50) {
                        Text("100 \(PointWords.current().plural) = \(money(centsPer100))")
                            .monospacedDigit()
                    }
                    Picker("Payday", selection: $payday) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Split Every Payday")
                        SplitBar(spend: splitSpend, save: splitSave, give: splitGive, accent: accent)
                    }
                    .padding(.vertical, 8)
                    // One row each, so the steppers get the list's own spacing and separators.
                    splitStepper("Spend", value: splitSpend) { setSplit(spend: $0) }
                    splitStepper("Save", value: splitSave) { setSplit(save: $0) }
                    splitStepper("Give", value: splitGive) { setSplit(give: $0) }
                    Button("Pay Out Now") { payingOut = true }
                }
            } header: {
                Text("Allowance")
            } footer: {
                Text("Caloma keeps track of what each kid has earned. You pay out however your family does: cash, a card or a savings jar.")
            }

            Section {
                Toggle(isOn: Binding(get: { homeReminders }, set: { on in
                    homeReminders = on
                    Task {
                        if on { _ = await Reminders.requestPermission() }
                        Reminders.reschedule(in: context)
                    }
                })) {
                    settingLabel("Home Care Reminders", "A notification before each task is due")
                }
                Toggle(isOn: Binding(get: { approvalAlerts }, set: { on in
                    approvalAlerts = on
                    if on { Task { _ = await Reminders.requestPermission() } }
                })) {
                    settingLabel("Needs Your OK", "When a kid finishes a chore or asks for a reward")
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Approve or send back right from the notification. Each parent's phone gets them while Caloma is open or in the background.")
            }

            Section {
                NavigationLink {
                    MealTimesView(app: .caloma)
                } label: {
                    LabeledContent {
                        Text(HearthLink.shared.mealTimes.summary)
                    } label: {
                        Label("Meal Times", systemImage: "fork.knife")
                    }
                }
                NavigationLink {
                    AppleCalendarSettingsView()
                } label: {
                    LabeledContent {
                        Text(AppleCalendar.shared.showsAppleEvents || AppleCalendar.shared.addsFamilyEvents ? "On" : "Off")
                    } label: {
                        Label("Apple Calendar", systemImage: "calendar")
                    }
                }
            } header: {
                Text("Calendar")
            } footer: {
                Text("Meal times place BigTable's meals on the calendar, and change in BigTable too. Apple Calendar is optional: show your other calendars beside the family's, or add family events to it.")
            }

            if UIDevice.current.userInterfaceIdiom == .pad {
                Section {
                    NavigationLink {
                        KioskSettingsView()
                    } label: {
                        Label("Kiosk Mode", systemImage: "rectangle.inset.filled.and.person.filled")
                    }
                } footer: {
                    Text("Turn this iPad into the family's wall screen: the calendar all day, and a tap on a face for chores.")
                }
            }

            Section("Accent Color") {
                HStack {
                    ForEach(Brand.accents, id: \.hex) { option in
                        let on = accentHex == hexString(option.hex)
                        Button {
                            accentHex = hexString(option.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: option.hex))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if on {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .padding(3)
                                .overlay(Circle().strokeBorder(on ? Color(hex: option.hex) : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        if option.hex != Brand.accents.last?.hex { Spacer(minLength: 0) }
                    }
                }
                .padding(.vertical, 4)
            }

            AccountSection()

            Section {
                LabeledContent("Sync", value: AppConfig.cloudSyncEnabled ? (CloudSync.shared.isShared ? "iCloud, shared" : "iCloud") : "This device")
                LabeledContent("Version", value: AppConfig.version)
                Button("Erase All Caloma Data", role: .destructive) { confirmsErase = true }
            } header: {
                Text("Data")
            } footer: {
                Text("Your family's data lives in your own iCloud. Caloma has no servers and can't see it.")
            }
        }
        .navigationTitle("Family")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
        .sheet(item: $addingRole) { role in
            NavigationStack { MemberEditor(member: nil, role: role) }
        }
        .sheet(isPresented: $payingOut) {
            PayOutSheet()
        }
        .confirmationDialog("Erase everything?", isPresented: $confirmsErase, titleVisibility: .visible) {
            Button("Erase All Data", role: .destructive) {
                Family.eraseAll(in: context)
                dismiss()
            }
        } message: {
            Text(CloudSync.shared.role == .participant
                 ? "This iPhone leaves the family and Caloma starts over here. The family's data stays with everyone else."
                 : "Every chore, reward, point, event and home care task is deleted from this device and iCloud\(CloudSync.shared.isShared ? ", for everyone in the family" : ""), and Caloma starts over. This can't be undone.")
        }
    }

    private var sharingSummary: String {
        switch CloudSync.shared.role {
        case .solo: "Not shared"
        case .owner: "Shared"
        case .participant: "Joined"
        }
    }

    private func splitStepper(_ name: String, value: Int, set: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(get: { value }, set: set), in: 0...100, step: 5) {
            Text("\(name) \(value)%")
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.vertical, 2)
    }

    private func settingLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func money(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    /// Changing one share takes the difference from the others, so the three add up to 100.
    private func setSplit(spend: Int? = nil, save: Int? = nil, give: Int? = nil) {
        var values = (spend ?? splitSpend, save ?? splitSave, give ?? splitGive)
        var over = values.0 + values.1 + values.2 - 100
        // Take from (or give to) the shares that weren't touched, last first.
        if spend == nil {
            let change = max(min(over, values.0), values.0 - 100)
            values.0 -= change
            over -= change
        }
        if give == nil && over != 0 {
            let change = max(min(over, values.2), values.2 - 100)
            values.2 -= change
            over -= change
        }
        if save == nil && over != 0 {
            let change = max(min(over, values.1), values.1 - 100)
            values.1 -= change
        }
        splitSpend = values.0
        splitSave = values.1
        splitGive = values.2
    }
}

/// Spend, save and give as one bar with a legend.
struct SplitBar: View {
    var spend: Int
    var save: Int
    var give: Int
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(accent).frame(width: proxy.size.width * CGFloat(spend) / 100)
                    Rectangle().fill(Color(hex: 0x0A84FF)).frame(width: proxy.size.width * CGFloat(save) / 100)
                    Rectangle().fill(Color(hex: 0xFF9F0A)).frame(width: proxy.size.width * CGFloat(give) / 100)
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            .animation(.snappy, value: spend)
            HStack(spacing: 14) {
                legend("Spend", spend, accent)
                legend("Save", save, Color(hex: 0x0A84FF))
                legend("Give", give, Color(hex: 0xFF9F0A))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spend \(spend) percent, save \(save) percent, give \(give) percent")
    }

    private func legend(_ name: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text("\(name) \(value)%")
        }
    }
}

/// Paying kids their allowance: what each has, in money and split three ways.
private struct PayOutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var points: [PointEntry]
    @Query private var redemptions: [Redemption]
    @AppStorage(SettingsKey.centsPer100) private var centsPer100 = 500
    @AppStorage(SettingsKey.splitSpend) private var splitSpend = 70
    @AppStorage(SettingsKey.splitSave) private var splitSave = 20
    @AppStorage(SettingsKey.splitGive) private var splitGive = 10

    @State private var paid: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(members.filter { $0.isKid && !$0.isArchived }) { kid in
                    let available = ChoreMath.spendable(of: kid.id, entries: points.map(\.record), redemptions: redemptions.map(\.record))
                    let cents = RewardMath.cents(for: max(available, 0), centsPer100: centsPer100)
                    let split = RewardMath.split(cents: cents, spend: splitSpend, save: splitSave, give: splitGive)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            MemberAvatar(kid, size: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kid.name).font(.headline)
                                Text(PointWords.current().count(available))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(money(cents))
                                .font(.title3.bold())
                                .monospacedDigit()
                        }
                        if cents > 0 {
                            Text("Spend \(money(split.spend)) · Save \(money(split.save)) · Give \(money(split.give))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                withAnimation {
                                    Family.payOut(available, to: kid.id, cents: cents, in: context)
                                    paid.insert(kid.id)
                                }
                            } label: {
                                Text("Mark \(money(cents)) Paid").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                        } else if paid.contains(kid.id) {
                            Label("Paid", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("Pay Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
        }
    }

    private func money(_ cents: Int) -> String {
        (Double(cents) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }
}

#Preview {
    NavigationStack { FamilyView() }
        .previewEnvironment()
}
