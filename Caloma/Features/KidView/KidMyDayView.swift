import SwiftData
import SwiftUI

/// Kid View › My Day: a big countdown to the next exciting thing, today as a timeline (the
/// next event pulses and has a packing list to tick off), and the rest of the week.
struct KidMyDayView: View {
    var kid: Member
    /// Jumps back to My Jobs.
    var onShowJobs: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived && $0.showInKidView }) private var events: [FamilyEvent]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var packings: [EventPacking]
    @Query private var chores: [Chore]
    @Query private var completions: [ChoreCompletion]
    @Query private var points: [PointEntry]

    private var color: Color { kid.color.color }

    private var mine: [EventRecord] {
        events.map(\.record).filter { $0.includes(kid.id) }
    }

    var body: some View {
        let mine = mine
        let today = CalendarMath.occurrences(of: mine, on: .now)
        let family = FamilySnapshot(members: members, chores: chores, completions: completions, points: points)
        let jobs = family.items(for: kid).filter { !$0.chore.upForGrabs || $0.memberID == kid.id }
        let jobsLeft = jobs.filter { $0.status == .open }.count
        VStack(alignment: .leading, spacing: 18) {
            if let countdown = CalendarMath.nextCountdown(mine, for: kid.id) {
                CountdownHero(occurrence: countdown, reduceMotion: reduceMotion)
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Spacer()
                Text(Date.now.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            if today.isEmpty {
                Text("Nothing on the calendar today.")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 26))
            } else {
                TimelineView(.everyMinute) { context in
                    let next = today.first { $0.end > context.date && !$0.event.isAllDay }?.id
                    VStack(spacing: 12) {
                        ForEach(today) { occurrence in
                            KidEventStep(
                                occurrence: occurrence,
                                kid: kid,
                                driver: members.first { $0.id == occurrence.event.driverID },
                                isPast: !occurrence.event.isAllDay && occurrence.end <= context.date,
                                isNext: occurrence.id == next,
                                packed: packed(for: occurrence),
                                reduceMotion: reduceMotion
                            ) { item in
                                Family.togglePacked(item, event: occurrence.event.id, kid: kid.id, day: occurrence.start, in: self.context)
                            }
                        }
                    }
                }
            }

            if !jobs.isEmpty {
                Button(action: onShowJobs) {
                    HStack(spacing: 14) {
                        Image(systemName: jobsLeft == 0 ? "checkmark.seal.fill" : "checklist")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(jobsLeft == 0 ? Color(hex: 0x1E9E6A) : color)
                            .frame(width: 50, height: 50)
                            .background((jobsLeft == 0 ? Color(hex: 0x1E9E6A) : color).opacity(0.15), in: .rect(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(jobsLeft == 0 ? "All your jobs are done!" : (jobsLeft == 1 ? "1 job left today" : "\(jobsLeft) jobs left today"))
                                .font(.system(size: 19, weight: .heavy, design: .rounded))
                            Text("Go to My Jobs")
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                }
                .buttonStyle(KidPressStyle())
            }

            let week = upcoming(mine)
            if !week.isEmpty {
                Text("This Week")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 4)
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(week) { occurrence in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(occurrence.start.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                                    .foregroundStyle(color)
                                Text(occurrence.event.title)
                                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                                    .lineLimit(2)
                                Text(occurrence.event.isAllDay ? "All day" : occurrence.start.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 150, alignment: .leading)
                            .padding(14)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                        }
                    }
                    .padding(.horizontal, sizeClass == .compact ? 16 : 28)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, sizeClass == .compact ? -16 : -28)
            }
        }
    }

    /// The next six days: the first thing each day.
    private func upcoming(_ events: [EventRecord]) -> [EventOccurrence] {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)),
              let end = calendar.date(byAdding: .day, value: 5, to: tomorrow) else { return [] }
        let all = CalendarMath.occurrences(of: events, from: tomorrow, through: end)
        var seen = Set<String>()
        return all.filter { seen.insert(CalendarMath.dayKey($0.start)).inserted }
    }

    private func packed(for occurrence: EventOccurrence) -> Set<String> {
        packings.first {
            $0.eventID == occurrence.event.id && $0.memberID == kid.id && Calendar.current.isDate($0.day, inSameDayAs: occurrence.start)
        }?.packed ?? []
    }
}

/// "3 sleeps until Movie Night!" with a moon for each sleep, floating.
private struct CountdownHero: View {
    var occurrence: EventOccurrence
    var reduceMotion: Bool
    @State private var float = false

    var body: some View {
        let sleeps = CalendarMath.sleeps(from: .now, until: occurrence.start)
        VStack(alignment: .leading, spacing: 12) {
            Text("COMING UP")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .opacity(0.85)
            if sleeps == 0 {
                Text("Today is \(occurrence.event.title)!")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(sleeps.formatted())
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("\(sleeps == 1 ? "sleep" : "sleeps") until\n\(occurrence.event.title)!")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .lineLimit(3)
                }
                HStack(spacing: 10) {
                    ForEach(0..<min(sleeps, 7), id: \.self) { index in
                        Image(systemName: "moon.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Color(hex: 0xFFD60A))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.16), in: Circle())
                            .offset(y: float && !reduceMotion ? -5 : 0)
                            .rotationEffect(.degrees(float && !reduceMotion ? 6 : -6))
                            .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(Double(index) * 0.15), value: float)
                    }
                    if sleeps > 7 {
                        Text("+\(sleeps - 7)")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                    }
                    Image(systemName: "sparkles")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color(hex: 0x2A1E78))
                        .frame(width: 42, height: 42)
                        .background(Color(hex: 0xFFD60A), in: Circle())
                }
            }
            Text(occurrence.start.formatted(.dateTime.weekday(.wide)) + (occurrence.event.isAllDay ? "" : " at " + occurrence.start.formatted(date: .omitted, time: .shortened)))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .opacity(0.95)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(LinearGradient(colors: [Color(hex: 0x5E5CE6), Color(hex: 0x2A1E78)], startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 28))
        .onAppear { float = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sleeps == 0 ? "Today is \(occurrence.event.title)" : "\(sleeps) sleeps until \(occurrence.event.title)")
    }
}

/// One stop on today's timeline. The next one is outlined and pulsing, with its packing list.
private struct KidEventStep: View {
    var occurrence: EventOccurrence
    var kid: Member
    var driver: Member?
    var isPast: Bool
    var isNext: Bool
    var packed: Set<String>
    var reduceMotion: Bool
    var onPack: (String) -> Void
    @State private var pulse = false

    private var color: Color { kid.color.color }

    var body: some View {
        let event = occurrence.event
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                Circle()
                    .fill(isPast ? Color(.systemGray3) : (isNext ? color : Color(.secondarySystemGroupedBackground)))
                    .overlay(Circle().strokeBorder(isNext || isPast ? Color.clear : color, lineWidth: 3))
                    .frame(width: 18, height: 18)
                    .background {
                        if isNext && !reduceMotion {
                            Circle()
                                .stroke(color.opacity(0.5), lineWidth: 3)
                                .scaleEffect(pulse ? 2.2 : 1)
                                .opacity(pulse ? 0 : 1)
                                .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                        }
                    }
                Text(event.isAllDay ? "All day" : occurrence.start.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()))
                    .font(.system(size: event.isAllDay ? 13 : 17, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isPast ? .tertiary : .primary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 56)
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        if isNext {
                            Text("UP NEXT")
                                .font(.system(size: 12, weight: .heavy, design: .rounded))
                                .tracking(0.6)
                                .foregroundStyle(color)
                        }
                        Text(event.title)
                            .font(.system(size: 20, weight: .heavy, design: .rounded))
                            .strikethrough(isPast)
                        if let sub = subtitle {
                            Text(sub)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !event.bring.isEmpty && !isPast {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Pack your bag")
                                .font(.system(size: 15, weight: .heavy, design: .rounded))
                            Spacer()
                            if event.bring.allSatisfy(packed.contains) {
                                Label("All packed!", systemImage: "checkmark")
                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Color(hex: 0x1E9E6A))
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        ForEach(event.bring, id: \.self) { item in
                            let on = packed.contains(item)
                            Button {
                                withAnimation(.spring(duration: 0.3, bounce: 0.5)) { onPack(item) }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 28))
                                        .foregroundStyle(on ? Color(hex: 0x1E9E6A) : color)
                                        .contentTransition(.symbolEffect(.replace))
                                    Text(item)
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                        .strikethrough(on)
                                        .foregroundStyle(on ? .secondary : .primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .frame(minHeight: 48)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 16))
                            }
                            .buttonStyle(KidPressStyle())
                            .sensoryFeedback(.success, trigger: on)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .padding(.top, 12)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
            .overlay {
                if isNext { RoundedRectangle(cornerRadius: 24).strokeBorder(color, lineWidth: 3) }
            }
            .opacity(isPast ? 0.55 : 1)
        }
        .onAppear { pulse = true }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let driver { parts.append("\(driver.name) drives") }
        if !occurrence.event.location.isEmpty && parts.isEmpty { parts.append(occurrence.event.location) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
