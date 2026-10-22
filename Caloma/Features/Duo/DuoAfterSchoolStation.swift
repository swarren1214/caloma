import SwiftData
import SwiftUI

/// iPhone Duo, partly folded and set down like a laptop: "After-school station". Set it on the
/// counter after school. The upright half reads the afternoon (each kid's progress, what's
/// left on the calendar today, and tonight's dinner from BigTable with Hearth+); the flat half
/// is a grid of big chore tiles, two across, that kids tap as they finish. A tap is the kid's
/// own "I did it" (`Family.markDone`, waiting for an OK when the chore asks for one), exactly
/// as in Kid View.
struct DuoAfterSchoolStation: View {
    var family: FamilySnapshot

    var body: some View {
        HearthFoldOverlay {
            DuoStationTiles(family: family)
        } content: {
            DuoStationAfternoon(family: family)
        }
        .colorHeader("Home")
    }
}

/// The upright half: the afternoon at a glance.
private struct DuoStationAfternoon: View {
    var family: FamilySnapshot

    @Environment(\.openURL) private var openURL
    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    private var link: HearthLink { HearthLink.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeaderTitle("This Afternoon", subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                if !family.kids.isEmpty {
                    LazyVGrid(columns: HearthEvenColumns.flexible(min(max(family.kids.count, 1), 3), spacing: 10), spacing: 10) {
                        ForEach(family.kids) { kid in
                            KidTodayCard(kid: kid, family: family)
                        }
                    }
                }
                let later = laterToday
                if !later.isEmpty {
                    CardList(items: later, inset: 28) { occurrence in
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(for: occurrence))
                                .frame(width: 4, height: 30)
                            Text(occurrence.event.title)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(CalendarMath.timeLabel(occurrence))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .accessibilityElement(children: .combine)
                    }
                }
                if let dinner = link.dinner(on: .now) {
                    Button {
                        if let url = dinner.openURL { openURL(url) }
                    } label: {
                        HStack(spacing: 12) {
                            MealArtwork(meal: dinner, cornerRadius: 12)
                                .frame(width: 56, height: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DINNER TONIGHT")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                Text(dinner.title)
                                    .font(.headline)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Dinner tonight: \(dinner.title)")
                    .accessibilityHint("Opens in BigTable")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .refreshesFromICloud()
    }

    /// What's still to come today, up to four.
    private var laterToday: [EventOccurrence] {
        let now = Date.now
        return Array(
            CalendarMath.occurrences(of: events.map(\.record), on: now)
                .filter { $0.event.isAllDay || $0.end > now }
                .sorted(by: CalendarMath.order)
                .prefix(4)
        )
    }

    private func color(for occurrence: EventOccurrence) -> Color {
        guard !occurrence.event.isEveryone else { return Brand.defaultAccent }
        return members.first { occurrence.event.attendeeIDs.contains($0.id) }?.color.color ?? Brand.defaultAccent
    }
}

/// The flat half: every kid's chores for today as big tiles, two across.
private struct DuoStationTiles: View {
    var family: FamilySnapshot

    @Environment(\.modelContext) private var context
    @State private var photoFor: StationPhoto?
    @State private var celebration = 0

    private struct StationPhoto: Identifiable {
        var item: BoardItem
        var kidID: UUID
        var id: String { item.id }
    }

    private struct StationTile: Identifiable {
        var kid: Member
        var item: BoardItem
        var id: String { item.id }
    }

    /// Every kid's chores for today (claimed up-for-grabs included), what's left first.
    private var tiles: [StationTile] {
        var result: [StationTile] = []
        for kid in family.kids {
            for item in family.items(for: kid) where item.memberID == kid.id {
                result.append(StationTile(kid: kid, item: item))
            }
        }
        let open = result.filter { $0.item.status == .open }
        let done = result.filter { $0.item.status != .open }
        return open + done
    }

    var body: some View {
        let tiles = tiles
        ScrollView {
            if tiles.isEmpty {
                Text("No chores left today.")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: HearthEvenColumns.flexible(2, spacing: 12), spacing: 12) {
                    ForEach(tiles) { tile in
                        tileButton(tile.item, kid: tile.kid)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(.systemGroupedBackground))
        // Pull down to fetch the family's latest from iCloud (AGENT.md).
        .refreshesFromICloud()
        .sensoryFeedback(.success, trigger: celebration)
        .sheet(item: $photoFor) { request in
            CameraPicker { image in
                finish(request.item, kidID: request.kidID, photo: PhotoTools.jpeg(from: image))
            }
            .ignoresSafeArea()
        }
    }

    private func tileButton(_ item: BoardItem, kid: Member) -> some View {
        let color = kid.color.color
        let open = item.status == .open
        return Button {
            guard open else { return }
            if item.chore.requiresPhoto {
                photoFor = StationPhoto(item: item, kidID: kid.id)
            } else {
                finish(item, kidID: kid.id, photo: nil)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: item.chore.symbol)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(open ? color : Color.secondary)
                    Spacer()
                    ChoreCheck(status: item.status, color: color, size: 32)
                }
                Text(item.chore.title)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    MemberAvatar(kid, size: 24)
                    Text(kid.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.status == .pending {
                        TagLabel(text: "Waiting for OK", color: Brand.waiting)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(open ? color.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
            .contentShape(Rectangle())
        }
        .buttonStyle(KidPressStyle())
        .disabled(!open)
        .accessibilityLabel(open ? "\(kid.name): \(item.chore.title)" : "\(kid.name): \(item.chore.title), done")
        .accessibilityHint(open ? "Marks it done" : "")
    }

    private func finish(_ item: BoardItem, kidID: UUID, photo: Data?) {
        withAnimation(.spring(duration: 0.45, bounce: 0.4)) {
            Family.markDone(item, by: kidID, byParent: false, photo: photo, in: context)
            celebration += 1
        }
    }
}
