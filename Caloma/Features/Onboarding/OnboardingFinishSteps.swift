import CloudKit
import HomeKit
import SwiftData
import SwiftUI
import UserNotifications

// MARK: - 6 · Make it your home

/// The extras, each asking for access only when it's switched on. Leaving this screen saves
/// the family.
struct HomeExtrasStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @State private var calendarAllowed: Bool?
    /// Home care's starter list was added once already (Caloma was set up here before).
    private let alreadySeeded = UserDefaults.standard.bool(forKey: SettingsKey.seeded)
    private var home: HomeBridge { HomeBridge.shared }
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        OnboardingScreen(title: "Make it your home", subtitle: "Turn on what you'll use. Each one asks for access only when you switch it on.") {
            OnboardingSymbolIcon(symbol: "sparkles", color: Color(hex: 0x5E5CE6))
        } content: {
            VStack(spacing: 12) {
                OnboardingSwitchCard(
                    symbol: "calendar",
                    color: KidColor.pink.color,
                    title: "Family calendar",
                    detail: "Everyone's events by color, with your Apple Calendar beside them.",
                    isOn: Binding(get: { flow.extras.calendar }, set: setCalendar),
                    tag: calendarTag,
                    tagColor: calendarAllowed == false ? Brand.waiting : Color(hex: 0x1E9E6A)
                )
                OnboardingSwitchCard(
                    symbol: "wrench.and.screwdriver.fill",
                    color: Brand.waiting,
                    title: "Home care reminders",
                    detail: "Starter list: HVAC filter, smoke detectors, water heater. Edit any time.",
                    isOn: Binding(get: { flow.extras.homeCare }, set: { flow.extras.homeCare = $0 }),
                    tag: alreadySeeded ? nil : "\(StarterData.homeTasks.count) tasks added"
                )
                OnboardingSwitchCard(
                    symbol: "lightbulb.fill",
                    color: KidColor.teal.color,
                    title: "Apple Home",
                    detail: "Lights, locks and cameras in Control, and your rooms for chores.",
                    isOn: Binding(get: { flow.extras.appleHome }, set: setAppleHome),
                    tag: homeTag,
                    tagColor: home.authorized == false ? Brand.waiting : Color(hex: 0x1E9E6A)
                )
                OnboardingSwitchCard(
                    symbol: "ipad.landscape",
                    color: Color(hex: 0x5E5CE6),
                    title: "Family Board",
                    detail: isPad
                        ? "Hang this iPad on the wall: the week, faces, the doorbell."
                        : "Hang an iPad on the wall: the week, faces, the doorbell. Set it up on the iPad.",
                    isOn: Binding(get: { flow.extras.familyBoard }, set: { flow.extras.familyBoard = $0 }),
                    tag: isPad ? "You can start it in a moment" : "On the iPad: Family › Family Board"
                )
            }
        } controls: {
            OnboardingPrimaryButton(title: "Continue") {
                if flow.commit(in: context) { flow.next() }
            }
        }
    }

    private var calendarTag: String? {
        switch calendarAllowed {
        case true?: "Calendars allowed"
        case false?: "Calendar access is off in Settings"
        case nil: nil
        }
    }

    private var homeTag: String? {
        switch home.authorized {
        case true?:
            let rooms = home.home?.rooms.count ?? 0
            return rooms > 0 ? "Home access allowed · \(rooms) \(rooms == 1 ? "room" : "rooms") found" : "Home access allowed"
        case false?:
            return "Home access is off in Settings"
        case nil:
            return "Asking Apple Home…"
        }
    }

    private func setCalendar(_ on: Bool) {
        flow.extras.calendar = on
        let calendar = AppleCalendar.shared
        guard on else {
            calendar.showsAppleEvents = false
            return
        }
        Task {
            let allowed = calendar.hasAccess ? true : await calendar.requestAccess()
            calendarAllowed = allowed
            calendar.showsAppleEvents = allowed
        }
    }

    private func setAppleHome(_ on: Bool) {
        flow.extras.appleHome = on
        // Asks for Home access the first time; HomeBridge remembers the answer.
        if on { home.start() }
    }
}

// MARK: - 7 · Notifications

struct NotificationsStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.modelContext) private var context
    @Environment(\.onboardingLayout) private var layout
    @AppStorage(SettingsKey.homeReminders) private var homeReminders = false
    @AppStorage(SettingsKey.approvalAlerts) private var approvalAlerts = true
    @State private var asking = false

    private var allowed: Bool { flow.notificationsAllowed == true }

    var body: some View {
        OnboardingScreen(title: "Know when it's your turn", subtitle: "A chore waiting for your OK, a filter due Thursday, someone at the door. Never ads, never streaks.") {
            NotificationStack(kidName: flow.firstKidName ?? "Ella", word: PointWords.current().plural)
                .frame(maxWidth: layout.isWide ? 380 : .infinity)
        } content: {
            if let answer = flow.notificationsAllowed {
                Label(
                    answer ? "Notifications are on. Fine-tune them any time in Family." : "Notifications are off. You can turn them on in Settings › Caloma.",
                    systemImage: answer ? "checkmark.circle.fill" : "bell.slash.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(answer ? Color(hex: 0x1E9E6A) : .secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onboardingCard()
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        } controls: {
            if flow.notificationsAllowed == nil {
                OnboardingPrimaryButton(title: "Turn On Notifications", busy: asking, action: ask)
                    .disabled(asking)
                OnboardingSecondaryButton(title: "Not Now", action: flow.next)
            } else {
                OnboardingPrimaryButton(title: "Continue", action: flow.next)
            }
        }
        .animation(.smooth, value: flow.notificationsAllowed)
    }

    private func ask() {
        asking = true
        Task {
            let granted = await Reminders.requestPermission()
            asking = false
            flow.notificationsAllowed = granted
            guard granted else { return }
            approvalAlerts = true
            if flow.extras.homeCare {
                homeReminders = true
                Reminders.reschedule(in: context)
            }
            EventAlerts.reschedule(in: context)
        }
    }
}

/// Three sample notifications, stacked and gently floating, as on the lock screen.
private struct NotificationStack: View {
    var kidName: String
    var word: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var samples: [(when: String, body: String)] {
        [
            ("now", "\(kidName) finished Unload the dishwasher. Tap to OK +15 \(word)."),
            ("2h ago", "Replace HVAC filter is due Thursday."),
            ("Yesterday", "Someone's at the front door."),
        ]
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: -8) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    let float = reduceMotion ? 0 : sin(time * 2 * .pi / Double(4 + index)) * 3
                    HStack(alignment: .top, spacing: 10) {
                        AppIconBadge(size: 34)
                            .shadow(radius: 0)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Caloma").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sample.when).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(sample.body)
                                .font(.subheadline)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.1), radius: 15, y: 8)
                    .scaleEffect(1 - CGFloat(index) * 0.05)
                    .opacity(1 - Double(index) * 0.22)
                    .offset(y: float)
                    .zIndex(Double(samples.count - index))
                }
            }
        }
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample notifications: a chore to OK, a home care task coming up, and someone at the door.")
    }
}

// MARK: - 8 · Run it together

/// Inviting the other parent to the household: one invitation for every Hearth app. Caloma's
/// family is shared with them by itself once they join.
struct InviteStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.accent) private var accent
    @AppStorage(SettingsKey.familyName) private var familyName = ""
    @State private var household = HearthHouseholdStore.shared
    @State private var sending = false
    @State private var error: String?

    private var title: String {
        let name = familyName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        if let householdName = household.info?.name.trimmingCharacters(in: .whitespaces), !householdName.isEmpty { return householdName }
        let me = household.me?.firstName ?? ""
        return me.isEmpty ? "Our Family" : "\(me)'s Family"
    }

    /// Another parent already in the household, by first name.
    private var partner: String? {
        household.parents.first { $0.id != household.me?.id }.map(\.firstName)
    }

    var body: some View {
        OnboardingScreen(
            title: "Run it together",
            subtitle: "Invite \(partner ?? "another parent"). They see everything, give the OK, and get the same reminders."
        ) {
            OnboardingSymbolIcon(symbol: "person.2.fill", color: KidColor.pink.color)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingSectionLabel(text: "Your family's name")
                TextField("Family name", text: $familyName, prompt: Text(title))
                    .font(.body.weight(.semibold))
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .onboardingCard(cornerRadius: 16)

                invitePreview
                    .padding(.vertical, 6)

                Text("\(Text("Kids don't need accounts.").bold()) Open Kid View on any phone or iPad, or hang an iPad on the wall as the Family Board.")
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.12), in: .rect(cornerRadius: 18, style: .continuous))

                if let error {
                    Label(error, systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(Brand.late)
                }
            }
        } controls: {
            if flow.invited {
                OnboardingPrimaryButton(title: "Continue", action: flow.next)
                Text("Invite sent: they'll join when they open it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
            } else {
                OnboardingPrimaryButton(title: sending ? "Getting Your Invite Ready…" : "Send Invite", busy: sending, action: invite)
                    .disabled(sending)
                OnboardingSecondaryButton(title: "Later", action: flow.next)
            }
        }
        .animation(.smooth, value: flow.invited)
    }

    /// What the invite looks like in Messages.
    private var invitePreview: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Come run the house with me on Caloma.")
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(hex: 0x0A84FF), in: .rect(cornerRadius: 18, style: .continuous))
            HStack(spacing: 12) {
                AppIconBadge(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Join \(title)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("Household · Shared with iCloud")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: 300)
            .onboardingCard(cornerRadius: 18)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private func invite() {
        sending = true
        error = nil
        Task {
            defer { sending = false }
            if familyName.trimmingCharacters(in: .whitespaces).isEmpty { familyName = title }
            // The household's invitation: Apple's sharing screen, from the household store.
            let earlier = household.problem
            await household.presentInvite(as: .parent)
            if let problem = household.problem, problem != earlier {
                self.error = problem
            } else {
                flow.invited = true
            }
        }
    }
}

// MARK: - 9 · Welcome home

struct AllSetStep: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(AppRouter.self) private var router
    @Environment(\.accent) private var accent
    @Environment(\.onboardingLayout) private var layout
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @AppStorage(SettingsKey.familyName) private var familyName = ""
    @AppStorage(SettingsKey.approvalsByDefault) private var approvalsByDefault = true
    @AppStorage(SettingsKey.allowanceOn) private var allowanceOn = true
    @AppStorage(SettingsKey.centsPer100) private var centsPer100 = 500

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @State private var settingPIN = false
    @State private var celebrated = false

    private var welcome: String {
        let name = familyName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Welcome home" : "Welcome home, \(name)"
    }

    private var summary: String {
        let draft = flow.draft
        let kids = flow.kidNames.count
        var parts = [kids == 1 ? "1 kid" : "\(kids) kids"]
        if kids > 0 { parts.append(draft.pickedCount == 1 ? "1 chore" : "\(draft.pickedCount) chores") }
        var points = PointWords.current().plural
        if allowanceOn {
            points += ", \((Double(centsPer100) / 100).formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))) per 100"
        }
        parts.append(points)
        if draft.addRewards { parts.append("store open") }
        return parts.joined(separator: " · ")
    }

    private struct NextUp: Identifiable {
        var id: String { title }
        var symbol: String
        var color: Color
        var title: String
        var detail: String
    }

    private var nextUp: [NextUp] {
        var rows: [NextUp] = []
        if let kid = flow.firstKidName {
            rows.append(NextUp(symbol: "figure.child", color: accent, title: "Hand \(isPad ? "an iPad" : "a phone") to \(kid)", detail: "Kid View shows just their day, with big buttons."))
        } else {
            rows.append(NextUp(symbol: "person.badge.plus", color: accent, title: "Add your kids", detail: "Family › Household › Add Person, then pick their chores."))
        }
        if approvalsByDefault {
            rows.append(NextUp(symbol: "checkmark.seal.fill", color: Color(hex: 0x1E9E6A), title: "Check Needs Your OK", detail: "Finished chores wait there for a tap."))
        } else {
            rows.append(NextUp(symbol: "calendar", color: KidColor.pink.color, title: "Plan the week", detail: "Add the first events to the family calendar."))
        }
        if isPad && flow.extras.familyBoard {
            rows.append(NextUp(symbol: "ipad.landscape", color: Color(hex: 0x5E5CE6), title: "Start the Family Board", detail: "The button below turns this iPad into it."))
        } else {
            rows.append(NextUp(symbol: "ipad.landscape", color: Color(hex: 0x5E5CE6), title: "Set up the Family Board", detail: "On an iPad: Family › Family Board."))
        }
        return rows
    }

    var body: some View {
        OnboardingScreen(title: welcome, subtitle: summary, centered: true) {
            DoneBadge(size: layout.isShort ? 130 : 170)
        } content: {
            VStack(spacing: 10) {
                ForEach(nextUp) { row in
                    HStack(spacing: 14) {
                        IconTile(symbol: row.symbol, color: row.color, size: 42)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.subheadline.weight(.bold))
                            Text(row.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .onboardingCard(cornerRadius: 18)
                    .accessibilityElement(children: .combine)
                }
            }
        } controls: {
            if isPad && flow.extras.familyBoard {
                OnboardingPrimaryButton(title: "Start the Family Board", action: startBoard)
                OnboardingSecondaryButton(title: "I'll Explore First") { finish(openBoard: false) }
            } else {
                OnboardingPrimaryButton(title: "Start Using Caloma") { finish(openBoard: false) }
            }
        }
        .sensoryFeedback(.success, trigger: celebrated)
        .onAppear { celebrated = true }
        // The Family Board needs a parent PIN first, so there's always a way back out.
        .sheet(isPresented: $settingPIN) {
            PINSetupSheet {
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    finish(openBoard: true)
                }
            }
            .tint(accent)
        }
    }

    private func startBoard() {
        if ParentPIN.isSet {
            finish(openBoard: true)
        } else {
            settingPIN = true
        }
    }

    private func finish(openBoard: Bool) {
        if openBoard { router.openKiosk() }
        onboarded = true
    }
}

/// The big check, with confetti bursting out around it.
private struct DoneBadge: View {
    var size: CGFloat
    @Environment(\.accent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = false

    private var colors: [Color] {
        [Brand.star, accent, Color(hex: 0x0A84FF), Color(hex: 0x1E9E6A), Color(hex: 0xAF52DE), Color(hex: 0xFF9F0A), Color(hex: 0x5E5CE6)]
    }

    var body: some View {
        ZStack {
            ForEach(0..<16, id: \.self) { index in
                let angle = Double(index) / 16 * 2 * .pi
                let radius = size * (0.42 + CGFloat(index % 3) * 0.07)
                let x: CGFloat = burst ? CGFloat(cos(angle)) * radius : 0
                let y: CGFloat = burst ? CGFloat(sin(angle)) * radius * 0.8 : 0
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(colors[index % colors.count])
                    .frame(width: index.isMultiple(of: 2) ? 10 : 7, height: index.isMultiple(of: 2) ? 10 : 14)
                    .rotationEffect(.degrees(burst ? Double(index * 47) : 0))
                    .offset(x: x, y: y)
                    .opacity(burst ? 1 : 0)
                    .scaleEffect(burst ? 1 : 0.2)
            }
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size * 0.56, height: size * 0.56)
                .background(accent.gradient, in: Circle())
                .shadow(color: accent.opacity(0.4), radius: 18, y: 10)
                .scaleEffect(burst ? 1 : 0.6)
        }
        .frame(width: size * 1.3, height: size)
        .onAppear {
            if reduceMotion {
                burst = true
            } else {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.62).delay(0.15)) { burst = true }
            }
        }
        .accessibilityHidden(true)
    }
}
