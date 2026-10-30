import Foundation

/// Rules for storing and pruning run history.
nonisolated enum RunHistory {
    static let defaultRetentionDays = 30
    static let defaultMaxRunsPerTask = 200
    /// Total output kept per run, in characters.
    static let outputLimit = 100_000

    /// Limits the combined output of all steps to `limit` characters. The last steps keep their
    /// output first (that is usually where an error is), and each output keeps its end.
    static func cappedSteps(_ steps: [StepRunResult], limit: Int = outputLimit) -> [StepRunResult] {
        var remaining = limit
        var result = steps

        for index in result.indices.reversed() {
            let output = result[index].output

            if output.count <= remaining {
                remaining -= output.count
            } else if remaining > 0 {
                result[index].output = "[Output truncated]\n" + String(output.suffix(remaining))
                remaining = 0
            } else {
                result[index].output = output.isEmpty ? "" : "[Output not kept: run output limit reached]"
            }
        }

        return result
    }

    /// Runs to delete: older than `retentionDays`, and beyond the newest `maxRuns`.
    static func runsToPrune<Run>(_ runs: [Run], startedAt: (Run) -> Date, now: Date, retentionDays: Int, maxRuns: Int) -> [Run] {
        let cutoff = now.addingTimeInterval(-TimeInterval(max(1, retentionDays)) * 86_400)
        let newestFirst = runs.sorted { startedAt($0) > startedAt($1) }

        return newestFirst.enumerated()
            .filter { index, run in index >= max(1, maxRuns) || startedAt(run) < cutoff }
            .map(\.element)
    }

    static func retentionDays(in defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: AppSettingsKeys.historyRetentionDays)
        return value > 0 ? value : defaultRetentionDays
    }

    static func maxRunsPerTask(in defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: AppSettingsKeys.historyMaxRunsPerTask)
        return value > 0 ? value : defaultMaxRunsPerTask
    }
}
