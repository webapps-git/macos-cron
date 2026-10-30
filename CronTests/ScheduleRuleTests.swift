import Foundation
import Testing
@testable import Cron

/// Fixed calendar so results do not depend on the Mac running the tests.
let warsaw: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    calendar.firstWeekday = 2
    return calendar
}()

func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    warsaw.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

func time(_ hour: Int, _ minute: Int = 0) -> TimeOfDay {
    TimeOfDay(hour: hour, minute: minute)
}

@Suite("Schedule rules")
struct ScheduleRuleTests {
    // MARK: Set times every day

    @Test func dailyTimesPicksNextTimeToday() {
        var rule = ScheduleRule(kind: .dailyTimes)
        rule.times = [time(18), time(9)]

        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 10), calendar: warsaw) == date(2026, 10, 30, 18))
        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 18), calendar: warsaw) == date(2026, 10, 31, 9))
    }

    @Test func dailyTimesRespectsWeekdays() {
        var rule = ScheduleRule(kind: .dailyTimes)
        rule.times = [time(9)]
        rule.weekdays = [2] // Monday

        // Friday 30 Oct 2026 -> Monday 2 Nov 2026.
        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 10), calendar: warsaw) == date(2026, 11, 2, 9))
    }

    @Test func dailyTimeSkippedByDaylightSavingStillFires() throws {
        var rule = ScheduleRule(kind: .dailyTimes)
        rule.times = [time(2, 30)] // does not exist on 29 Mar 2026 in Warsaw

        let next = try #require(rule.nextOccurrence(after: date(2026, 3, 29, 0), calendar: warsaw))
        #expect(warsaw.isDate(next, inSameDayAs: date(2026, 3, 29, 12)))
        #expect(warsaw.component(.hour, from: next) >= 3)
    }

    // MARK: Interval

    @Test func intervalIsCountedFromStartNotFromLastRun() {
        var rule = ScheduleRule(kind: .interval)
        rule.start = date(2026, 10, 30, 8, 7)
        rule.every = 15
        rule.unit = .minutes

        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 10, 0), calendar: warsaw) == date(2026, 10, 30, 10, 7))
        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 10, 7), calendar: warsaw) == date(2026, 10, 30, 10, 22))
        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 7, 0), calendar: warsaw) == date(2026, 10, 30, 8, 7))
    }

    @Test func intervalUntilTimeRestartsNextDay() {
        var rule = ScheduleRule(kind: .interval)
        rule.start = date(2026, 10, 30, 8)
        rule.every = 1
        rule.unit = .hours
        rule.windowMode = .untilTime
        rule.windowEnd = time(17)

        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 16, 30), calendar: warsaw) == date(2026, 10, 30, 17))
        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 17), calendar: warsaw) == date(2026, 10, 31, 8))
    }

    @Test func intervalForDuration() {
        var rule = ScheduleRule(kind: .interval)
        rule.start = date(2026, 10, 30, 8)
        rule.every = 30
        rule.unit = .minutes
        rule.windowMode = .forDuration
        rule.windowDurationMinutes = 60

        let runs = rule.occurrences(after: date(2026, 10, 30, 7), count: 4, calendar: warsaw)
        #expect(runs == [date(2026, 10, 30, 8), date(2026, 10, 30, 8, 30), date(2026, 10, 30, 9), date(2026, 10, 31, 8)])
    }

    @Test func intervalWithWeekdaysSkipsOtherDays() {
        var rule = ScheduleRule(kind: .interval)
        rule.start = date(2026, 10, 30, 8)
        rule.every = 2
        rule.unit = .hours
        rule.weekdays = [2] // Monday

        #expect(rule.nextOccurrence(after: date(2026, 10, 30, 9), calendar: warsaw) == date(2026, 11, 2, 0))
    }

    @Test func dailyIntervalKeepsWallClockAcrossDaylightSaving() throws {
        var rule = ScheduleRule(kind: .interval)
        rule.start = date(2026, 10, 24, 9)
        rule.every = 1
        rule.unit = .days

        // Clocks go back on 25 Oct 2026; the run stays at 9:00 local time.
        let next = try #require(rule.nextOccurrence(after: date(2026, 10, 25, 0), calendar: warsaw))
        #expect(next == date(2026, 10, 25, 9))
        #expect(warsaw.component(.hour, from: next) == 9)
    }

    // MARK: Every N weeks

    @Test func everyTwoWeeks() {
        var rule = ScheduleRule(kind: .weekly)
        rule.start = date(2026, 11, 2)
        rule.everyWeeks = 2
        rule.weekdays = [2]
        rule.times = [time(9)]

        #expect(rule.nextOccurrence(after: date(2026, 11, 2, 10), calendar: warsaw) == date(2026, 11, 16, 9))
    }

    // MARK: Monthly

    @Test func monthlySkipsDaysMissingInMonth() {
        var rule = ScheduleRule(kind: .monthly)
        rule.monthlyMode = .daysOfMonth
        rule.monthDays = [31]
        rule.times = [time(9)]

        #expect(rule.nextOccurrence(after: date(2026, 4, 1), calendar: warsaw) == date(2026, 5, 31, 9))
    }

    @Test func monthlyLastDayInLeapYear() {
        var rule = ScheduleRule(kind: .monthly)
        rule.monthlyMode = .lastDay
        rule.times = [time(9)]

        #expect(rule.nextOccurrence(after: date(2028, 2, 1), calendar: warsaw) == date(2028, 2, 29, 9))
    }

    @Test(arguments: [
        (1, 2, date(2026, 11, 2, 9)),   // first Monday
        (-1, 6, date(2026, 11, 27, 9)), // last Friday
        (2, 6, date(2026, 11, 13, 9))   // second Friday
    ])
    func monthlyWeekdayOrdinal(ordinal: Int, weekday: Int, expected: Date) {
        var rule = ScheduleRule(kind: .monthly)
        rule.monthlyMode = .weekdayOrdinal
        rule.weekdayOrdinal = ordinal
        rule.ordinalWeekday = weekday
        rule.times = [time(9)]

        #expect(rule.nextOccurrence(after: date(2026, 11, 1), calendar: warsaw) == expected)
    }

    // MARK: Once, disabled

    @Test func onceFiresOnlyBeforeItsDate() {
        var rule = ScheduleRule(kind: .once)
        rule.start = date(2026, 11, 1, 12)

        #expect(rule.nextOccurrence(after: date(2026, 10, 30), calendar: warsaw) == date(2026, 11, 1, 12))
        #expect(rule.nextOccurrence(after: date(2026, 11, 2), calendar: warsaw) == nil)
    }

    @Test func disabledRuleNeverFires() {
        var rule = ScheduleRule(kind: .dailyTimes)
        rule.isEnabled = false

        #expect(rule.nextOccurrence(after: date(2026, 10, 30), calendar: warsaw) == nil)
    }

    // MARK: Stored JSON

    @Test func ruleFromOlderJSONGetsDefaults() throws {
        let rules = try DefaultDecoding.decodeList(ScheduleRule.self, from: #"[{"kind":"weekly","everyWeeks":3}]"#).get()
        let rule = try #require(rules.first)

        #expect(rule.kind == .weekly)
        #expect(rule.everyWeeks == 3)
        #expect(rule.times == [time(9)])
        #expect(rule.isEnabled)
    }
}
