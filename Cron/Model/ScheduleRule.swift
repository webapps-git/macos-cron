import Foundation

/// Hour and minute of a day.
nonisolated struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    var minutesSinceMidnight: Int {
        hour * 60 + minute
    }

    static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }

    /// The given day at this time. Times skipped by a daylight-saving change move to the next valid time.
    func on(_ day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
}

nonisolated enum ScheduleRuleKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case interval
    case dailyTimes
    case weekly
    case monthly
    case once

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .interval:
            return "Repeat at an interval"
        case .dailyTimes:
            return "At set times every day"
        case .weekly:
            return "Every N weeks"
        case .monthly:
            return "Monthly"
        case .once:
            return "Once"
        }
    }
}

/// Interval units. Scheduling works with one-minute precision, so there are no seconds.
nonisolated enum ScheduleIntervalUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case minutes
    case hours
    case days

    var id: String { rawValue }

    var titleKey: String {
        rawValue
    }

    var minutes: Int {
        switch self {
        case .minutes:
            return 1
        case .hours:
            return 60
        case .days:
            return 1_440
        }
    }
}

/// Limits repetition within a day, like "repeat for a duration" in the Windows Task Scheduler.
nonisolated enum ScheduleWindowMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case untilTime
    case forDuration

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .none:
            return "All day"
        case .untilTime:
            return "Until time"
        case .forDuration:
            return "For a duration"
        }
    }
}

nonisolated enum MonthlyMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case daysOfMonth
    case lastDay
    case weekdayOrdinal

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .daysOfMonth:
            return "On days of the month"
        case .lastDay:
            return "On the last day of the month"
        case .weekdayOrdinal:
            return "On a weekday of the month"
        }
    }
}

/// One time-based trigger of a task. Which fields are used depends on `kind`.
nonisolated struct ScheduleRule: DefaultDecodable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var isEnabled = true
    var kind = ScheduleRuleKind.dailyTimes

    /// interval, weekly: first occurrence / anchor; once: the date and time.
    var start = ScheduleRule.nextFullHour()

    // interval
    var every = 1
    var unit = ScheduleIntervalUnit.hours
    var windowMode = ScheduleWindowMode.none
    var windowEnd = TimeOfDay(hour: 17, minute: 0)
    var windowDurationMinutes = 60

    // dailyTimes, weekly, monthly
    var times: [TimeOfDay] = [TimeOfDay(hour: 9, minute: 0)]

    /// interval, dailyTimes, weekly: `Calendar` weekday numbers (1 = Sunday). Empty = every day.
    var weekdays: Set<Int> = []

    // weekly
    var everyWeeks = 1

    // monthly
    var monthlyMode = MonthlyMode.daysOfMonth
    var monthDays: Set<Int> = [1]
    /// 1...4 = first...fourth, -1 = last.
    var weekdayOrdinal = 1
    var ordinalWeekday = 2

    init() {}

    init(kind: ScheduleRuleKind) {
        self.kind = kind
    }

    static func nextFullHour(after date: Date = Date(), calendar: Calendar = .current) -> Date {
        let hourStart = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? date
    }

    // MARK: Next occurrence

    /// The first occurrence strictly after `date`, or `nil` if there is none.
    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else {
            return nil
        }

        switch kind {
        case .interval:
            return nextInterval(after: date, calendar: calendar)
        case .dailyTimes:
            return nextOnMatchingDays(after: date, calendar: calendar, maxDays: 8) { day in
                isAllowed(weekdayOf: day, calendar: calendar)
            }
        case .weekly:
            let anchorWeek = startOfWeek(minuteStart(start, calendar: calendar), calendar: calendar)
            let firstDay = calendar.startOfDay(for: start)
            return nextOnMatchingDays(after: date, calendar: calendar, maxDays: 7 * max(1, everyWeeks) + 8) { day in
                guard day >= firstDay, isAllowed(weekdayOf: day, calendar: calendar) else {
                    return false
                }

                let weeks = calendar.dateComponents([.weekOfYear], from: anchorWeek, to: startOfWeek(day, calendar: calendar)).weekOfYear ?? 0
                return weeks % max(1, everyWeeks) == 0
            }
        case .monthly:
            return nextMonthly(after: date, calendar: calendar)
        case .once:
            let occurrence = minuteStart(start, calendar: calendar)
            return occurrence > date ? occurrence : nil
        }
    }

    /// Upcoming occurrences, e.g. for a preview.
    func occurrences(after date: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []
        var cursor = date

        while result.count < count, let next = nextOccurrence(after: cursor, calendar: calendar) {
            result.append(next)
            cursor = next
        }

        return result
    }

    private func isAllowed(weekdayOf day: Date, calendar: Calendar) -> Bool {
        weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: day))
    }

    private func minuteStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    private func startOfWeek(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private var sortedTimes: [TimeOfDay] {
        times.isEmpty ? [TimeOfDay(hour: 0, minute: 0)] : times.sorted()
    }

    /// Walks day by day from `date`'s day and returns the first `times` slot after `date` on a matching day.
    private func nextOnMatchingDays(after date: Date, calendar: Calendar, maxDays: Int, matches: (Date) -> Bool) -> Date? {
        var day = calendar.startOfDay(for: date)

        for _ in 0..<maxDays {
            if matches(day) {
                for time in sortedTimes {
                    if let candidate = time.on(day, calendar: calendar), candidate > date {
                        return candidate
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            day = nextDay
        }

        return nil
    }

    private func nextInterval(after date: Date, calendar: Calendar) -> Date? {
        let first = minuteStart(start, calendar: calendar)
        let every = max(1, self.every)

        if first > date, isAllowed(weekdayOf: first, calendar: calendar), windowMode == .none || unit == .days {
            return first
        }

        if unit == .days {
            // Whole days keep the wall-clock time across daylight-saving changes.
            let elapsedDays = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: date)).day ?? 0)
            var index = elapsedDays / every

            for _ in 0..<(366 * 2) {
                if let candidate = calendar.date(byAdding: .day, value: index * every, to: first),
                   candidate > date, isAllowed(weekdayOf: candidate, calendar: calendar) {
                    return candidate
                }
                index += 1
            }

            return nil
        }

        let stepSeconds = TimeInterval(every * unit.minutes * 60)

        if windowMode == .none {
            var index = max(0, Int((date.timeIntervalSince(first) / stepSeconds).rounded(.down)))

            for _ in 0..<100_000 {
                let candidate = first.addingTimeInterval(TimeInterval(index) * stepSeconds)

                if candidate > date {
                    if isAllowed(weekdayOf: candidate, calendar: calendar) {
                        return candidate
                    }

                    // Jump to the first step on the next day instead of walking minute by minute.
                    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: candidate)) else {
                        return nil
                    }
                    index = max(index + 1, Int((nextDay.timeIntervalSince(first) / stepSeconds).rounded(.up)))
                } else {
                    index += 1
                }
            }

            return nil
        }

        // With a daily window the repetition restarts every day at the start time.
        let dailyStart = TimeOfDay(first, calendar: calendar)
        var day = calendar.startOfDay(for: max(date, first))

        for _ in 0..<370 {
            if day >= calendar.startOfDay(for: first), isAllowed(weekdayOf: day, calendar: calendar),
               let windowStart = dailyStart.on(day, calendar: calendar) {
                let windowEnd: Date?
                switch windowMode {
                case .untilTime:
                    windowEnd = self.windowEnd.on(day, calendar: calendar)
                case .forDuration:
                    windowEnd = windowStart.addingTimeInterval(TimeInterval(max(0, windowDurationMinutes) * 60))
                case .none:
                    windowEnd = nil
                }

                if let windowEnd, windowEnd >= windowStart {
                    var candidate = max(windowStart, first)
                    if date >= candidate {
                        let steps = (date.timeIntervalSince(windowStart) / stepSeconds).rounded(.down) + 1
                        candidate = windowStart.addingTimeInterval(steps * stepSeconds)
                    }

                    if candidate > date, candidate <= windowEnd {
                        return candidate
                    }
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            day = nextDay
        }

        return nil
    }

    private func nextMonthly(after date: Date, calendar: Calendar) -> Date? {
        guard let firstMonth = calendar.dateInterval(of: .month, for: date)?.start else {
            return nil
        }

        for offset in 0..<60 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: firstMonth),
                  let dayRange = calendar.range(of: .day, in: .month, for: month) else {
                continue
            }

            for day in monthlyDays(in: month, dayCount: dayRange.count, calendar: calendar) {
                guard let dayDate = calendar.date(byAdding: .day, value: day - 1, to: month) else {
                    continue
                }

                for time in sortedTimes {
                    if let candidate = time.on(dayDate, calendar: calendar), candidate > date {
                        return candidate
                    }
                }
            }
        }

        return nil
    }

    /// Day numbers (1-based, ascending) the monthly rule fires on in the month starting at `month`.
    private func monthlyDays(in month: Date, dayCount: Int, calendar: Calendar) -> [Int] {
        switch monthlyMode {
        case .daysOfMonth:
            // Days that do not exist in the month (e.g. 31 in April) are skipped.
            return monthDays.filter { (1...dayCount).contains($0) }.sorted()
        case .lastDay:
            return [dayCount]
        case .weekdayOrdinal:
            let firstWeekday = calendar.component(.weekday, from: month)
            let firstMatch = 1 + (ordinalWeekday - firstWeekday + 7) % 7
            let matches = Array(stride(from: firstMatch, through: dayCount, by: 7))

            if weekdayOrdinal == -1 {
                return matches.last.map { [$0] } ?? []
            }

            return matches.indices.contains(weekdayOrdinal - 1) ? [matches[weekdayOrdinal - 1]] : []
        }
    }
}
