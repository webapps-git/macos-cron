import Foundation
import SwiftData
import Testing
@testable import Cron

@Suite("Run history rules")
struct RunHistoryTests {
    @Test func outputLimitKeepsLastStepsFirst() {
        let steps = (1...3).map { StepRunResult(title: "\($0)", output: String(repeating: "x", count: 60_000)) }
        let capped = RunHistory.cappedSteps(steps, limit: 100_000)

        #expect(capped[2].output.count == 60_000)
        #expect(capped[1].output.hasPrefix("[Output truncated]"))
        #expect(capped[1].output.hasSuffix(String(repeating: "x", count: 40_000)))
        #expect(capped[0].output.hasPrefix("[Output not kept"))
    }

    @Test(arguments: [(3, ["40", "50"]), (2, ["10", "40", "50"])])
    func pruneByAgeAndCount(maxRuns: Int, expected: [String]) {
        let now = Date()
        let runs = [1, 10, 40, 2, 50].map { (id: "\($0)", startedAt: now.addingTimeInterval(-Double($0) * 86_400)) }

        let pruned = RunHistory.runsToPrune(runs, startedAt: \.startedAt, now: now, retentionDays: 30, maxRuns: maxRuns)

        #expect(pruned.map(\.id).sorted() == expected.sorted())
    }
}

@MainActor
@Suite("Run history recording")
struct RunHistoryRecordingTests {
    private func runtime(_ container: ModelContainer, maxRuns: Int = 200) -> TaskRuntime {
        let defaults = UserDefaults(suiteName: "CronTests.\(UUID().uuidString)")!
        defaults.set(maxRuns, forKey: AppSettingsKeys.historyMaxRunsPerTask)
        return TaskRuntime(modelContainer: container, defaults: defaults)
    }

    private func job(_ steps: [WorkflowStep], in container: ModelContainer) -> ScheduledJob {
        let job = ScheduledJob(name: "History")
        job.notificationMode = .never
        job.workflowSteps = steps
        container.mainContext.insert(job)
        return job
    }

    private func waitUntilFinished(_ runtime: TaskRuntime, _ job: ScheduledJob) async throws {
        for _ in 0..<100 where runtime.isRunning(job) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Let the completion code after the workflow run.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func manualRunIsRecordedWithSteps() async throws {
        let container = try makeContainer()
        var step = WorkflowStep(actionType: .specifyText, title: "Say")
        step.setConfiguration(TextConfiguration(text: "hello"))
        let job = job([step], in: container)
        let runtime = runtime(container)

        runtime.runNow(job, modelContext: container.mainContext)
        try await waitUntilFinished(runtime, job)

        let run = try #require(job.runs.first)
        #expect(job.runs.count == 1)
        #expect(run.outcome == .succeeded)
        #expect(run.steps.map(\.output) == ["hello"])
    }

    @Test(.timeLimit(.minutes(1)))
    func timedOutRunIsRecordedAsTimeout() async throws {
        let container = try makeContainer()
        var step = WorkflowStep(actionType: .shellScript, title: "Slow")
        step.setConfiguration(ShellScriptConfiguration(script: "sleep 10", workingDirectory: NSTemporaryDirectory()))
        step.timeoutSeconds = 1
        let job = job([step], in: container)
        let runtime = runtime(container)

        runtime.runNow(job, modelContext: container.mainContext)
        try await waitUntilFinished(runtime, job)

        #expect(job.runs.first?.outcome == .timedOut)
        #expect(job.runs.first?.steps.first?.outcome == .timedOut)
    }

    @Test func pruningKeepsNewestRuns() throws {
        let container = try makeContainer()
        let job = job([], in: container)
        for daysAgo in [3, 2, 1] {
            let start = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            let run = TaskRun(startedAt: start, finishedAt: start, reason: "test", outcome: .succeeded, exitCode: 0, steps: [])
            container.mainContext.insert(run)
            run.job = job
        }

        runtime(container, maxRuns: 2).pruneHistory(of: job, modelContext: container.mainContext)
        try container.mainContext.save()

        #expect(job.runs.count == 2)
    }

    @Test func deletingTaskDeletesHistory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let job = job([], in: container)
        let run = TaskRun(startedAt: Date(), finishedAt: Date(), reason: "test", outcome: .failed, exitCode: 1, steps: [])
        context.insert(run)
        run.job = job
        try context.save()

        context.delete(job)
        try context.save()

        #expect(try context.fetchCount(FetchDescriptor<TaskRun>()) == 0)
    }
}

@MainActor
@Suite("Export, import and duplicate")
struct TaskTransferTests {
    private func sampleJob(in context: ModelContext) -> ScheduledJob {
        let job = ScheduledJob(name: "Backup")
        job.groupName = "Work"
        job.isEnabled = true
        job.scheduleRules = [ScheduleRule(kind: .monthly)]
        job.eventTriggers = [EventTrigger(kind: .systemWake)]
        var step = WorkflowStep(actionType: .sendHTTPRequest, title: "Ping")
        step.setConfiguration(HTTPRequestConfiguration(url: "https://example.org", method: "POST"))
        job.workflowSteps = [step]
        job.runCount = 7
        context.insert(job)
        return job
    }

    @Test func exportAndImportRoundTrip() throws {
        let source = try makeContainer()
        let original = sampleJob(in: source.mainContext)
        let data = try TaskTransfer.exportData([original])

        let target = try makeContainer()
        let imported = try TaskTransfer.importTasks(from: data, into: target.mainContext, existingNames: ["Backup"])
        let job = try #require(imported.first)

        #expect(job.name == "Backup (2)")
        #expect(!job.isEnabled)
        #expect(job.groupName == "Work")
        #expect(job.runCount == 0)
        #expect(job.scheduleRules.map(\.kind) == [.monthly])
        #expect(job.eventTriggers.map(\.kind) == [.systemWake])
        #expect(job.workflowSteps == original.workflowSteps)
    }

    @Test func importRejectsOtherFiles() throws {
        let container = try makeContainer()
        #expect(throws: TaskTransferError.self) {
            try TaskTransfer.importTasks(from: Data(#"{"hello":"world"}"#.utf8), into: container.mainContext, existingNames: [])
        }
    }

    @Test func importIsAllOrNothing() throws {
        let source = try makeContainer()
        let data = try TaskTransfer.exportData([sampleJob(in: source.mainContext)])
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"sendHTTPRequest\"", with: "\"teleport\"")

        let target = try makeContainer()
        #expect(throws: TaskTransferError.self) {
            try TaskTransfer.importTasks(from: Data(text.utf8), into: target.mainContext, existingNames: [])
        }
        #expect(try target.mainContext.fetchCount(FetchDescriptor<ScheduledJob>()) == 0)
    }

    @Test func duplicateIsDisabledCopyWithoutState() throws {
        let container = try makeContainer()
        let original = sampleJob(in: container.mainContext)
        let copy = try TaskTransfer.duplicate(original, existingNames: ["Backup"], copySuffix: "copy")

        #expect(copy.name == "Backup (copy)")
        #expect(!copy.isEnabled)
        #expect(copy.runCount == 0)
        #expect(copy.workflowSteps == original.workflowSteps)
    }

    @Test func searchAndSort() throws {
        let container = try makeContainer()
        let backup = sampleJob(in: container.mainContext)
        let later = ScheduledJob(name: "Alpha")
        later.nextRunAt = Date().addingTimeInterval(3_600)
        container.mainContext.insert(later)

        #expect(TaskSearch.matches(backup, query: "ping"))
        #expect(!TaskSearch.matches(later, query: "ping"))
        #expect(TaskListOrder.name.sorted([backup, later]).map(\.name) == ["Alpha", "Backup"])
        #expect(TaskListOrder.nextRun.sorted([backup, later]).map(\.name) == ["Alpha", "Backup"])
    }
}
