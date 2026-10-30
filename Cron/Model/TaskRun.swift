import Foundation
import SwiftData

nonisolated enum RunOutcome: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
    case timedOut
    /// A condition action was not met; not an error.
    case conditionNotMet

    init(stepResult result: TaskExecutionResult, actionType: TaskActionType) {
        if result.wasCancelled {
            self = .cancelled
        } else if actionType.isCondition, result.conditionMet == false {
            self = .conditionNotMet
        } else if actionType.runsProcess, result.exitCode == ShellScriptRunner.timeoutExitCode {
            self = .timedOut
        } else {
            self = result.exitCode == 0 ? .succeeded : .failed
        }
    }

    /// Outcome of a whole workflow run.
    init(workflowResult result: TaskExecutionResult) {
        // Exit code first: a failed step the workflow continued after does not fail the run.
        if result.wasCancelled {
            self = .cancelled
        } else if result.exitCode == 0 {
            self = result.stoppedByCondition ? .conditionNotMet : .succeeded
        } else if result.steps.last?.outcome == .timedOut {
            self = .timedOut
        } else {
            self = .failed
        }
    }

    var titleKey: String {
        switch self {
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Stopped"
        case .timedOut:
            return "Time limit exceeded"
        case .conditionNotMet:
            return "Condition not met"
        }
    }

    var symbol: String {
        switch self {
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "stop.circle.fill"
        case .timedOut:
            return "timer"
        case .conditionNotMet:
            return "minus.circle.fill"
        }
    }
}

/// Result of one workflow step inside a run.
nonisolated struct StepRunResult: DefaultDecodable, Hashable, Sendable {
    var title = ""
    var actionType = ""
    var outcome = RunOutcome.succeeded
    var startedAt = Date(timeIntervalSinceReferenceDate: 0)
    var duration: TimeInterval = 0
    var exitCode = 0
    var output = ""
    /// Attempts made (more than 1 when the step was retried).
    var attempts = 1
}

/// One execution of a task (run history).
@Model
final class TaskRun {
    var id = UUID()
    var startedAt = Date()
    var finishedAt = Date()
    var reason = ""
    var outcomeRawValue = RunOutcome.succeeded.rawValue
    var exitCode = 0
    var stepsJSON = "[]"
    var job: ScheduledJob?

    init(startedAt: Date, finishedAt: Date, reason: String, outcome: RunOutcome, exitCode: Int, steps: [StepRunResult]) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.reason = reason
        self.outcomeRawValue = outcome.rawValue
        self.exitCode = exitCode
        self.stepsJSON = DefaultDecoding.encodeList(steps)
    }

    var outcome: RunOutcome {
        RunOutcome(rawValue: outcomeRawValue) ?? .failed
    }

    var steps: [StepRunResult] {
        (try? DefaultDecoding.decodeList(StepRunResult.self, from: stepsJSON).get()) ?? []
    }
}
