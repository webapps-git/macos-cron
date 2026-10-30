import AppKit
import SwiftData
import SwiftUI

struct ScheduleTabView: View {
    @Environment(\.openSettings) private var openSettings
    @Bindable var job: ScheduledJob
    var onScheduleChange: () -> Void

    @State private var selectedRuleID: ScheduleRule.ID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rulesSection

                if let ruleBinding = selectedRuleBinding {
                    ScheduleRuleEditor(rule: ruleBinding)
                }

                UpcomingRunsView(job: job)

                Divider()

                taskSettingsSection

                Label(L("Tasks run only while Cron is running and you are logged in. A Mac that is asleep or turned off does not run tasks."), systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)

                Button(L("Launch at login…")) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.link)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if selectedRuleID == nil {
                selectedRuleID = job.scheduleRules.first?.id
            }
        }
    }

    // MARK: Rules list

    private var rulesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(L("Schedule rules"), systemImage: "calendar.badge.clock")
                        .font(.headline)

                    Spacer()

                    Menu {
                        ForEach(ScheduleRuleKind.allCases) { kind in
                            Button(L(kind.titleKey)) {
                                addRule(kind)
                            }
                        }
                    } label: {
                        Label(L("Add rule"), systemImage: "plus")
                    }
                    .fixedSize()
                }

                if job.scheduleRules.isEmpty {
                    Text(L("No schedule rules. The task runs only on events or manually."))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(job.scheduleRules) { rule in
                        ScheduleRuleRow(
                            rule: rule,
                            isSelected: rule.id == selectedRuleID,
                            onSelect: { selectedRuleID = rule.id },
                            onToggle: { updateRule(rule.id) { $0.isEnabled.toggle() } },
                            onDelete: { deleteRule(rule.id) }
                        )
                    }
                }
            }
            .padding(8)
        }
    }

    private var selectedRuleBinding: Binding<ScheduleRule>? {
        guard let selectedRuleID, job.scheduleRules.contains(where: { $0.id == selectedRuleID }) else {
            return nil
        }

        return Binding {
            job.scheduleRules.first { $0.id == selectedRuleID } ?? ScheduleRule()
        } set: { updated in
            updateRule(selectedRuleID) { $0 = updated }
        }
    }

    private func addRule(_ kind: ScheduleRuleKind) {
        var rule = ScheduleRule(kind: kind)
        if kind == .once {
            rule.start = ScheduleRule.nextFullHour()
        }

        job.scheduleRules.append(rule)
        selectedRuleID = rule.id
        onScheduleChange()
    }

    private func updateRule(_ id: ScheduleRule.ID, _ change: (inout ScheduleRule) -> Void) {
        var rules = job.scheduleRules
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            return
        }

        change(&rules[index])
        job.scheduleRules = rules
        onScheduleChange()
    }

    private func deleteRule(_ id: ScheduleRule.ID) {
        job.scheduleRules.removeAll { $0.id == id }
        if selectedRuleID == id {
            selectedRuleID = job.scheduleRules.first?.id
        }
        onScheduleChange()
    }

    // MARK: Task-level settings

    private var taskSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            OptionalDateRow(title: "Schedule valid from", date: $job.validFrom, onChange: onScheduleChange)
            OptionalDateRow(title: "Schedule valid until", date: $job.validUntil, onChange: onScheduleChange)

            HStack {
                Text(L("When a scheduled time is missed"))

                Picker("", selection: $job.missedRunPolicyRawValue) {
                    ForEach(MissedRunPolicy.allCases) { policy in
                        Text(L(policy.titleKey)).tag(policy.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            Toggle(L("Keep the Mac awake while the task runs"), isOn: $job.preventsSleep)
        }
    }
}

// MARK: - Rule row

private struct ScheduleRuleRow: View {
    var rule: ScheduleRule
    var isSelected: Bool
    var onSelect: () -> Void
    var onToggle: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()

            Image(systemName: "clock")
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(L(rule.kind.titleKey))
                    .font(.headline)

                Text(ScheduleRuleText.summary(rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete"))
        }
        .padding(10)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Rule editor

private struct ScheduleRuleEditor: View {
    @Binding var rule: ScheduleRule

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Picker(L("Rule"), selection: $rule.kind) {
                    ForEach(ScheduleRuleKind.allCases) { kind in
                        Text(L(kind.titleKey)).tag(kind)
                    }
                }
                .frame(maxWidth: 360)

                switch rule.kind {
                case .interval:
                    intervalEditor
                case .dailyTimes:
                    TimesEditor(times: $rule.times)
                    WeekdaySelector(weekdays: $rule.weekdays)
                case .weekly:
                    LabeledRow(title: "Start") {
                        DatePicker("", selection: $rule.start, displayedComponents: .date)
                            .labelsHidden()
                    }
                    LabeledRow(title: "Every") {
                        Stepper(value: $rule.everyWeeks, in: 1...52) {
                            Text("\(rule.everyWeeks) \(L("weeks"))")
                        }
                    }
                    WeekdaySelector(weekdays: $rule.weekdays)
                    TimesEditor(times: $rule.times)
                case .monthly:
                    monthlyEditor
                    TimesEditor(times: $rule.times)
                case .once:
                    LabeledRow(title: "Date and time") {
                        DatePicker("", selection: $rule.start, displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var intervalEditor: some View {
        LabeledRow(title: "Start") {
            DatePicker("", selection: $rule.start, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }

        LabeledRow(title: "Repeat every") {
            HStack {
                Stepper(value: $rule.every, in: 1...10_000) {
                    Text("\(rule.every)")
                        .frame(width: 54, alignment: .leading)
                }

                Picker("", selection: $rule.unit) {
                    ForEach(ScheduleIntervalUnit.allCases) { unit in
                        Text(L(unit.titleKey)).tag(unit)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }

        if rule.unit != .days {
            LabeledRow(title: "Each day") {
                HStack {
                    Picker("", selection: $rule.windowMode) {
                        ForEach(ScheduleWindowMode.allCases) { mode in
                            Text(L(mode.titleKey)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)

                    switch rule.windowMode {
                    case .none:
                        EmptyView()
                    case .untilTime:
                        DatePicker("", selection: TimeOfDayBinding.date($rule.windowEnd), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    case .forDuration:
                        Stepper(value: $rule.windowDurationMinutes, in: 15...1_440, step: 15) {
                            Text(DurationText.minutes(rule.windowDurationMinutes))
                                .frame(width: 90, alignment: .leading)
                        }
                    }
                }
            }
        }

        WeekdaySelector(weekdays: $rule.weekdays)
    }

    @ViewBuilder
    private var monthlyEditor: some View {
        Picker("", selection: $rule.monthlyMode) {
            ForEach(MonthlyMode.allCases) { mode in
                Text(L(mode.titleKey)).tag(mode)
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()

        switch rule.monthlyMode {
        case .daysOfMonth:
            MonthDaySelector(days: $rule.monthDays)
        case .lastDay:
            EmptyView()
        case .weekdayOrdinal:
            HStack {
                Picker("", selection: $rule.weekdayOrdinal) {
                    Text(L("First")).tag(1)
                    Text(L("Second")).tag(2)
                    Text(L("Third")).tag(3)
                    Text(L("Fourth")).tag(4)
                    Text(L("Last")).tag(-1)
                }
                .labelsHidden()
                .frame(width: 140)

                Picker("", selection: $rule.ordinalWeekday) {
                    ForEach(WeekdaySelector.orderedWeekdays, id: \.self) { weekday in
                        Text(L(WeekdaySelector.shortNameKey(weekday))).tag(weekday)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }
    }
}

// MARK: - Shared editors

private struct LabeledRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Text(L(title))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            content
        }
    }
}

private struct TimesEditor: View {
    @Binding var times: [TimeOfDay]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Times"))
                .foregroundStyle(.secondary)

            ForEach(times.indices, id: \.self) { index in
                HStack {
                    DatePicker("", selection: TimeOfDayBinding.date(timeBinding(index)), displayedComponents: .hourAndMinute)
                        .labelsHidden()

                    Button(role: .destructive) {
                        times.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(times.count == 1)
                }
            }

            Button {
                let last = times.max() ?? TimeOfDay(hour: 8, minute: 0)
                times.append(TimeOfDay(hour: min(23, last.hour + 1), minute: last.minute))
            } label: {
                Label(L("Add time"), systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    private func timeBinding(_ index: Int) -> Binding<TimeOfDay> {
        Binding {
            times.indices.contains(index) ? times[index] : TimeOfDay(hour: 0, minute: 0)
        } set: { value in
            if times.indices.contains(index) {
                times[index] = value
            }
        }
    }
}

struct WeekdaySelector: View {
    @Binding var weekdays: Set<Int>

    /// Monday first; values are `Calendar` weekday numbers (1 = Sunday).
    static let orderedWeekdays = [2, 3, 4, 5, 6, 7, 1]

    static func shortNameKey(_ weekday: Int) -> String {
        ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(weekday - 1) % 7]
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(L("Days"))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            ForEach(Self.orderedWeekdays, id: \.self) { weekday in
                Toggle(L(Self.shortNameKey(weekday)), isOn: binding(weekday))
            }
        }
        .toggleStyle(.checkbox)
        .help(L("No day selected means every day."))
    }

    private func binding(_ weekday: Int) -> Binding<Bool> {
        Binding {
            weekdays.contains(weekday)
        } set: { isOn in
            if isOn {
                weekdays.insert(weekday)
            } else {
                weekdays.remove(weekday)
            }
        }
    }
}

private struct MonthDaySelector: View {
    @Binding var days: Set<Int>

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(0..<5) { row in
                GridRow {
                    ForEach(1...7, id: \.self) { column in
                        let day = row * 7 + column
                        if day <= 31 {
                            Toggle("\(day)", isOn: binding(day))
                                .toggleStyle(.button)
                                .frame(width: 36)
                        }
                    }
                }
            }
        }
        .help(L("Days that do not exist in a month are skipped."))
    }

    private func binding(_ day: Int) -> Binding<Bool> {
        Binding {
            days.contains(day)
        } set: { isOn in
            if isOn {
                days.insert(day)
            } else if days.count > 1 {
                days.remove(day)
            }
        }
    }
}

private struct OptionalDateRow: View {
    var title: String
    @Binding var date: Date?
    var onChange: () -> Void

    var body: some View {
        HStack {
            Toggle(L(title), isOn: Binding {
                date != nil
            } set: { isOn in
                date = isOn ? (date ?? Date()) : nil
                onChange()
            })

            DatePicker("", selection: Binding {
                date ?? Date()
            } set: { value in
                date = value
                onChange()
            }, displayedComponents: [.date, .hourAndMinute])
            .labelsHidden()
            .disabled(date == nil)
        }
    }
}

private struct UpcomingRunsView: View {
    var job: ScheduledJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Upcoming runs"))
                .font(.headline)

            let dates = upcoming(count: 5)
            if dates.isEmpty {
                Text(L("No upcoming runs"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dates, id: \.self) { date in
                    Text(date.formatted(date: .complete, time: .shortened))
                        .monospacedDigit()
                }
            }
        }
    }

    private func upcoming(count: Int) -> [Date] {
        var result: [Date] = []
        var cursor = Date()

        while result.count < count, let next = job.nextRunDate(after: cursor) {
            result.append(next)
            cursor = next
        }

        return result
    }
}

enum TimeOfDayBinding {
    /// Edits a `TimeOfDay` with a `DatePicker` showing hours and minutes.
    static func date(_ time: Binding<TimeOfDay>) -> Binding<Date> {
        Binding {
            time.wrappedValue.on(Date(), calendar: .current) ?? Date()
        } set: { date in
            time.wrappedValue = TimeOfDay(date)
        }
    }
}

enum DurationText {
    static func minutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60

        if hours == 0 {
            return "\(rest) min"
        }

        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

enum ScheduleRuleText {
    @MainActor
    static func summary(_ rule: ScheduleRule) -> String {
        let times = rule.times.sorted().map { String(format: "%02d:%02d", $0.hour, $0.minute) }.joined(separator: ", ")
        let days = rule.weekdays.isEmpty
            ? ""
            : " · " + WeekdaySelector.orderedWeekdays.filter(rule.weekdays.contains).map { L(WeekdaySelector.shortNameKey($0)) }.joined(separator: ", ")

        switch rule.kind {
        case .interval:
            var text = "\(L("Every")) \(rule.every) \(L(rule.unit.titleKey)) · \(L("Start")) \(rule.start.formatted(date: .abbreviated, time: .shortened))"
            if rule.unit != .days {
                switch rule.windowMode {
                case .none:
                    break
                case .untilTime:
                    text += " · \(L("Until time")) \(String(format: "%02d:%02d", rule.windowEnd.hour, rule.windowEnd.minute))"
                case .forDuration:
                    text += " · \(DurationText.minutes(rule.windowDurationMinutes))"
                }
            }
            return text + days
        case .dailyTimes:
            return times + days
        case .weekly:
            return "\(L("Every")) \(rule.everyWeeks) \(L("weeks")) · \(times)\(days)"
        case .monthly:
            switch rule.monthlyMode {
            case .daysOfMonth:
                return "\(rule.monthDays.sorted().map(String.init).joined(separator: ", ")) · \(times)"
            case .lastDay:
                return "\(L("On the last day of the month")) · \(times)"
            case .weekdayOrdinal:
                let ordinal = [1: "First", 2: "Second", 3: "Third", 4: "Fourth", -1: "Last"][rule.weekdayOrdinal] ?? "First"
                return "\(L(ordinal)) \(L(WeekdaySelector.shortNameKey(rule.ordinalWeekday))) · \(times)"
            }
        case .once:
            return rule.start.formatted(date: .abbreviated, time: .shortened)
        }
    }
}
