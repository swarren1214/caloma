import SwiftData
import SwiftUI

/// The Family Board's screensaver: the family's photos (or Caloma's wallpapers) crossfading
/// with a slow zoom, the clock, and cards that take turns: what's next, dinner, a countdown,
/// this week's stars and whether the house is locked up. Nothing on it can be pressed; a tap
/// anywhere, someone walking up, or the doorbell wakes the wall. From 10 PM to 6 AM it can be
/// just a dim clock instead.
struct KioskScreensaverView: View {
    /// A tap anywhere.
    var onWake: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.kioskScreensaverStyle) private var styleRaw = ScreensaverStyle.corner.rawValue
    @AppStorage(SettingsKey.kioskScreensaverNight) private var nightClock = true
    @AppStorage(SettingsKey.kioskScreensaverPhotoSeconds) private var photoSeconds = 15
    @AppStorage(SettingsKey.kioskScreensaverZoom) private var slowZoom = true
    @AppStorage(SettingsKey.kioskScreensaverWidgets) private var widgetsRaw = ScreensaverWidget.defaultOrder

    @Query(filter: #Predicate<FamilyEvent> { !$0.isArchived }) private var events: [FamilyEvent]
    @Query(sort: \Member.sortOrder) private var members: [Member]
    @Query private var points: [PointEntry]

    @State private var shown: ShownSlide?
    @State private var cardIndex = 0
    /// Rebuilt once a minute, not on every frame.
    @State private var cards: [ScreensaverCard] = []
    private let presence = KioskPresence.shared

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
        let start = CalendarMath.week(containing: .now).first ?? Calendar.current.startOfDay(for: .now)
        _points = Query(filter: #Predicate<PointEntry> { $0.date >= start && $0.points > 0 })
    }

    private var style: ScreensaverStyle { ScreensaverStyle(rawValue: styleRaw) ?? .corner }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let night = nightClock && ScreensaverPrefs.isNight(context.date)
            ZStack {
                Color.black
                if night {
                    NightClock(date: context.date, tomorrow: firstThingTomorrow(after: context.date))
                        .transition(.opacity)
                } else {
                    photos
                    // Darker at the top and bottom, so the white type always reads.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.45), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.6),
                        .init(color: .black.opacity(0.5), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
                    overlay(date: context.date)
                }
            }
            .animation(.easeInOut(duration: 1.2), value: night)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .contentShape(.rect)
        .onTapGesture(perform: onWake)
        // One element for VoiceOver, hiding the calendar underneath: double-tap wakes it.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits([.isButton, .isModal])
        .accessibilityLabel("Screensaver")
        .accessibilityHint("Double-tap to wake the Family Board")
        .accessibilityAction { onWake() }
        .task {
            while !Task.isCancelled {
                cards = buildCards(now: .now)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    // MARK: Photos

    private struct SlideshowKey: Equatable {
        var size: CGSize
        var paused: Bool
    }

    private struct ShownSlide: Identifiable {
        let id = UUID()
        let image: UIImage
        /// Where the slow zoom drifts toward.
        let anchor: UnitPoint
    }

    private var photos: some View {
        GeometryReader { proxy in
            ZStack {
                if let shown {
                    KenBurns(image: shown.image, anchor: shown.anchor, seconds: Double(photoSeconds) + 2, moves: slowZoom && !reduceMotion)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .id(shown.id)
                        .transition(.opacity)
                }
            }
            // Paused while the screen is dimmed: nobody's looking.
            .task(id: SlideshowKey(size: proxy.size, paused: presence.isDimmed)) {
                guard !presence.isDimmed else { return }
                await slideshow(size: proxy.size)
            }
        }
        .accessibilityHidden(true)
    }

    /// Shows each picture for its time, loading the next one while this one shows.
    private func slideshow(size: CGSize) async {
        guard size.width > 0 else { return }
        let library = ScreensaverLibrary.shared
        let slides = await library.slides()
        guard !slides.isEmpty else { return }
        let anchors: [UnitPoint] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing, .center]
        let scale = displayScale
        let seconds = max(photoSeconds, 4)
        var index = 0
        var next = await library.image(for: slides[0], size: size, scale: scale)
        while !Task.isCancelled {
            if let image = next {
                withAnimation(.easeInOut(duration: 1.6)) {
                    shown = ShownSlide(image: image, anchor: anchors[index % anchors.count])
                }
            }
            index += 1
            let upcoming = slides[index % slides.count]
            async let loaded = library.image(for: upcoming, size: size, scale: scale)
            try? await Task.sleep(for: .seconds(seconds))
            next = await loaded
        }
    }

    // MARK: Clock and cards

    private func overlay(date: Date) -> some View {
        ZStack {
            switch style {
            case .corner:
                VStack(alignment: .leading, spacing: 6) {
                    ScreensaverClock(date: date, size: 112, weight: .ultraLight)
                    Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .font(.system(size: 26, weight: .semibold))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 56)
                .padding(.top, 48)
                .accessibilityElement(children: .combine)

                if !cards.isEmpty {
                    CornerCard(cards: cards, index: cardIndex)
                        .frame(width: 400)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(44)
                }
            case .panel:
                SidePanel(date: date, cards: cards, index: cardIndex)
                    .frame(width: 400)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .task(id: cards.count) {
            // The cards take turns every 8 seconds, when there's more than one turn to take.
            let turns = style == .panel ? 3 : 1
            guard cards.count > turns else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.6)) { cardIndex += 1 }
            }
        }
    }

    private var people: [Member] { members.filter { !$0.isArchived } }

    private func name(_ id: UUID?) -> String? {
        people.first { $0.id == id }?.name
    }

    /// The cards that have something to say right now, in the order chosen in Settings.
    private func buildCards(now: Date) -> [ScreensaverCard] {
        let records = events.map(\.record)
        var cards: [ScreensaverCard] = []
        for setting in ScreensaverWidget.decode(widgetsRaw) where setting.isOn {
            let widget = setting.widget
            switch widget {
            case .upNext:
                if let next = nextEvent(records, now: now) {
                    let who = next.event.isEveryone ? "Everyone" : next.event.attendeeIDs.compactMap { name($0) }.formatted(.list(type: .and))
                    var parts = [who, timeText(next, now: now)]
                    if let driver = name(next.event.driverID) { parts.append("\(driver) drives") }
                    cards.append(ScreensaverCard(widget: widget, label: "UP NEXT", title: next.event.title, detail: parts.filter { !$0.isEmpty }.joined(separator: " · ")))
                }
            case .dinner:
                if let dinner = HearthLink.shared.dinner(on: now), Calendar.current.component(.hour, from: now) < 20 {
                    let detail = dinner.kind == "dineOut" ? (dinner.placeName.map { "Out at \($0)" } ?? "Eating out") : "From BigTable"
                    cards.append(ScreensaverCard(widget: widget, label: "DINNER TONIGHT", title: dinner.title, detail: detail))
                }
            case .countdown:
                if let next = CalendarMath.nextCountdown(records, now: now) {
                    let sleeps = CalendarMath.sleeps(from: now, until: next.start)
                    let title = sleeps <= 0 ? "Today!" : (sleeps == 1 ? "1 sleep" : "\(sleeps) sleeps")
                    cards.append(ScreensaverCard(widget: widget, label: "COUNTDOWN", title: title, detail: sleeps <= 0 ? next.event.title : "until \(next.event.title)", big: true))
                }
            case .stars:
                let kids = people.filter(\.isKid)
                let totals = kids.map { kid in (kid, points.filter { $0.memberID == kid.id }.reduce(0) { $0 + $1.points }) }
                if totals.contains(where: { $0.1 > 0 }) {
                    let top = max(totals.map(\.1).max() ?? 1, 1)
                    let bars = totals.prefix(4).map { kid, total in
                        ScreensaverCard.Bar(id: kid.id, name: kid.name, value: total, fraction: Double(total) / Double(top), color: kid.color.color)
                    }
                    cards.append(ScreensaverCard(widget: widget, label: "\(PointWords.current().plural.uppercased()) THIS WEEK", title: "", detail: "", bars: Array(bars)))
                }
            case .home:
                // Before Apple Home has reported in, a lock reads "Unknown": leave those out.
                let items = HomeBridge.shared.statusItems.filter { $0.symbol != "thermometer.medium" && $0.state != "Unknown" }
                if !items.isEmpty {
                    let open = items.filter(\.needsAttention)
                    let title = open.first.map { "\($0.name) is \($0.state.lowercased())" } ?? "All locked up"
                    let detail = items.prefix(3).map { "\($0.name) \($0.state.lowercased())" }.joined(separator: " · ")
                    cards.append(ScreensaverCard(widget: widget, label: "HOME", title: title, detail: detail, alert: !open.isEmpty))
                }
            }
        }
        return cards
    }

    /// The next thing that starts, today or tomorrow.
    private func nextEvent(_ records: [EventRecord], now: Date) -> EventOccurrence? {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return nil }
        let upcoming = CalendarMath.occurrences(of: records, from: calendar.startOfDay(for: now), through: end)
        let timed = upcoming.filter { !$0.event.isAllDay && $0.start > now }.sorted { $0.start < $1.start }
        if let first = timed.first { return first }
        return upcoming.filter { $0.event.isAllDay && $0.start > now }.sorted { $0.start < $1.start }.first
    }

    private func timeText(_ occurrence: EventOccurrence, now: Date) -> String {
        let calendar = Calendar.current
        let day: String
        if calendar.isDate(occurrence.start, inSameDayAs: now) {
            day = occurrence.event.isAllDay ? "Today" : ""
        } else if calendar.isDateInTomorrow(occurrence.start) {
            day = "Tomorrow"
        } else {
            day = occurrence.start.formatted(.dateTime.weekday(.wide))
        }
        if occurrence.event.isAllDay { return day }
        let time = occurrence.start.formatted(date: .omitted, time: .shortened)
        return day.isEmpty ? time : "\(day) \(time)"
    }

    /// For the night clock: the first thing on tomorrow's calendar.
    private func firstThingTomorrow(after now: Date) -> String? {
        let calendar = Calendar.current
        // After midnight, "tomorrow" is the morning that's coming.
        let morning = calendar.component(.hour, from: now) < 6 ? now : (calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let dayStart = calendar.startOfDay(for: morning)
        // Only things that start that morning or later, not last night's sleepover.
        let first = CalendarMath.occurrences(of: events.map(\.record), on: morning)
            .filter { !$0.event.isAllDay && $0.start >= dayStart && $0.start > now }
            .sorted { $0.start < $1.start }
            .first
        guard let first else { return nil }
        return "\(first.event.title) at \(first.start.formatted(date: .omitted, time: .shortened))"
    }
}

/// What one card says.
struct ScreensaverCard: Identifiable {
    struct Bar: Identifiable {
        let id: UUID
        let name: String
        let value: Int
        let fraction: Double
        let color: Color
    }

    let widget: ScreensaverWidget
    let label: String
    let title: String
    let detail: String
    var big = false
    var alert = false
    var bars: [Bar] = []

    var id: ScreensaverWidget { widget }
}

/// The photo, drifting slowly toward one corner while it shows.
private struct KenBurns: View {
    var image: UIImage
    var anchor: UnitPoint
    var seconds: Double
    var moves: Bool

    @State private var zoomed = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(zoomed ? 1.09 : 1.0, anchor: anchor)
            .onAppear {
                guard moves else { return }
                withAnimation(.linear(duration: seconds)) { zoomed = true }
            }
    }
}

/// One card at a time in the bottom corner, with dots for the rest.
private struct CornerCard: View {
    var cards: [ScreensaverCard]
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = cards[index % cards.count]
        VStack(spacing: 12) {
            ZStack {
                CardContent(card: current, titleSize: current.big ? 46 : 34)
                    .id(current.id)
                    .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
            .padding(.horizontal, 26)
            .background(.ultraThinMaterial.opacity(0.9), in: .rect(cornerRadius: 30))
            .background(Color.black.opacity(0.2), in: .rect(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.18)))
            if cards.count > 1 {
                HStack(spacing: 7) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { offset, _ in
                        Capsule()
                            .fill(.white.opacity(offset == index % cards.count ? 0.95 : 0.4))
                            .frame(width: offset == index % cards.count ? 18 : 7, height: 7)
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }
}

/// "10:50" big with a small "AM" beside it, like the Lock Screen, on one line: it shrinks to
/// fit a narrow column rather than wrapping.
private struct ScreensaverClock: View {
    var date: Date
    var size: CGFloat
    var weight: Font.Weight

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                .font(.system(size: size, weight: weight))
                .monospacedDigit()
                .contentTransition(.numericText())
            // Empty on a 24-hour clock.
            let period = date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))).filter { !$0.isNumber && !$0.isWhitespace }
            if !period.isEmpty {
                Text(period)
                    .font(.system(size: size * 0.3, weight: .medium))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
    }
}

/// A frosted column down the right: the clock and three cards.
private struct SidePanel: View {
    var date: Date
    var cards: [ScreensaverCard]
    var index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreensaverClock(date: date, size: 92, weight: .ultraLight)
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, -10)
            Rectangle().fill(.white.opacity(0.16)).frame(height: 1).padding(.vertical, 6)
            ForEach(visible) { card in
                CardContent(card: card, titleSize: 26)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 22))
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
        .padding(.vertical, 44)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial.opacity(0.92))
        .background(Color.black.opacity(0.25))
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.14)).frame(width: 1) }
    }

    /// Three at a time, moving along one card every turn.
    private var visible: [ScreensaverCard] {
        guard cards.count > 3 else { return cards }
        return (0..<3).map { cards[(index + $0) % cards.count] }
    }
}

private struct CardContent: View {
    var card: ScreensaverCard
    var titleSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(card.alert ? Brand.waiting : card.widget.tint).frame(width: 8, height: 8)
                Text(card.label)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.72))
            }
            if !card.title.isEmpty {
                Text(card.title)
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            if !card.detail.isEmpty {
                Text(card.detail)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(2)
            }
            if !card.bars.isEmpty {
                VStack(spacing: 7) {
                    ForEach(card.bars) { bar in
                        HStack(spacing: 10) {
                            Text(bar.name)
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 70, alignment: .leading)
                                .lineLimit(1)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.16))
                                    Capsule().fill(bar.color).frame(width: max(8, proxy.size.width * bar.fraction))
                                }
                            }
                            .frame(height: 8)
                            Text(bar.value.formatted())
                                .font(.system(size: 15, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
    }
}

/// Night: a dim, warm clock on black, and the first thing tomorrow. It drifts a little each
/// minute so nothing sits in one place all night.
private struct NightClock: View {
    var date: Date
    var tomorrow: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let minute = Calendar.current.component(.minute, from: date)
        let drift = CGSize(width: CGFloat((minute * 37) % 41 - 20), height: CGFloat((minute * 53) % 31 - 15))
        VStack(spacing: 14) {
            ScreensaverClock(date: date, size: 180, weight: .thin)
                .foregroundStyle(Color(hex: 0x8E6A4F))
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color(hex: 0x6E5340))
            if let tomorrow {
                Label("First thing tomorrow: \(tomorrow)", systemImage: "moon.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color(hex: 0x5A4434))
                    .padding(.top, 24)
            }
        }
        .offset(drift)
        .animation(reduceMotion ? nil : .easeInOut(duration: 2), value: minute)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
