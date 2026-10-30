import Foundation
import SwiftData

/// Settings of one task as written to an export file. Run state and history are not exported.
nonisolated struct ExportedTask: Codable, Sendable {
    var name: String
    var description: String
    var isEnabled: Bool
    var group: String
    var notificationMode: String
    var maximumExecutions: Int?
    var maximumExecutionsBehavior: String
    var validFrom: Date?
    var validUntil: Date?
    var missedRunPolicy: String
    var preventsSleep: Bool
    var allowsURLTrigger: Bool
    var eventCooldownMinutes: Int
    var scheduleRules: [JSONValue]
    var eventTriggers: [JSONValue]
    var workflowSteps: [JSONValue]
}

nonisolated struct TaskExportFile: Codable, Sendable {
    static let formatName = "cron-tasks"
    static let currentVersion = 1

    var format = TaskExportFile.formatName
    var version = TaskExportFile.currentVersion
    var exportedAt = Date()
    var tasks: [ExportedTask]
}

nonisolated enum TaskTransferError: LocalizedError {
    case notACronFile
    case unsupportedVersion(Int)
    case invalidTask(name: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .notACronFile:
            return "The file is not a Cron task export."
        case .unsupportedVersion(let version):
            return "The export file version \(version) is not supported."
        case .invalidTask(let name, let reason):
            return "Task \"\(name)\" could not be read: \(reason)"
        }
    }
}

/// Export, import and duplication of tasks.
enum TaskTransfer {
    static func exportData(_ jobs: [ScheduledJob]) throws -> Data {
        let file = TaskExportFile(tasks: try jobs.map(exported))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(file)
    }

    /// Creates the tasks from `data` in `context`. Imported tasks are disabled until reviewed and
    /// get a "(2)", "(3)"… suffix when the name is taken. Nothing is inserted if any task is invalid.
    @discardableResult
    static func importTasks(from data: Data, into context: ModelContext, existingNames: Set<String>) throws -> [ScheduledJob] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let file = try? decoder.decode(TaskExportFile.self, from: data), file.format == TaskExportFile.formatName else {
            throw TaskTransferError.notACronFile
        }

        guard file.version <= TaskExportFile.currentVersion else {
            throw TaskTransferError.unsupportedVersion(file.version)
        }

        var names = existingNames
        var jobs: [ScheduledJob] = []

        for task in file.tasks {
            let job = try makeJob(from: task)
            job.name = uniqueName(task.name, existing: names)
            job.isEnabled = false
            names.insert(job.name)
            jobs.append(job)
        }

        jobs.forEach(context.insert)
        return jobs
    }

    /// A disabled copy named "<name> (copy)", without run state or history.
    static func duplicate(_ job: ScheduledJob, existingNames: Set<String>, copySuffix: String) throws -> ScheduledJob {
        let copy = try makeJob(from: exported(job))
        copy.name = uniqueName("\(job.name) (\(copySuffix))", existing: existingNames)
        copy.isEnabled = false
        return copy
    }

    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else {
            return name
        }

        var index = 2
        while existing.contains("\(name) (\(index))") {
            index += 1
        }
        return "\(name) (\(index))"
    }

    private static func exported(_ job: ScheduledJob) throws -> ExportedTask {
        if let error = job.workflowLoadError {
            throw TaskTransferError.invalidTask(name: job.name, reason: error)
        }

        return ExportedTask(
            name: job.name,
            description: job.jobDescription,
            isEnabled: job.isEnabled,
            group: job.groupName,
            notificationMode: job.notificationModeRawValue,
            maximumExecutions: job.maximumExecutions,
            maximumExecutionsBehavior: job.maximumExecutionsBehaviorRawValue,
            validFrom: job.validFrom,
            validUntil: job.validUntil,
            missedRunPolicy: job.missedRunPolicyRawValue,
            preventsSleep: job.preventsSleep,
            allowsURLTrigger: job.allowsURLTrigger,
            eventCooldownMinutes: job.eventCooldownMinutes,
            scheduleRules: try jsonList(job.scheduleRulesJSON),
            eventTriggers: try jsonList(job.eventTriggersJSON),
            workflowSteps: try jsonList(job.workflowJSON)
        )
    }

    private static func makeJob(from task: ExportedTask) throws -> ScheduledJob {
        let job = ScheduledJob(name: task.name)
        job.jobDescription = task.description
        job.isEnabled = task.isEnabled
        job.groupName = task.group
        job.notificationModeRawValue = NotificationMode(rawValue: task.notificationMode)?.rawValue ?? NotificationMode.errorsOnly.rawValue
        job.maximumExecutions = task.maximumExecutions
        job.maximumExecutionsBehaviorRawValue = MaximumExecutionsBehavior(rawValue: task.maximumExecutionsBehavior)?.rawValue ?? MaximumExecutionsBehavior.disableTask.rawValue
        job.validFrom = task.validFrom
        job.validUntil = task.validUntil
        job.missedRunPolicyRawValue = MissedRunPolicy(rawValue: task.missedRunPolicy)?.rawValue ?? MissedRunPolicy.runOnce.rawValue
        job.preventsSleep = task.preventsSleep
        job.allowsURLTrigger = task.allowsURLTrigger
        job.eventCooldownMinutes = max(0, task.eventCooldownMinutes)

        // Re-encode through the typed models so invalid entries are rejected here, not at run time.
        do {
            let steps = try JSONDecoder().decode([WorkflowStep].self, from: JSONEncoder().encode(task.workflowSteps))
            let rules = try DefaultDecoding.decodeList(ScheduleRule.self, from: text(task.scheduleRules)).get()
            let triggers = try DefaultDecoding.decodeList(EventTrigger.self, from: text(task.eventTriggers)).get()
            job.workflowSteps = steps
            job.scheduleRules = rules
            job.eventTriggers = triggers
        } catch {
            throw TaskTransferError.invalidTask(name: task.name, reason: String(describing: error))
        }

        return job
    }

    private static func jsonList(_ text: String) throws -> [JSONValue] {
        let trimmed = text.trimmed
        return trimmed.isEmpty ? [] : try JSONDecoder().decode([JSONValue].self, from: Data(trimmed.utf8))
    }

    private static func text(_ values: [JSONValue]) throws -> String {
        String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }
}

/// Searching and sorting the task list.
enum TaskListOrder: String, CaseIterable, Identifiable {
    case name
    case nextRun
    case lastRun
    case created

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .name:
            return "Name"
        case .nextRun:
            return "Next run"
        case .lastRun:
            return "Last run"
        case .created:
            return "Date created"
        }
    }

    func sorted(_ jobs: [ScheduledJob]) -> [ScheduledJob] {
        switch self {
        case .name:
            return jobs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nextRun:
            return jobs.sorted { ($0.nextRunAt ?? .distantFuture, $0.name) < ($1.nextRunAt ?? .distantFuture, $1.name) }
        case .lastRun:
            return jobs.sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
        case .created:
            return jobs.sorted { $0.createdAt > $1.createdAt }
        }
    }
}

enum TaskSearch {
    /// Matches name, description and step titles, ignoring case and diacritics.
    static func matches(_ job: ScheduledJob, query: String) -> Bool {
        let query = query.trimmed
        guard !query.isEmpty else {
            return true
        }

        return [job.name, job.jobDescription].contains { $0.localizedStandardContains(query) }
            || job.workflowSteps.contains { $0.title.localizedStandardContains(query) }
    }
}
