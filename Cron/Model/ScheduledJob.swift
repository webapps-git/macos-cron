import Foundation
import SwiftData

nonisolated enum MaximumExecutionsBehavior: String, CaseIterable, Identifiable, Sendable {
    case deleteTask
    case disableTask

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .deleteTask:
            return "and then delete task"
        case .disableTask:
            return "and then disable task"
        }
    }
}

nonisolated enum JobStatus: String, Sendable {
    case idle
    case running
    case succeeded
    case failed

    var titleKey: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }

    @MainActor
    var title: String {
        L(titleKey)
    }
}

nonisolated enum NotificationMode: String, CaseIterable, Identifiable, Sendable {
    case always
    case errorsOnly
    case never

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .always:
            return "Always"
        case .errorsOnly:
            return "Only on errors"
        case .never:
            return "Never"
        }
    }
}

/// What to do when a scheduled time passed while the Mac slept or Cron was not running.
nonisolated enum MissedRunPolicy: String, CaseIterable, Identifiable, Sendable {
    case runOnce
    case skip

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .runOnce:
            return "Run once when possible"
        case .skip:
            return "Skip"
        }
    }
}

@Model
final class ScheduledJob {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()

    var name = ""
    var jobDescription = ""
    var isEnabled = true
    var groupName = ""
    var notificationModeRawValue = NotificationMode.errorsOnly.rawValue

    /// nil = no limit.
    var maximumExecutions: Int?
    var maximumExecutionsBehaviorRawValue = MaximumExecutionsBehavior.disableTask.rawValue
    var validFrom: Date?
    var validUntil: Date?
    var missedRunPolicyRawValue = MissedRunPolicy.runOnce.rawValue
    var preventsSleep = false
    var allowsURLTrigger = false
    /// Minimum minutes between event-triggered runs; 0 = no limit.
    var eventCooldownMinutes = 0
    var lastEventRunAt: Date?

    /// JSON lists; see `scheduleRules`, `eventTriggers`, `workflowSteps`.
    var scheduleRulesJSON = "[]"
    var eventTriggersJSON = "[]"
    var workflowJSON = "[]"

    /// Next scheduled run; kept so a run missed while the Mac slept can be detected.
    var nextRunAt: Date?
    var runCount = 0
    var lastRunAt: Date?
    var lastRunReason = ""
    var lastExitCode = 0
    var lastStatusRawValue = JobStatus.idle.rawValue
    var lastOutput = ""

    @Relationship(deleteRule: .cascade, inverse: \TaskRun.job)
    var runs: [TaskRun] = []

    init(name: String) {
        self.name = name
    }

    // MARK: Typed accessors

    var notificationMode: NotificationMode {
        get { NotificationMode(rawValue: notificationModeRawValue) ?? .errorsOnly }
        set { notificationModeRawValue = newValue.rawValue }
    }

    var maximumExecutionsBehavior: MaximumExecutionsBehavior {
        get { MaximumExecutionsBehavior(rawValue: maximumExecutionsBehaviorRawValue) ?? .disableTask }
        set { maximumExecutionsBehaviorRawValue = newValue.rawValue }
    }

    var missedRunPolicy: MissedRunPolicy {
        get { MissedRunPolicy(rawValue: missedRunPolicyRawValue) ?? .runOnce }
        set { missedRunPolicyRawValue = newValue.rawValue }
    }

    var status: JobStatus {
        get { JobStatus(rawValue: lastStatusRawValue) ?? .idle }
        set { lastStatusRawValue = newValue.rawValue }
    }

    var workflowSteps: [WorkflowStep] {
        get {
            switch decodeWorkflowSteps() {
            case .success(let steps):
                return steps
            case .failure(let error):
                NSLog("Cron: could not decode workflow of task \(name): \(error)")
                return []
            }
        }
        set {
            workflowJSON = DefaultDecoding.encodeList(newValue)
        }
    }

    /// Non-nil when the stored workflow JSON cannot be decoded. Callers must not overwrite it then.
    var workflowLoadError: String? {
        if case .failure(let error) = decodeWorkflowSteps() {
            return String(describing: error)
        }

        return nil
    }

    private func decodeWorkflowSteps() -> Result<[WorkflowStep], Error> {
        let trimmed = workflowJSON.trimmed

        guard !trimmed.isEmpty else {
            return .success([])
        }

        return Result {
            try JSONDecoder().decode([WorkflowStep].self, from: Data(trimmed.utf8))
        }
    }

    var scheduleRules: [ScheduleRule] {
        get { (try? DefaultDecoding.decodeList(ScheduleRule.self, from: scheduleRulesJSON).get()) ?? [] }
        set {
            scheduleRulesJSON = DefaultDecoding.encodeList(newValue)
            nextRunAt = nil
        }
    }

    var eventTriggers: [EventTrigger] {
        get { (try? DefaultDecoding.decodeList(EventTrigger.self, from: eventTriggersJSON).get()) ?? [] }
        set { eventTriggersJSON = DefaultDecoding.encodeList(newValue) }
    }

    func triggers(_ kind: EventKind) -> Bool {
        eventTriggers.contains { $0.kind == kind }
    }

    /// The first of the task's triggers that `occurrence` starts.
    func trigger(matching occurrence: EventOccurrence) -> EventTrigger? {
        eventTriggers.first { $0.matches(occurrence) }
    }

    // MARK: Scheduling

    var hasReachedMaximumExecutions: Bool {
        if let maximumExecutions {
            return runCount >= max(1, maximumExecutions)
        }

        return false
    }

    /// Whether the task may run at `date` (enabled, within its validity period, below its run limit).
    func canRun(at date: Date) -> Bool {
        guard isEnabled, !hasReachedMaximumExecutions else {
            return false
        }

        if let validFrom, date < validFrom {
            return false
        }

        if let validUntil, date > validUntil {
            return false
        }

        return true
    }

    /// The earliest rule occurrence after `date` inside the validity period, or nil.
    func nextRunDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled, !hasReachedMaximumExecutions else {
            return nil
        }

        var reference = date
        if let validFrom, validFrom > reference {
            reference = validFrom.addingTimeInterval(-1)
        }

        let next = scheduleRules
            .compactMap { $0.nextOccurrence(after: reference, calendar: calendar) }
            .min()

        if let next, let validUntil, next > validUntil {
            return nil
        }

        return next
    }

    func recordExecution(_ result: TaskExecutionResult, reason: String) {
        runCount += 1
        lastRunAt = result.finishedAt
        lastRunReason = reason
        lastExitCode = Int(result.exitCode)
        status = result.exitCode == 0 ? .succeeded : .failed
        lastOutput = Self.cappedOutput(result.output)
        updatedAt = Date()
    }

    // MARK: Summaries

    @MainActor
    var actionSummary: String {
        let steps = workflowSteps

        if steps.isEmpty {
            return L("No actions")
        }

        if steps.count == 1 {
            return steps[0].title
        }

        return "\(steps.count) \(L("workflow actions"))"
    }

    @MainActor
    var scheduleSummary: String {
        let rules = scheduleRules.filter(\.isEnabled)

        if rules.isEmpty {
            return L("No schedule")
        }

        if let next = nextRunAt ?? nextRunDate(after: Date()) {
            return "\(L("Next")): \(next.formatted(date: .abbreviated, time: .shortened))"
        }

        return L("No upcoming runs")
    }

    private static func cappedOutput(_ output: String) -> String {
        guard output.count > 20_000 else {
            return output
        }

        return "[Output truncated to last 20000 characters]\n" + String(output.suffix(20_000))
    }
}
