import SwiftData
import SwiftUI

/// A parent's screen on the wall, for the moment they pass by: a hello and the time, their
/// tasks, their evening, what's waiting on their OK (visible to them, actionable only with the
/// PIN), how each kid is doing, the home, and dinner or the week ahead. Every card has
/// something worth seeing even when there's nothing to do.
struct AdultContextView: View {
    var member: Member

    @Environment(KioskSession.self) private var session
    @Environment(\.modelContext) private var context
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query(filter: #Predicate<ChoreCompletion> { $0.statusRaw == "pending" }, sort: \ChoreCompletion.completedAt) private var pending: [ChoreCompletion]
    @Query(filter: #Predicate<Redemption> { $0.statusRaw == "pending" }, sort: \Redemption.requestedAt) private var requests: [Redemption]
    @Query private var rewards: [Reward]
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @Query(filter: #Predicate<HomeTask> { !$0.isArchived }, sort: \HomeTask.nextDue) private var homeTasks: [HomeTask]
    @Query(filter: #Predicate<FamilyList> { !$0.isArchived }) private var lists: [FamilyList]
    @Query private var listItems: [FamilyListItem]
    @Query private var listChecks: [FamilyListCheck]

    @State private var picking = false
    /// The parent PIN, then every Apple Home control.
    @State private var homeSheet: KioskHomeSheet?

    private var color: Color { member.color.color }
    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: [])
    }

    private static let green = Color(hex: 0x1E9E6A)

    var body: some View {
        let family = family
        let agenda = agenda
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(agenda: agenda)

                HStack(alignment: .top, spacing: 16) {
                    tasksCard(family)
                    eveningCard(agenda)
                    approvalsCard
                        .frame(width: 330)
                }
                .fixedSize(horizontal: false, vertical: true)

                kidsCard(family)

                HStack(alignment: .top, spacing: 16) {
                    if HomeBridge.shared.statusItems.isEmpty {
                        homeCareCard
                    } else {
                        homeStatusCard
                    }
                    if let dinner = HearthLink.shared.dinner(on: .now) {
                        dinnerCard(dinner)
                    } else {
                        weekCard
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .refreshesFromICloud()
        .background {
            // A soft wash of their color behind the greeting.
            LinearGradient(colors: [color.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $picking) {
            WhoIsHerePicker(current: member.id)
        }
    }

    // MARK: Header

    private func header(agenda: [EventOccurrence]) -> some View {
        HStack(alignment: .center, spacing: 20) {
            MemberAvatar(member, size: 84)
                .padding(5)
                .overlay(Circle().strokeBorder(color, lineWidth: 5))
                .shadow(color: color.opacity(0.35), radius: 16, y: 6)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(kioskGreeting()), \(member.name)")
                    .font(.system(size: 40, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(summary(agenda: agenda))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if session.source == .face {
                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: 0x34C759)).frame(width: 8, height: 8)
                        Text("Recognized")
                            .foregroundStyle(.secondary)
                        Button("Not \(member.name)?") { picking = true }
                            .fontWeight(.semibold)
                            .foregroundStyle(color)
                            .buttonStyle(.plain)
                    }
                    .font(.subheadline)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 16)
            TimelineView(.everyMinute) { context in
                VStack(alignment: .trailing, spacing: 0) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 54, weight: .thin))
                        .monospacedDigit()
                    Text(context.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func summary(agenda: [EventOccurrence]) -> String {
        var parts: [String] = []
        if let next = agenda.first, Calendar.current.isDateInToday(next.start) {
            parts.append(next.event.isAllDay ? "\(next.event.title) today." : "\(next.event.title) at \(next.start.formatted(date: .omitted, time: .shortened)).")
        }
        let waiting = pending.count + requests.count
        if waiting == 1 {
            parts.append("One thing is waiting on you.")
        } else if waiting > 1 {
            parts.append("\(waiting) things are waiting on you.")
        }
        if parts.isEmpty {
            let kids = members.filter { $0.isKid && !$0.isArchived }
            let left = kids.reduce(0) { total, kid in
                let progress = family.progress(for: kid)
                return total + (progress.total - progress.done)
            }
            return left > 0 ? "A calm one. The kids have \(left) jobs to go." : "All quiet. Enjoy it."
        }
        return parts.joined(separator: " ")
    }

    // MARK: Tasks

    private func tasksCard(_ family: FamilySnapshot) -> some View {
        // Up-for-grabs chores are volunteer jobs, not this parent's: they only show once claimed.
        let items = family.items(for: member).filter { !$0.chore.upForGrabs || $0.memberID == member.id }
        let due = dueHomeCare
        let listed = listThings
        let left = items.filter { $0.status == .open }.count + due.count + listed.count
        return card(title: "Your tasks", symbol: "checklist", tint: color, trailing: left == 0 ? nil : "\(left) left") {
            if items.isEmpty && due.isEmpty && listed.isEmpty {
                emptyState(symbol: "checkmark.seal.fill", tint: Self.green, title: "All caught up", message: "Nothing on your list today.")
            } else if left == 0 {
                emptyState(symbol: "checkmark.seal.fill", tint: Self.green, title: "All done", message: "Every task is checked off.")
            }
            ForEach(left == 0 ? [BoardItem]() : items) { item in
                taskRow(title: item.chore.title, detail: item.status.isDone ? "Done" : "Chore", tag: "Chore", tint: color, done: item.status.isDone, late: false) {
                    toggle(item)
                }
            }
            // Their part of any list: open things only, so it doesn't grow with every tick.
            ForEach(listed) { entry in
                taskRow(title: entry.item.title, detail: ListText.when(entry.list), tag: entry.list.title, tint: color, done: false, late: false) {
                    withAnimation(.snappy) { FamilyLists.toggle(entry.item, for: member.id, in: context) }
                }
            }
            ForEach(due) { task in
                let late = Calendar.current.startOfDay(for: task.nextDue) < Calendar.current.startOfDay(for: .now)
                taskRow(title: task.name, detail: dueLabel(task), tag: "Home Care", tint: late ? Brand.late : Brand.waiting, done: false, late: late) {
                    withAnimation(.snappy) { Family.markHomeTaskDone(task, by: member.id, in: context) }
                }
            }
        }
    }

    /// This parent's things still to do on the lists that are on now.
    private var listThings: [ListThing] {
        FamilyLists.active(lists).flatMap { list in
            FamilyLists.items(of: list, for: member.id, in: listItems)
                .filter { !FamilyLists.isDone($0, for: member.id, checks: listChecks) }
                .map { ListThing(list: list, item: $0) }
        }
    }

    private struct ListThing: Identifiable {
        var list: FamilyList
        var item: FamilyListItem
        var id: UUID { item.id }
    }

    /// Home care that's late or due within three days.
    private var dueHomeCare: [HomeTask] {
        let calendar = Calendar.current
        let soon = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: .now)) ?? .now
        return Array(homeTasks.filter { calendar.startOfDay(for: $0.nextDue) <= soon }.prefix(3))
    }

    private func dueLabel(_ task: HomeTask) -> String {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: calendar.startOfDay(for: task.nextDue)).day ?? 0
        var label: String
        switch days {
        case ..<(-1): label = "\(-days) days late"
        case -1: label = "1 day late"
        case 0: label = "Due today"
        case 1: label = "Due tomorrow"
        default: label = "Due " + task.nextDue.formatted(.dateTime.weekday(.wide))
        }
        if !task.details.isEmpty { label += " · " + task.details }
        return label
    }

    private func toggle(_ item: BoardItem) {
        withAnimation(.snappy) {
            if item.status.isDone {
                guard let id = item.completionID else { return }
                let target = id
                var descriptor = FetchDescriptor<ChoreCompletion>(predicate: #Predicate { $0.id == target })
                descriptor.fetchLimit = 1
                if let completion = try? context.fetch(descriptor).first {
                    Family.undo(completion, in: context)
                }
            } else {
                // A parent checking off their own chore needs nobody's OK.
                Family.markDone(item, by: member.id, byParent: true, in: context)
            }
        }
    }

    private func taskRow(title: String, detail: String, tag: String, tint: Color, done: Bool, late: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if done {
                        Circle().fill(Self.green)
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .heavy))
                            .foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(tint, lineWidth: 2.5)
                    }
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .strikethrough(done)
                        .foregroundStyle(done ? .secondary : .primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(late ? Brand.late : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(tag)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .foregroundStyle(tint)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 9))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(done ? .isSelected : [])
    }

    // MARK: Evening

    /// What's left today for this parent, then the next thing after today.
    private var agenda: [EventOccurrence] {
        let calendar = Calendar.current
        let now = Date.now
        let mine = events.map(\.record).filter { $0.includes(member.id) || $0.driverID == member.id }
        guard let end = calendar.date(byAdding: .day, value: 7, to: now) else { return [] }
        let all = CalendarMath.occurrences(of: mine, from: now, through: end)
            .filter { $0.end > now }
            .sorted(by: CalendarMath.order)
        let today = all.filter { calendar.isDateInToday($0.start) || $0.start < now }
        let later = all.first { !calendar.isDateInToday($0.start) && $0.start >= now }
        return Array(today.prefix(4)) + (later.map { [$0] } ?? [])
    }

    private func eveningCard(_ agenda: [EventOccurrence]) -> some View {
        let driving = agenda.first { $0.event.driverID == member.id }
        let hour = Calendar.current.component(.hour, from: .now)
        let free: (symbol: String, tint: Color, title: String) = hour >= 17
            ? ("moon.stars.fill", Color(hex: 0x5E5CE6), "Your evening is free")
            : (hour >= 12 ? ("sun.max.fill", Color(hex: 0xF5A623), "Your afternoon is free") : ("sun.horizon.fill", Color(hex: 0xE8650F), "Your day is clear"))
        return card(title: eveningTitle, symbol: "calendar", tint: Color(hex: 0x0A84FF), trailing: nil) {
            if agenda.isEmpty {
                emptyState(symbol: free.symbol, tint: free.tint, title: free.title, message: "Nothing else on the calendar this week.")
            }
            ForEach(agenda) { occurrence in
                HStack(alignment: .top, spacing: 12) {
                    Text(timeLabel(occurrence))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(eventColor(occurrence.event))
                        .frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(occurrence.event.title)
                            .font(.body.weight(.semibold))
                        Text(eventDetail(occurrence.event))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let driving {
                Label {
                    Text("You're driving: \(driving.event.title)" + (driving.event.location.isEmpty ? "" : " · \(driving.event.location)"))
                        .lineLimit(2)
                } icon: {
                    Image(systemName: "car.fill")
                        .foregroundStyle(Color(hex: 0x0A84FF))
                }
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
            }
        }
    }

    private var eveningTitle: String {
        let hour = Calendar.current.component(.hour, from: .now)
        return hour >= 17 ? "Your evening" : (hour >= 12 ? "Your afternoon" : "Your day")
    }

    private func timeLabel(_ occurrence: EventOccurrence) -> String {
        if !Calendar.current.isDateInToday(occurrence.start) && occurrence.start > .now {
            return Calendar.current.isDateInTomorrow(occurrence.start) ? "Tomorrow" : occurrence.start.formatted(.dateTime.weekday(.abbreviated))
        }
        return occurrence.event.isAllDay ? "All day" : occurrence.start.formatted(date: .omitted, time: .shortened)
    }

    private func eventColor(_ event: EventRecord) -> Color {
        if event.attendeeIDs.count == 1, let who = members.first(where: { $0.id == event.attendeeIDs[0] }) {
            return who.color.color
        }
        return color
    }

    private func eventDetail(_ event: EventRecord) -> String {
        var parts: [String] = []
        if event.isEveryone {
            parts.append("Everyone")
        } else {
            let names = event.attendeeIDs.compactMap { id in members.first { $0.id == id }?.name }
            if !names.isEmpty { parts.append(names.formatted(.list(type: .and))) }
        }
        if let driver = event.driverID, let who = members.first(where: { $0.id == driver }) {
            parts.append(driver == member.id ? "you're driving" : "\(who.name) drives")
        } else if !event.location.isEmpty {
            parts.append(event.location)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Needs your OK

    private var approvalsCard: some View {
        let waiting = pending.count + requests.count
        return card(title: "Needs your OK", symbol: "hand.raised.fill", tint: Color(hex: 0xFF9F0A), trailing: waiting == 0 ? nil : waiting.formatted()) {
            if waiting == 0 {
                emptyState(symbol: "hand.thumbsup.fill", tint: Self.green, title: "Nothing waiting", message: "The kids' finished chores and reward requests show up here.")
            }
            ForEach(pending.prefix(4)) { completion in
                let kid = members.first { $0.id == completion.memberID }
                let chore = chores.first { $0.id == completion.choreID }
                approvalRow(
                    who: kid,
                    title: "\(kid?.name ?? "Someone") finished \(chore?.title ?? "a chore")",
                    detail: "+\(completion.points) \(PointWords.current().plural)" + (completion.photoData == nil ? "" : " · photo") + " · " + completion.completedAt.formatted(date: .omitted, time: .shortened),
                    no: "Send Back",
                    onYes: { Family.approve(completion, in: context) },
                    onNo: { Family.sendBack(completion, in: context) }
                )
            }
            ForEach(requests.prefix(3)) { request in
                let kid = members.first { $0.id == request.memberID }
                let reward = rewards.first { $0.id == request.rewardID }
                approvalRow(
                    who: kid,
                    title: "\(kid?.name ?? "Someone") wants \(reward?.name ?? "a reward")",
                    detail: "\(request.cost) \(PointWords.current().plural)",
                    no: "Decline",
                    onYes: { Family.approve(request, in: context) },
                    onNo: { Family.decline(request, in: context) }
                )
            }
            if waiting > 0 {
                Spacer(minLength: 4)
                if session.isUnlocked {
                    Label("Unlocked until you walk away", systemImage: "lock.open.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else if ParentPIN.isSet {
                    VStack(spacing: 8) {
                        ParentPINPad(title: "Enter your PIN to approve", tint: color, keySize: 64) {
                            withAnimation(.snappy) { session.unlock() }
                        }
                        Text("Your face shows these. It never approves them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 18))
                } else {
                    Text("Set a parent PIN in Profile › Family Board to approve from the wall.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func approvalRow(who: Member?, title: String, detail: String, no: String, onYes: @escaping () -> Void, onNo: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let who {
                    MemberAvatar(who, size: 34)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if session.isUnlocked {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { onYes() }
                    } label: {
                        Text("Approve")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(.white)
                            .background(Self.green, in: Capsule())
                    }
                    Button {
                        withAnimation(.snappy) { onNo() }
                    } label: {
                        Text(no)
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(Color.primary)
                            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
    }

    // MARK: Kids

    private func kidsCard(_ family: FamilySnapshot) -> some View {
        let kids = members.filter { $0.isKid && !$0.isArchived }
        let done = kids.reduce(0) { $0 + family.progress(for: $1).done }
        let total = kids.reduce(0) { $0 + family.progress(for: $1).total }
        return card(title: "The kids today", symbol: "figure.2.and.child.holdinghands", tint: Color(hex: 0xAF52DE), trailing: total == 0 ? nil : "\(done) of \(total) jobs done") {
            if kids.isEmpty {
                emptyState(symbol: "person.3.fill", tint: Color(hex: 0xAF52DE), title: "No kids yet", message: "Add kids in Household to see their day here.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 12)], spacing: 16) {
                    ForEach(kids) { kid in
                        kidProgress(kid, family: family)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func kidProgress(_ kid: Member, family: FamilySnapshot) -> some View {
        let progress = family.progress(for: kid)
        let fraction = progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
        let waiting = pending.filter { $0.memberID == kid.id }.count
        let allDone = progress.total > 0 && progress.done == progress.total
        return VStack(spacing: 8) {
            ZStack {
                Circle().stroke(kid.color.color.opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(kid.color.color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                MemberAvatar(kid, size: 64)
                if allDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Self.green, in: Circle())
                        .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
                        .offset(x: 28, y: 28)
                } else if waiting > 0 {
                    Text(waiting.formatted())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Color(hex: 0xFF9F0A), in: Circle())
                        .overlay(Circle().strokeBorder(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
                        .offset(x: 28, y: -28)
                }
            }
            .frame(width: 80, height: 80)
            Text(kid.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(progress.total == 0 ? "No jobs today" : (allDone ? "All done" : "\(progress.done) of \(progress.total)"))
                .font(.caption)
                .foregroundStyle(allDone ? Self.green : .secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Home, dinner, the week

    /// Locks, garage and thermostat from Apple Home, working: lock up or close in one tap,
    /// unlock or open with the parent PIN, step the thermostat. Anything open in orange. All
    /// Home Controls opens the whole Control screen, after the parent PIN.
    private var homeStatusCard: some View {
        let items = HomeBridge.shared.statusItems
        let hasDoors = items.contains { $0.symbol != "thermometer.medium" }
        let secure = hasDoors && !items.contains { $0.needsAttention }
        return card(title: "Home", symbol: "house.fill", tint: Color(hex: 0x30B0C7), trailing: secure ? "All secure" : nil) {
            KioskHomeControls()
            Button(action: openAllControls) {
                HStack(spacing: 10) {
                    // The icon in the text's color (see AGENT.md › App color).
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("All Home Controls")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 6)
                    if !session.isUnlocked {
                        Image(systemName: "key.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityHint(session.isUnlocked ? "Opens every light, lock and device" : "Asks for the parent PIN, then opens every light, lock and device")
        }
        .sheet(item: $homeSheet) { sheet in
            switch sheet {
            case .pin:
                NavigationStack {
                    VStack(spacing: 16) {
                        if ParentPIN.isSet {
                            ParentPINPad(title: "Enter the parent PIN for all home controls", tint: Color(hex: 0x30B0C7)) {
                                session.unlock()
                                homeSheet = .controls
                            }
                        } else {
                            ContentUnavailableView(
                                "Set a Parent PIN First",
                                systemImage: "key.fill",
                                description: Text("Every home control, unlocking doors included, takes the parent PIN on the wall. Set one in Profile › Family Board.")
                            )
                        }
                    }
                    .padding(24)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            SheetCancelButton { homeSheet = nil }
                        }
                    }
                }
                .presentationDetents([.large])
            case .controls:
                NavigationStack {
                    ControlView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                SheetDoneButton { homeSheet = nil }
                            }
                        }
                }
                // Using the controls counts as using the wall, so it doesn't idle away.
                .simultaneousGesture(TapGesture().onEnded { session.touched() })
                .presentationSizing(.page)
            }
        }
    }

    /// Straight in when this visit is already unlocked; the parent PIN first otherwise.
    private func openAllControls() {
        session.touched()
        homeSheet = session.isUnlocked ? .controls : .pin
    }

    private var homeCareCard: some View {
        let upcoming = Array(homeTasks.prefix(4))
        return card(title: "Home care", symbol: "wrench.and.screwdriver.fill", tint: Brand.waiting, trailing: nil) {
            if upcoming.isEmpty {
                emptyState(symbol: "house.fill", tint: Color(hex: 0x30B0C7), title: "Nothing coming up", message: "Filters, detectors and the rest show here when they're due.")
            }
            ForEach(upcoming) { task in
                let late = Calendar.current.startOfDay(for: task.nextDue) < Calendar.current.startOfDay(for: .now)
                HStack(spacing: 10) {
                    Image(systemName: task.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(late ? Brand.late : Brand.waiting)
                        .frame(width: 32, height: 32)
                        .background((late ? Brand.late : Brand.waiting).opacity(0.14), in: Circle())
                    Text(task.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(late ? "Late" : task.nextDue.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(late ? Brand.late : .secondary)
                }
            }
        }
    }

    /// Tonight's dinner from BigTable, with its photo.
    private func dinnerCard(_ dinner: HearthMealPlan.Meal) -> some View {
        ZStack(alignment: .bottomLeading) {
            // The photo fills whatever height the row has; it never sets it.
            Color.clear
                .overlay {
                    if let url = dinner.artworkURL {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            LinearGradient(colors: [Color(hex: 0xE8650F), Color(hex: 0xC2185B)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                    } else {
                        LinearGradient(colors: [Color(hex: 0xE8650F), Color(hex: 0xC2185B)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Label(dinner.isDineOut ? "EATING OUT TONIGHT" : "DINNER TONIGHT", systemImage: dinner.symbol)
                    .font(.caption.weight(.heavy))
                    .tracking(0.5)
                    .opacity(0.9)
                Text(dinner.title)
                    .font(.title2.bold())
                    .lineLimit(2)
                if let note = dinner.notEating, !note.isEmpty {
                    Text("Not eating: " + note.formatted(.list(type: .and)))
                        .font(.footnote)
                        .opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
        }
        .frame(minHeight: 200)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 24))
    }

    /// The family's next few days, when there's no dinner plan.
    private var weekCard: some View {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        let coming = Array(CalendarMath.occurrences(of: events.map(\.record), from: start, through: end).sorted(by: CalendarMath.order).prefix(4))
        return card(title: "Coming up", symbol: "sparkles", tint: Color(hex: 0x5E5CE6), trailing: nil) {
            if coming.isEmpty {
                emptyState(symbol: "leaf.fill", tint: Self.green, title: "A quiet week ahead", message: "Nothing on the family calendar for the next few days.")
            }
            ForEach(coming) { occurrence in
                HStack(spacing: 12) {
                    VStack(spacing: 0) {
                        Text(occurrence.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 10, weight: .heavy))
                        Text(occurrence.start.formatted(.dateTime.day()))
                            .font(.system(size: 18, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(eventColor(occurrence.event), in: .rect(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(occurrence.event.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text((occurrence.event.isAllDay ? "All day" : occurrence.start.formatted(date: .omitted, time: .shortened)) + " · " + eventDetail(occurrence.event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: Pieces

    /// A card with an icon, a title, an optional count on the right, and its content.
    private func card<Content: View>(title: String, symbol: String, tint: Color, trailing: String?, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.15), in: .rect(cornerRadius: 9))
                Text(title)
                    .font(.title3.bold())
                Spacer(minLength: 6)
                if let trailing {
                    Text(trailing)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    /// What a card shows when there's nothing in it: a calm icon and a line or two.
    private func emptyState(symbol: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 64, height: 64)
                .background(
                    Circle().fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                )
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 150)
        .padding(.vertical, 6)
    }
}

/// What's up over a parent's wall screen from the Home card.
enum KioskHomeSheet: String, Identifiable {
    case pin, controls

    var id: String { rawValue }
}
