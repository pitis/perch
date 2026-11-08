import Foundation

public struct ParsedTask: Equatable, Sendable {
    public var title = ""
    public var day: String?
    public var reminderAt: Date?
    public var deadline: String?
    public var priority = Priority.none
    public var project: String?
    public var repeatRule: RepeatRule?

    public var hasDetails: Bool {
        day != nil || reminderAt != nil || deadline != nil || priority != .none || project != nil || repeatRule != nil
    }

    /// "Tomorrow, 5:00 PM" for the composer's preview, using the Mac's own 12 or 24-hour setting.
    public func whenLabel(today: String, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let day else { return nil }
        let dayLabel = Day.label(day, today: today, calendar: calendar)
        guard let reminderAt else { return dayLabel }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        f.dateStyle = .none
        f.timeStyle = .short
        return "\(dayLabel), \(f.string(from: reminderAt))"
    }
}

/// Removes recognised phrases from the text one at a time; what's left is the title.
private struct Cutter {
    var text: String

    /// Cuts the first match and returns its capture groups (index 0 is the whole match).
    mutating func take(_ pattern: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let groups: [String?] = (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        text = ns.replacingCharacters(in: m.range, with: " ")
        return groups
    }

    mutating func rewrite(_ pattern: String, _ template: String) {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}

/// English task phrases: "call mom tomorrow at 5pm", "standup every weekday at 9:30 !high #work", "invoice by friday".
/// Numeric dates such as "12/25" are read in the order of the locale's short date format.
public enum NLParser {
    private static let fullDays = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
    private static let shortDays = ["sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7]
    private static let months = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12,
    ]
    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "a": 1, "an": 1,
    ]

    private static let fullDayAlt = "sunday|monday|tuesday|wednesday|thursday|friday|saturday"
    private static let shortDayAlt = "tues|tue|sun|mon|wed|thurs|thur|thu|fri|sat"
    private static let monthAlt = "january|february|march|april|may|june|july|august|september|october|november|december|sept|jan|feb|mar|apr|jun|jul|aug|sep|oct|nov|dec"
    private static let ordinal = "(?:st|nd|rd|th)?"
    private static func dayExpr(_ numeric: NumericDate) -> String {
        "today|tomorrow|tmrw|next week|next month|(?:next |this )?(?:\(fullDayAlt)|\(shortDayAlt))"
            + "|(?:\(monthAlt))\\.? \\d{1,2}\(ordinal)|\\d{1,2}\(ordinal) (?:of )?(?:\(monthAlt))|\(numeric.pattern)"
    }

    /// `locale` decides whether "3/4" is March 4 or April 3; `.current` follows the Mac's date format setting.
    public static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ParsedTask {
        var s = Cutter(text: normalized(input))
        var result = ParsedTask()
        let today = Day.key(now, calendar: calendar)
        let numeric = NumericDate(locale: locale)

        result.priority = takePriority(&s)
        result.project = takeProject(&s)
        result.repeatRule = takeRepeat(&s)

        if let m = s.take("\\b(?:due(?: on| by)?|by|deadline)\\s+(\(dayExpr(numeric)))\\b"), let expr = m[1] {
            result.deadline = dayKey(from: expr, today: today, numeric: numeric, calendar: calendar)
        }

        var relative: Date?
        if let m = s.take("\\bin\\s+(\\d+|half an?|an?|one|two|three|four|five|six|ten|twelve)\\s*(minutes?|mins?|hours?|hrs?)\\b") {
            let amount = (m[1] ?? "").lowercased()
            let isHours = (m[2] ?? "").lowercased().hasPrefix("h")
            let minutes: Int
            if amount.hasPrefix("half") {
                minutes = 30
            } else {
                minutes = (Int(amount) ?? numberWords[amount] ?? 1) * (isHours ? 60 : 1)
            }
            relative = calendar.date(byAdding: .minute, value: minutes, to: now)
        } else if let m = s.take("\\bin\\s+half an?\\s+hour\\b"), m[0] != nil {
            relative = calendar.date(byAdding: .minute, value: 30, to: now)
        }

        var time = takeClock(&s)
        var explicitDay: String?

        // "tomorrow morning": keep the day word for the day pass below, turn the rest into a time.
        if let m = s.take("\\b(today|tomorrow|tmrw|\(fullDayAlt))\\s+(morning|afternoon|evening|night)\\b") {
            if time == nil { time = partOfDay(m[2]) }
            s.text += " " + (m[1] ?? "")
        } else if let m = s.take("\\b(this|in the)\\s+(morning|afternoon|evening)\\b") {
            if time == nil { time = partOfDay(m[2]) }
            if m[1]?.lowercased() == "this" { explicitDay = today }
        }
        if s.take("\\btonight\\b") != nil {
            if time == nil { time = Clock(hour: 20, minute: 0, explicit: true) }
            explicitDay = today
        }

        if let day = takeDay(&s, today: today, numeric: numeric, calendar: calendar) { explicitDay = day }

        let firstRepeat = result.repeatRule?.first(onOrAfter: today, calendar: calendar)

        if let relative {
            result.reminderAt = relative
            result.day = Day.key(relative, calendar: calendar)
        } else if let time {
            let anchored = explicitDay ?? result.deadline
            var base = anchored ?? firstRepeat ?? today
            var hour = time.hour
            if !time.explicit, hour < 12 {
                if anchored != nil {
                    if hour < 8 { hour += 12 }
                } else if Day.at(base, hour: hour, minute: time.minute, calendar: calendar) <= now {
                    hour += 12
                }
            }
            var at = Day.at(base, hour: hour, minute: time.minute, calendar: calendar)
            if at <= now, anchored == nil {
                base = result.repeatRule?.next(from: base, today: base, calendar: calendar) ?? Day.adding(1, to: base, calendar: calendar)
                at = Day.at(base, hour: hour, minute: time.minute, calendar: calendar)
            }
            result.reminderAt = at
            result.day = base
        } else {
            result.day = explicitDay ?? firstRepeat
        }

        result.title = cleanTitle(s.text)
        if result.title.isEmpty { result.title = cleanTitle(input) }
        return result
    }

    /// "12/25", "25.12.", "25/12/2026": day and month in the locale's order, its separator or a slash, an optional year.
    private struct NumericDate {
        var pattern: String
        var dayFirst: Bool

        init(locale: Locale) {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .short
            let format = f.dateFormat ?? "M/d/y"
            dayFirst = (format.firstIndex(of: "d") ?? format.endIndex) < (format.firstIndex(of: "M") ?? format.endIndex)
            let own = format.first { !$0.isLetter && !$0.isWhitespace && $0 != "'" } ?? "/"
            let sep = "[\\/\\\(own)]"
            let day = "(0?[1-9]|[12]\\d|3[01])", month = "(0?[1-9]|1[0-2])"
            // The lookarounds keep version numbers ("1.2.3") and prices ("10.50") out.
            pattern = "(?<![\\w./-])" + (dayFirst ? day + sep + month : month + sep + day)
                + "(?:\(sep)(\\d{4}|\\d{2})|\(sep)?)(?![\\w]|[./-]\\d)"
        }
    }

    private struct Clock {
        var hour: Int
        var minute: Int
        /// false when the phrase didn't say am or pm, as in "at 5".
        var explicit: Bool
    }

    private static func normalized(_ input: String) -> String {
        var s = Cutter(text: input.replacingOccurrences(of: "’", with: "'"))
        s.rewrite("\\b([ap])\\.\\s?m\\.?", "$1m")
        s.rewrite("\\s*o'?clock\\b", " ")
        for (word, value) in numberWords where word.count > 2 {
            s.rewrite("\\bat \(word)\\b", "at \(value)")
            s.rewrite("\\b\(word)(\\s*(?:am|pm)\\b)", "\(value)$1")
        }
        return s.text
    }

    private static func takePriority(_ s: inout Cutter) -> Priority {
        if let m = s.take("(?:^|\\s)!(high|hi|h|medium|med|m|low|lo|l|1|2|3)(?=\\s|$)") {
            switch (m[1] ?? "").lowercased() {
            case "high", "hi", "h", "1": return .high
            case "medium", "med", "m", "2": return .medium
            default: return .low
            }
        }
        if let m = s.take("\\bp([123])\\b") {
            return m[1] == "1" ? .high : m[1] == "2" ? .medium : .low
        }
        if s.take("\\b(?:urgent|high priority)\\b") != nil { return .high }
        if s.take("\\bmedium priority\\b") != nil { return .medium }
        if s.take("\\blow priority\\b") != nil { return .low }
        return .none
    }

    private static func takeProject(_ s: inout Cutter) -> String? {
        let m = s.take("(?:^|\\s)#([\\p{L}\\p{N}][\\p{L}\\p{N}_-]*)")
            ?? s.take("\\b(?:in )?project ([\\p{L}\\p{N}_-]+)\\b")
            ?? s.take("\\bhashtag ([\\p{L}\\p{N}_-]+)\\b")
        guard let name = m?[1] else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func takeRepeat(_ s: inout Cutter) -> RepeatRule? {
        if let m = s.take("\\bevery (\\d+) (day|week|month|year)s?\\b") {
            return RepeatRule(kind: kind(unit: m[2]), interval: Int(m[1] ?? "") ?? 1)
        }
        if let m = s.take("\\bevery other (day|week|month|year)\\b") {
            return RepeatRule(kind: kind(unit: m[1]), interval: 2)
        }
        if s.take("\\b(?:every weekday|(?:on )?weekdays)\\b") != nil { return RepeatRule(kind: .weekdays) }
        if s.take("\\b(?:every ?day|daily)\\b") != nil { return RepeatRule(kind: .daily) }
        if s.take("\\b(?:every week|weekly)\\b") != nil { return RepeatRule(kind: .weekly) }
        if s.take("\\b(?:every month|monthly)\\b") != nil { return RepeatRule(kind: .monthly) }
        if s.take("\\b(?:every year|yearly|annually)\\b") != nil { return RepeatRule(kind: .yearly) }

        let list = "(?:\(fullDayAlt)|\(shortDayAlt))"
        if let m = s.take("\\bevery (\(list)(?:(?:,? and |, )\(list))*)\\b"), let names = m[1] {
            return RepeatRule(kind: .weekly, weekdays: weekdayNumbers(in: names))
        }
        if let m = s.take("\\b(?:on )?(\(fullDayAlt))s\\b"), let name = m[1] {
            return RepeatRule(kind: .weekly, weekdays: weekdayNumbers(in: name))
        }
        return nil
    }

    private static func kind(unit: String?) -> RepeatRule.Kind {
        switch (unit ?? "").lowercased() {
        case "week": .weekly
        case "month": .monthly
        case "year": .yearly
        default: .daily
        }
    }

    private static func weekdayNumbers(in text: String) -> [Int] {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let numbers = words.compactMap { fullDays[$0] ?? shortDays[$0] }
        return Array(Set(numbers)).sorted()
    }

    private static func takeClock(_ s: inout Cutter) -> Clock? {
        if let m = s.take("\\b(?:at\\s+|@\\s*)?(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\b") {
            var hour = Int(m[1] ?? "") ?? 0
            let minute = Int(m[2] ?? "") ?? 0
            guard (1...12).contains(hour), minute < 60 else { return nil }
            let isPM = m[3]?.lowercased() == "pm"
            if isPM, hour < 12 { hour += 12 }
            if !isPM, hour == 12 { hour = 0 }
            return Clock(hour: hour, minute: minute, explicit: true)
        }
        if let m = s.take("(?:\\bat\\s+|@\\s*)(\\d{1,2})(?:[:.](\\d{2}))?\\b(?!\\s*(?:st|nd|rd|th)\\b)")
            ?? s.take("\\b(\\d{1,2}):(\\d{2})\\b") {
            let hour = Int(m[1] ?? "") ?? 0
            let minute = Int(m[2] ?? "") ?? 0
            guard hour < 24, minute < 60 else { return nil }
            return Clock(hour: hour, minute: minute, explicit: hour >= 13 || hour == 0)
        }
        if s.take("\\b(?:at\\s+)?(?:noon|midday)\\b") != nil { return Clock(hour: 12, minute: 0, explicit: true) }
        if s.take("\\b(?:at\\s+)?midnight\\b") != nil { return Clock(hour: 0, minute: 0, explicit: true) }
        return nil
    }

    private static func partOfDay(_ word: String?) -> Clock {
        switch (word ?? "").lowercased() {
        case "morning": Clock(hour: 9, minute: 0, explicit: true)
        case "afternoon": Clock(hour: 15, minute: 0, explicit: true)
        case "evening": Clock(hour: 18, minute: 0, explicit: true)
        default: Clock(hour: 20, minute: 0, explicit: true)
        }
    }

    private static func takeDay(_ s: inout Cutter, today: String, numeric: NumericDate, calendar: Calendar) -> String? {
        if s.take("\\b(?:the )?day after tomorrow\\b") != nil { return Day.adding(2, to: today, calendar: calendar) }
        if s.take("\\b(?:tomorrow|tmrw)\\b") != nil { return Day.adding(1, to: today, calendar: calendar) }
        if s.take("\\btoday\\b") != nil { return today }
        if let m = s.take("\\bin\\s+(\\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten)\\s+(day|week|month)s?\\b") {
            let word = (m[1] ?? "").lowercased()
            let amount = Int(word) ?? numberWords[word] ?? 1
            let start = Day.date(today, calendar: calendar)
            switch (m[2] ?? "").lowercased() {
            case "week": return Day.adding(7 * amount, to: today, calendar: calendar)
            case "month": return Day.key(calendar.date(byAdding: .month, value: amount, to: start)!, calendar: calendar)
            default: return Day.adding(amount, to: today, calendar: calendar)
            }
        }
        if let m = s.take("\\b(?:on\\s+)?(?:the\\s+)?(?:(\(monthAlt))\\.?\\s+(\\d{1,2})\(ordinal)|(\\d{1,2})\(ordinal)\\s+(?:of\\s+)?(\(monthAlt)))(?:,?\\s+(\\d{4}))?\\b") {
            let month = months[(m[1] ?? m[4] ?? "").lowercased()] ?? 1
            let date = Int(m[2] ?? m[3] ?? "") ?? 1
            return monthDay(month, date, year: m[5].flatMap { Int($0) }, today: today, calendar: calendar)
        }
        if let m = s.take(numeric.pattern) {
            let first = Int(m[1] ?? "") ?? 1, second = Int(m[2] ?? "") ?? 1
            let year = m[3].flatMap { Int($0) }.map { $0 < 100 ? 2000 + $0 : $0 }
            return numeric.dayFirst
                ? monthDay(second, first, year: year, today: today, calendar: calendar)
                : monthDay(first, second, year: year, today: today, calendar: calendar)
        }
        if let m = s.take("\\bnext (week|month)\\b") {
            if m[1]?.lowercased() == "month" {
                return Day.key(calendar.date(byAdding: .month, value: 1, to: Day.date(today, calendar: calendar))!, calendar: calendar)
            }
            return upcoming(weekday: 2, next: false, from: Day.adding(1, to: today, calendar: calendar), calendar: calendar)
        }
        if let m = s.take("\\b(?:on\\s+|this\\s+|(next)\\s+)?(\(fullDayAlt))\\b")
            ?? s.take("\\b(?:on\\s+|this\\s+|(next)\\s+)(\(shortDayAlt))\\b"),
            let name = m[2]?.lowercased(), let weekday = fullDays[name] ?? shortDays[name] {
            return upcoming(weekday: weekday, next: m[1] != nil, from: today, calendar: calendar)
        }
        return nil
    }

    private static func dayKey(from expr: String, today: String, numeric: NumericDate, calendar: Calendar) -> String? {
        var s = Cutter(text: expr)
        return takeDay(&s, today: today, numeric: numeric, calendar: calendar) ?? {
            // takeDay leaves bare short names alone so "sat with mom" stays a title; after "by" they're unambiguous.
            let lower = expr.lowercased()
            return shortDays[lower].map { upcoming(weekday: $0, next: false, from: today, calendar: calendar) }
        }()
    }

    /// `next` means the following calendar week: on a Tuesday, "next friday" skips this Friday.
    private static func upcoming(weekday: Int, next: Bool, from start: String, calendar: Calendar) -> String {
        var day = start
        while Day.weekday(day, calendar: calendar) != weekday { day = Day.adding(1, to: day, calendar: calendar) }
        if next {
            let sameWeek = calendar.isDate(Day.date(day, calendar: calendar), equalTo: Day.date(start, calendar: calendar), toGranularity: .weekOfYear)
            if sameWeek { day = Day.adding(7, to: day, calendar: calendar) }
        }
        return day
    }

    private static func monthDay(_ month: Int, _ date: Int, year: Int?, today: String, calendar: Calendar) -> String? {
        let thisYear = calendar.component(.year, from: Day.date(today, calendar: calendar))
        func key(_ y: Int) -> String { String(format: "%04d-%02d-%02d", y, month, date) }
        guard (1...31).contains(date) else { return nil }
        if let year { return key(year) }
        return key(thisYear) >= today ? key(thisYear) : key(thisYear + 1)
    }

    private static func cleanTitle(_ text: String) -> String {
        var s = Cutter(text: text)
        s.rewrite("\\s+", " ")
        s.rewrite("\\s+(?:on|at|by|due)\\s*$", "")
        s.rewrite("^\\s*(?:on|at|by)\\s+", "")
        let trimmed = s.text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—\t\n"))
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}
