import SwiftData
import SwiftUI

/// A parent's screen on the wall, for the moment they pass by: their tasks, their evening,
/// what's waiting on their OK (visible to them, actionable only with the PIN), how the kids
/// are doing, and home care coming due.
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

    @State private var picking = false

    private var color: Color { member.color.color }
    private var family: FamilySnapshot {
        FamilySnapshot(members: members, chores: chores, completions: completions, points: [])
    }

    var body: some View {
        let family = family
        let agenda = agenda
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(agenda: agenda)
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        HStack(alignment: .top, spacing: 16) {
                            tasksCard(family)
                            eveningCard(agenda)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            kidsCard(family)
                            if HomeBridge.shared.statusItems.isEmpty {
                                homeCareCard
                            } else {
                                homeStatusCard
                            }
                        }
                    }
                    approvalsCard
                        .frame(width: 316)
                }
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $picking) {
            WhoIsHerePicker(current: member.id)
        }
    }

    // MARK: Header

    private func header(agenda: [EventOccurrence]) -> some View {
        HStack(spacing: 18) {
            MemberAvatar(member, size: 74)
                .padding(5)
                .overlay(Circle().strokeBorder(color, lineWidth: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(kioskGreeting()), \(member.name)")
                    .font(.system(size: 36, weight: .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(summary(agenda: agenda))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if session.source == .face {
                HStack(spacing: 10) {
                    Circle().fill(Color(hex: 0x34C759)).frame(width: 8, height: 8)
                    Text("Recognized")
                        .foregroundStyle(.secondary)
                    Button("Not \(member.name)?") { picking = true }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .foregroundStyle(color)
                        .background(color.opacity(0.14), in: Capsule())
                        .buttonStyle(.plain)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 44)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
            }
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
        return parts.isEmpty ? "Nothing pressing right now." : parts.joined(separator: " ")
    }

    // MARK: Tasks

    private func tasksCard(_ family: FamilySnapshot) -> some View {
        let items = family.items(for: member)
        let due = dueHomeCare
        let left = items.filter { $0.status == .open }.count + due.count
        return card {
            HStack(alignment: .firstTextBaseline) {
                Text("Your tasks").font(.title3.bold())
                Text(left == 0 ? "All done" : "\(left) left today")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty && due.isEmpty {
                emptyLine("Nothing on your list today.")
            }
            ForEach(items) { item in
                taskRow(title: item.chore.title, detail: item.status.isDone ? "Done" : "Chore", tag: "Chore", tint: color, done: item.status.isDone, late: false) {
                    toggle(item)
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
                        Circle().fill(Color(hex: 0x1E9E6A))
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
        return card {
            Text(eveningTitle).font(.title3.bold())
            if agenda.isEmpty {
                emptyLine("Nothing else on the calendar this week.")
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
        return card {
            HStack {
                Text("Needs your OK").font(.title3.bold())
                Spacer()
                if waiting > 0 {
                    Text(waiting.formatted())
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 26, minHeight: 26)
                        .background(Color(hex: 0xFF9F0A), in: Capsule())
                }
            }
            if waiting == 0 {
                emptyLine("Nothing waiting. Nice.")
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
                    Text("Unlocked. Locks again when you walk away.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else if ParentPIN.isSet {
                    VStack(spacing: 8) {
                        ParentPINPad(title: "Enter your PIN to approve", tint: color, keySize: 52) {
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
                    Text("Set a parent PIN in Family › Kiosk Mode to approve from the wall.")
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
                            .background(Color(hex: 0x1E9E6A), in: Capsule())
                    }
                    Button {
                        withAnimation(.snappy) { onNo() }
                    } label: {
                        Text(no)
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .foregroundStyle(.primary)
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

    // MARK: Kids and home care

    private func kidsCard(_ family: FamilySnapshot) -> some View {
        let kids = members.filter { $0.isKid && !$0.isArchived }
        return card {
            Text("The kids today").font(.headline)
            HStack(spacing: 0) {
                ForEach(kids) { kid in
                    let progress = family.progress(for: kid)
                    let waiting = pending.filter { $0.memberID == kid.id }.count
                    VStack(spacing: 6) {
                        ZStack {
                            Circle().stroke(Color(.tertiarySystemFill), lineWidth: 7)
                            Circle()
                                .trim(from: 0, to: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total))
                                .stroke(kid.color.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(progress.done)/\(progress.total)")
                                .font(.subheadline.weight(.heavy))
                                .monospacedDigit()
                        }
                        .frame(width: 70, height: 70)
                        Text(kid.name).font(.subheadline.weight(.semibold))
                        Text(waiting > 0 ? "\(waiting) waiting on you" : (progress.total > 0 && progress.done == progress.total ? "All done" : " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 4)
        }
    }

    private var homeCareCard: some View {
        let upcoming = Array(homeTasks.prefix(4))
        return card {
            Text("Home care").font(.headline)
            if upcoming.isEmpty {
                emptyLine("Nothing coming up.")
            }
            ForEach(upcoming) { task in
                let late = Calendar.current.startOfDay(for: task.nextDue) < Calendar.current.startOfDay(for: .now)
                HStack(spacing: 10) {
                    Circle()
                        .fill(late ? Brand.late : Color(.systemGray3))
                        .frame(width: 9, height: 9)
                    Text(task.name)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(task.nextDue.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(late ? Brand.late : .secondary)
                }
                .font(.subheadline)
            }
        }
    }

    /// Locks, garage and thermostat from Apple Home; anything open or unlocked in orange.
    private var homeStatusCard: some View {
        card {
            Text("Home").font(.headline)
            ForEach(HomeBridge.shared.statusItems) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.subheadline)
                        .foregroundStyle(item.needsAttention ? Brand.waiting : .secondary)
                        .frame(width: 22)
                    Text(item.name)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.state)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.needsAttention ? Brand.waiting : .secondary)
                }
                .font(.subheadline)
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
    }
}
