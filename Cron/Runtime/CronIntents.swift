import AppIntents
import Foundation
import SwiftData

// Shortcuts actions. They run inside Cron (macOS starts it in the background when needed) and use
// the runtime registered with AppDependencyManager in CronApp.init. Titles are keys of
// Localizable.strings.

struct CronTaskEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Cron task")
    static let defaultQuery = CronTaskQuery()

    var id: UUID
    var name: String
    var group: String

    var displayRepresentation: DisplayRepresentation {
        group.isEmpty ? DisplayRepresentation(title: "\(name)") : DisplayRepresentation(title: "\(name)", subtitle: "\(group)")
    }

    @MainActor
    init(job: ScheduledJob) {
        id = job.id
        name = job.name
        group = job.groupName.trimmed
    }
}

/// Text search is required for the Shortcuts task picker (EntityStringQuery).
struct CronTaskQuery: EntityStringQuery {
    @Dependency private var runtime: TaskRuntime

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [CronTaskEntity] {
        runtime.allJobs().filter { identifiers.contains($0.id) }.map(CronTaskEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [CronTaskEntity] {
        runtime.allJobs().filter { TaskSearch.matches($0, query: string) }.map(CronTaskEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [CronTaskEntity] {
        TaskListOrder.name.sorted(runtime.allJobs()).map(CronTaskEntity.init)
    }
}

enum CronIntentError: Error, CustomLocalizedStringResourceConvertible {
    case taskNotFound
    case taskDidNotStart

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .taskNotFound:
            return "Task not found."
        case .taskDidNotStart:
            return "The task did not start: it is already running or has no enabled actions."
        }
    }
}

/// Like "Run now": also runs disabled tasks and while the scheduler is paused.
struct RunCronTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Cron task"
    static let description = IntentDescription("Starts a Cron task. Optionally waits until it finishes and returns its output.")

    @Parameter(title: "Task")
    var task: CronTaskEntity

    @Parameter(title: "Wait for the result", default: false)
    var waitForResult: Bool

    @Dependency private var runtime: TaskRuntime

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let job = runtime.job(withID: task.id), let modelContext = job.modelContext else {
            throw CronIntentError.taskNotFound
        }

        if waitForResult {
            guard let result = await runtime.runAndWait(job, reason: L("Shortcuts")) else {
                throw CronIntentError.taskDidNotStart
            }

            return .result(value: result.output)
        }

        guard !runtime.isRunning(job) else {
            throw CronIntentError.taskDidNotStart
        }

        runtime.runNow(job, modelContext: modelContext)
        return .result(value: "")
    }
}

struct SetCronTaskEnabledIntent: AppIntent {
    static let title: LocalizedStringResource = "Enable or disable Cron task"

    @Parameter(title: "Task")
    var task: CronTaskEntity

    @Parameter(title: "Enabled", default: true)
    var isEnabled: Bool

    @Dependency private var runtime: TaskRuntime

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let job = runtime.job(withID: task.id) else {
            throw CronIntentError.taskNotFound
        }

        runtime.setEnabled(isEnabled, for: job)
        return .result()
    }
}

/// Status, time and output of the task's last run, as text.
struct GetCronTaskLastRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Get last run of Cron task"

    @Parameter(title: "Task")
    var task: CronTaskEntity

    @Dependency private var runtime: TaskRuntime

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let job = runtime.job(withID: task.id) else {
            throw CronIntentError.taskNotFound
        }

        return .result(value: Self.summary(of: job))
    }

    @MainActor
    static func summary(of job: ScheduledJob) -> String {
        guard let run = job.runs.max(by: { $0.startedAt < $1.startedAt }) else {
            return L("No runs yet")
        }

        let time = run.startedAt.formatted(date: .abbreviated, time: .standard)
        let output = run.steps.map(\.output).joined(separator: "\n\n")
        return "\(L(run.outcome.titleKey))\n\(time)\n\(output)"
    }
}

struct SetCronSchedulerPausedIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause or resume Cron scheduler"

    @Parameter(title: "Paused", default: true)
    var isPaused: Bool

    @Dependency private var runtime: TaskRuntime

    @MainActor
    func perform() async throws -> some IntentResult {
        runtime.isSchedulerPaused = isPaused
        return .result()
    }
}
