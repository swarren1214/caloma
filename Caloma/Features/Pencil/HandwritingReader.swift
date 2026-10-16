import Foundation
import PencilKit
import UIKit
import Vision

/// Reads what someone wrote with the Pencil, on the device, with Vision.
enum HandwritingReader {
    /// The words written, top line first, or nil when nothing could be read.
    static func text(in drawing: PKDrawing, separator: String = " ") async -> String? {
        guard drawing.hasInk, let image = drawing.paperImage(scale: 3, margin: 32)?.cgImage else { return nil }
        return await read(image, separator: separator)
    }

    nonisolated static func read(_ image: CGImage, separator: String) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        // Top to bottom (Vision's origin is the lower left), then left to right on a line.
        let lines = observations.sorted { a, b in
            let ay = a.boundingBox.origin.y + a.boundingBox.height / 2
            let by = b.boundingBox.origin.y + b.boundingBox.height / 2
            if abs(ay - by) > 0.05 { return ay > by }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }
        .compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Turns a handwritten "when" into dates, with the rules people use without thinking on a
/// family calendar: "4:30" with no am or pm is the afternoon, a weekday is the next one, a bare
/// "Sat 10" means 10 in the morning, and "10–12" is a range.
nonisolated enum EventTimeParser {
    nonisolated struct Result: Equatable {
        var start: Date
        var end: Date
        var isAllDay: Bool
    }

    /// `day` is the day to use when none is written (the day the sheet was opened for).
    static func parse(_ raw: String, day: Date, now: Date = .now, calendar: Calendar = .current) -> Result? {
        var text = normalize(raw)
        let today = calendar.startOfDay(for: now)

        // The day.
        var date: Date?
        if let found = explicitDate(in: &text, today: today, calendar: calendar) {
            date = found
        } else if let found = relativeDay(in: text, today: today, calendar: calendar) {
            date = found
        }

        // The time, or a range of times. "Tonight 8" is the evening.
        var times = timeRange(in: text)
        if text.contains("tonight"), let found = times, found.start < 12 * 60 {
            times = (found.start + 12 * 60, found.end.map { min($0 + 12 * 60, 24 * 60 - 1) })
        }
        guard date != nil || times != nil else { return nil }
        let base = calendar.startOfDay(for: date ?? day)

        guard let times else {
            let end = calendar.date(byAdding: .day, value: 1, to: base) ?? base
            return Result(start: base, end: end, isAllDay: true)
        }
        // By clock time, so the day the clocks change still lands on the hour written.
        let at = { (minutes: Int) -> Date? in
            calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: base)
        }
        let start = at(times.start) ?? base
        let endMinutes = min(times.end ?? (times.start + 60), 24 * 60 - 1)
        let end = at(endMinutes) ?? start.addingTimeInterval(3600)
        return Result(start: start, end: max(end, start.addingTimeInterval(15 * 60)), isAllDay: false)
    }

    // MARK: Cleaning up what Vision read

    static func normalize(_ raw: String) -> String {
        var text = " " + raw.lowercased() + " "
        // Common misreads in handwritten times: "4:3O", "l0:30", "4.30".
        text = text.replacingOccurrences(of: #"(?<=[\d:])o"#, with: "0", options: .regularExpression)
        text = text.replacingOccurrences(of: #"o(?=\d)"#, with: "0", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\s)[li|](?=\d)"#, with: "1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\d)[li|](?=\d)"#, with: "1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<=\d)\.(?=\d\d\b)"#, with: ":", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\ba\.m\.?"#, with: "am", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bp\.m\.?"#, with: "pm", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\b(tmrw|tmr|tomm?orr?ow)\b"#, with: "tomorrow", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[–—]"#, with: "-", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bnoon\b"#, with: "12pm", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\bmidnight\b"#, with: "12am", options: .regularExpression)
        return text
    }

    // MARK: Days

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "10/20" or "Oct 20": that day this year (next year if it's well past). The date is taken
    /// out of the text so its numbers aren't read as a time.
    private static func explicitDate(in text: inout String, today: Date, calendar: Calendar) -> Date? {
        var month: Int?
        var dayOfMonth: Int?
        if let match = text.firstMatch(of: #/\b(\d{1,2})\/(\d{1,2})(?:\/\d{2,4})?\b/#) {
            month = Int(match.1)
            dayOfMonth = Int(match.2)
            text.removeSubrange(match.range)
        } else if let match = text.firstMatch(of: #/\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b/#) {
            month = months.firstIndex(of: String(match.1)).map { $0 + 1 }
            dayOfMonth = Int(match.2)
            text.removeSubrange(match.range)
        }
        guard let month, let dayOfMonth, (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        let year = calendar.component(.year, from: today)
        guard var date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) else { return nil }
        if date < calendar.date(byAdding: .day, value: -30, to: today) ?? today {
            date = calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    /// Whole weekday words only, so "month" isn't Monday and "wedding" isn't Wednesday.
    private static let weekdays: [(String, Int)] = [
        ("sun(day)?", 1), ("mon(day)?", 2), ("tue(s|sday)?", 3), ("wed(s|nesday)?", 4),
        ("thu(r|rs|rsday)?", 5), ("fri(day)?", 6), ("sat(urday)?", 7),
    ]

    /// "today", "tomorrow" or a weekday (the next one; today if it's today).
    private static func relativeDay(in text: String, today: Date, calendar: Calendar) -> Date? {
        if text.contains("tomorrow") { return calendar.date(byAdding: .day, value: 1, to: today) }
        if text.contains("today") || text.contains("tonight") { return today }
        for (pattern, weekday) in weekdays where text.range(of: #"\b"# + pattern + #"\b"#, options: .regularExpression) != nil {
            let current = calendar.component(.weekday, from: today)
            let ahead = (weekday - current + 7) % 7
            return calendar.date(byAdding: .day, value: ahead, to: today)
        }
        return nil
    }

    // MARK: Times

    /// Minutes after midnight for the start, and the end when a range was written.
    static func timeRange(in text: String) -> (start: Int, end: Int?)? {
        let time = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a|p)?"#
        if let range = try? Regex(#"\b"# + time + #"\s*(?:-|to)\s*"# + time + #"\b"#),
           let match = text.firstMatch(of: range) {
            let parts = match.output.map { $0.substring.map(String.init) }
            guard parts.count >= 7, let startHour = parts[1].flatMap(Int.init), let endHour = parts[4].flatMap(Int.init) else { return nil }
            let startMinute = parts[2].flatMap(Int.init) ?? 0
            let endMinute = parts[5].flatMap(Int.init) ?? 0
            let startMeridiem = parts[3]
            let endMeridiem = parts[6]
            guard valid(startHour, startMinute), valid(endHour, endMinute) else { return nil }
            var start: Int
            var end: Int
            if let endMeridiem {
                end = minutes(endHour, endMinute, endMeridiem)
                if let startMeridiem {
                    start = minutes(startHour, startMinute, startMeridiem)
                } else {
                    // "10-12pm" is 10 in the morning; "4-6pm" is 4 in the afternoon.
                    start = minutes(startHour, startMinute, endMeridiem)
                    if start > end { start = minutes(startHour, startMinute, endMeridiem.hasPrefix("p") ? "am" : "pm") }
                }
            } else {
                start = startMeridiem.map { minutes(startHour, startMinute, $0) } ?? guess(startHour, startMinute)
                // The end is the first time with that hour after the start.
                end = minutes(endHour % 12, endMinute, "am")
                while end <= start { end += 12 * 60 }
            }
            if end <= start { end += 24 * 60 }
            return (start, min(end, 24 * 60 - 1))
        }

        // One time. "4:30", "4pm", "430", or a bare hour.
        if let match = text.firstMatch(of: #/\b(\d{1,2}):(\d{2})\s*(am|pm|a|p)?\b/#) {
            let hour = Int(match.1) ?? 0
            let minute = Int(match.2) ?? 0
            guard valid(hour, minute) else { return nil }
            return (match.3.map { minutes(hour, minute, String($0)) } ?? guess(hour, minute), nil)
        }
        if let match = text.firstMatch(of: #/\b(\d{1,2})\s*(am|pm|a|p)\b/#) {
            let hour = Int(match.1) ?? 0
            guard valid(hour, 0) else { return nil }
            return (minutes(hour, 0, String(match.2)), nil)
        }
        // "430" or "1015" with the colon missed.
        if let match = text.firstMatch(of: #/\b(\d{1,2})(\d{2})\s*(am|pm|a|p)?\b/#) {
            let hour = Int(match.1) ?? 0
            let minute = Int(match.2) ?? 0
            guard valid(hour, minute), (1...12).contains(hour) else { return nil }
            return (match.3.map { minutes(hour, minute, String($0)) } ?? guess(hour, minute), nil)
        }
        if let match = text.firstMatch(of: #/\b(\d{1,2})\b/#) {
            let hour = Int(match.1) ?? 0
            guard (1...12).contains(hour) else { return nil }
            return (guess(hour, 0), nil)
        }
        return nil
    }

    private static func valid(_ hour: Int, _ minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    private static func minutes(_ hour: Int, _ minute: Int, _ meridiem: String) -> Int {
        guard hour <= 12 else { return hour * 60 + minute }
        let pm = meridiem.hasPrefix("p")
        let h = hour % 12 + (pm ? 12 : 0)
        return h * 60 + minute
    }

    /// No am or pm written: 1 to 7 is the afternoon or evening, 8 to 11 the morning, 12 noon.
    private static func guess(_ hour: Int, _ minute: Int) -> Int {
        if hour > 12 || hour == 0 { return hour * 60 + minute }
        if hour == 12 { return 12 * 60 + minute }
        return (hour <= 7 ? hour + 12 : hour) * 60 + minute
    }
}
