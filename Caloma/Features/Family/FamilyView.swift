import SwiftData
import SwiftUI

/// Profile: the shared Hearth Profile with Caloma's rooms, points, allowance, reminders and calendar.
struct FamilyView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.accent) private var accent
    @Query(sort: \Member.sortOrder) private var allMembers: [Member]
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
    @AppStorage(SettingsKey.homeReminders) private var homeReminders = false
    @AppStorage(SettingsKey.approvalAlerts) private var approvalAlerts = true

    @State private var household = HearthHouseholdStore.shared
    @State private var payingOut = false
    @AppStorage(SettingsKey.appleUserID) private var appleUserID = ""

    private var members: [Member] { allMembers.filter { !$0.isArchived } }

    var body: some View {
        // The shared Hearth Profile (HearthProfile.swift), with Caloma's own sections in the middle.
        HearthProfileView(
            app: .caloma,
            profile: accountProfile,
            sync: HearthProfileSync(summary: "The family’s chores, calendar and rewards", sharing: syncSharing) {
                CloudSync.shared.syncSnapshot
            } syncNow: {
                await CloudSync.shared.syncNow()
            },
            erase: HearthProfileErase(
                app: .caloma,
                question: "Erase everything?",
                message: CloudSync.shared.isJoined
                    ? "Caloma starts over on this \(UIDevice.current.localizedModel) and downloads the family's data again. The family's data stays with everyone else."
                    : "Every chore, reward, point, event and home care task is deleted from this device and iCloud\(CloudSync.shared.isShared ? ", for everyone in the family" : ""), and Caloma starts over. This can't be undone.",
                confirm: "Erase All Data",
                footer: "Caloma keeps your family's information on your devices and in iCloud. Purchases are checked with RevenueCat."
            ) {
                Family.eraseAll(in: context)
                HearthProfilePresenter.shared.dismiss()
            }
        ) {
            AccountSection()
        } settings: {
            calomaSections
        } data: {
            // TestFlight and Debug builds: why two devices don't match.
            if CloudSync.showsSyncDetails {
                NavigationLink {
                    SyncDetailsView()
                } label: {
                    Label("Sync Details", systemImage: "stethoscope")
                        .tint(.primary)
                }
            }
        } about: {
        }
        .refreshesFromICloud()
        .sheet(isPresented: $payingOut) {
            PayOutSheet()
        }
    }

    /// Who's signed in with Apple, for the account card at the top (nil shows Sign in with Apple).
    private var accountProfile: HearthAccountProfile? {
        guard !appleUserID.isEmpty else { return nil }
        let shared = HearthAccounts.appleID().flatMap { $0.userID == appleUserID ? $0 : nil }
        return HearthAccountProfile(name: shared?.fullName, email: shared?.email)
    }

    /// Caloma's own settings: the wall screen, rooms, points, allowance, reminders and calendar.
    @ViewBuilder
    private var calomaSections: some View {
        if case .waiting = CloudSync.shared.location {
            Section {
                Label {
                    Text(waitingText)
                } icon: {
                    Image(systemName: "hourglass")
                }
                // The icon in the text color, not the app's.
                .tint(.primary)
            } footer: {
                Text("Changes you make here are kept on this \(UIDevice.current.localizedModel) until then.")
            }
        }

        // iPad only: the wall screen comes next, since it's set up once and opened often.
        if UIDevice.current.userInterfaceIdiom == .pad {
            Section {
                NavigationLink {
                    KioskSettingsView()
                } label: {
                    Label("Family Board", systemImage: "rectangle.inset.filled.and.person.filled")
                        // The row's icon in its text color, not the app's.
                        .tint(.primary)
                }
            } footer: {
                Text("Turn this iPad into the family's wall screen: the calendar all day, and a tap on a face for chores.")
            }
        }

        Section {
            NavigationLink {
                RoomsView()
            } label: {
                LabeledContent {
                    Text(rooms.isEmpty ? "None yet" : "\(rooms.count)")
                } label: {
                    Label("Rooms", systemImage: "door.left.hand.open")
                        .tint(.primary)
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
            .tint(.primary)
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
                .tint(.primary)
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
                    .tint(.primary)
            }
        } header: {
            Text("Allowance")
        } footer: {
            Text("Caloma keeps track of what each kid has earned. You pay out however your family does: cash, a card or a savings jar.")
        }

        Section {
            // Home Care is part of Caloma Plus and Hearth+.
            if CalomaPlus.isUnlocked {
                Toggle(isOn: Binding(get: { homeReminders }, set: { on in
                    homeReminders = on
                    Task {
                        if on { _ = await Reminders.requestPermission() }
                        Reminders.reschedule(in: context)
                    }
                })) {
                    settingLabel("Home Care Reminders", "A notification before each task is due")
                }
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
                        .tint(.primary)
                }
            }
            NavigationLink {
                AppleCalendarSettingsView()
            } label: {
                LabeledContent {
                    Text(AppleCalendar.shared.showsAppleEvents || AppleCalendar.shared.addsFamilyEvents ? "On" : "Off")
                } label: {
                    Label("Apple Calendar", systemImage: "calendar")
                        .tint(.primary)
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Meal times place BigTable's meals on the calendar, and change in BigTable too. Apple Calendar is optional: show your other calendars beside the family's, or add family events to it.")
        }

    }

    /// Who the family is shared with, for the iCloud Sync card: the parents, since they're the
    /// ones on their own Apple Accounts.
    private var syncSharing: HearthSyncSharing? {
        guard CloudSync.shared.isShared else { return nil }
        let parents = members.filter { $0.role == .parent }.prefix(4)
        return HearthSyncSharing(
            label: "Your family",
            people: parents.map { HearthSyncSharing.Person(id: $0.id.uuidString, initial: $0.initial, colorHex: $0.color.hex) }
        )
    }

    /// Waiting for the household's owner to share the family's Caloma.
    private var waitingText: String {
        guard household.isMember else {
            // From before the Hearth household: another family's Caloma, kept until this
            // account joins their household.
            return "This \(UIDevice.current.localizedModel) has another family's Caloma. It syncs again once you join their household."
        }
        let name = household.organizer?.firstName ?? ""
        return "Waiting for \(name.isEmpty ? "the person who set up your household" : name) to open Caloma to share the family's chores, calendar and rewards."
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
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .refreshesFromICloud()
            .navigationTitle("Pay Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetDoneButton { dismiss() }
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
