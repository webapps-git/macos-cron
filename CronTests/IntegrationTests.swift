import Foundation
import SwiftData
import Testing
@testable import Cron

@Suite("Links")
struct URLCommandTests {
    @Test func runByNameOrID() throws {
        let id = UUID()

        #expect(URLCommand.parse(try #require(URL(string: "webapps-cron://run?task=Daily%20Backup"))) == .success(.run(.name("Daily Backup"))))
        #expect(URLCommand.parse(try #require(URL(string: "WEBAPPS-CRON://RUN?task=Backup"))) == .success(.run(.name("Backup"))))
        #expect(URLCommand.parse(try #require(URL(string: "webapps-cron://run?id=\(id.uuidString)"))) == .success(.run(.id(id))))
    }

    @Test func invalidLinksAreRejected() throws {
        #expect(URLCommand.parse(try #require(URL(string: "webapps-cron://delete?task=Backup"))) == .failure(.unknownCommand("delete")))
        #expect(URLCommand.parse(try #require(URL(string: "webapps-cron://run"))) == .failure(.missingTask))
        #expect(URLCommand.parse(try #require(URL(string: "webapps-cron://run?task=%20"))) == .failure(.missingTask))
        #expect(URLCommand.parse(try #require(URL(string: "cron://run?task=Backup"))) == .failure(.wrongScheme))
    }

    @Test func copiedLinkOpensTheSameTask() throws {
        let link = URLCommand.runLink(taskName: "Kopia & zapis łącza")
        #expect(URLCommand.parse(try #require(URL(string: link))) == .success(.run(.name("Kopia & zapis łącza"))))
    }
}

@MainActor
@Suite("Links, Shortcuts and menu bar in the runtime", .serialized)
struct RuntimeIntegrationTests {
    private func runtime(_ container: ModelContainer) -> TaskRuntime {
        TaskRuntime(modelContainer: container, defaults: UserDefaults(suiteName: "CronTests.\(UUID().uuidString)")!)
    }

    private func job(_ name: String, script: String = "echo done", in container: ModelContainer) -> ScheduledJob {
        let job = ScheduledJob(name: name)
        job.notificationMode = .never
        var step = WorkflowStep(actionType: .shellScript, title: "Script")
        step.setConfiguration(ShellScriptConfiguration(script: script, workingDirectory: NSTemporaryDirectory()))
        job.workflowSteps = [step]
        container.mainContext.insert(job)
        return job
    }

    private func waitUntilIdle(_ runtime: TaskRuntime) async throws {
        for _ in 0..<100 where !runtime.runningJobIDs.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test(.timeLimit(.minutes(1)))
    func linkStartsOnlyTasksThatAllowIt() async throws {
        let container = try makeContainer()
        let allowed = job("Allowed", in: container)
        allowed.allowsURLTrigger = true
        let closed = job("Closed", in: container)
        let disabled = job("Disabled", in: container)
        disabled.allowsURLTrigger = true
        disabled.isEnabled = false
        let runtime = runtime(container)
        let jobs = [allowed, closed, disabled]

        func open(_ link: String) throws -> TaskRuntime.URLRunResult {
            runtime.handleURL(try #require(URL(string: link)), jobs: jobs, modelContext: container.mainContext)
        }

        #expect(try open("webapps-cron://run?task=allowed") == .started("Allowed"))
        if case .started = try open("webapps-cron://run?task=Closed") { Issue.record("Closed task accepted a link") }
        if case .started = try open("webapps-cron://run?task=Disabled") { Issue.record("Disabled task started") }
        if case .started = try open("webapps-cron://run?task=Missing") { Issue.record("Missing task started") }

        try await waitUntilIdle(runtime)
        #expect(allowed.runs.count == 1)
        #expect(closed.runs.isEmpty && disabled.runs.isEmpty)

        runtime.isSchedulerPaused = true
        if case .started = try open("webapps-cron://run?task=Allowed") { Issue.record("Link started a task while paused") }
    }

    @Test func linkRejectsAmbiguousNames() throws {
        let container = try makeContainer()
        let first = job("Twin", in: container)
        let second = job("twin", in: container)
        first.allowsURLTrigger = true
        second.allowsURLTrigger = true
        let runtime = runtime(container)

        let result = runtime.handleURL(try #require(URL(string: "webapps-cron://run?task=Twin")), jobs: [first, second], modelContext: container.mainContext)

        #expect(result == .rejected(L("Several tasks have this name.")))
    }

    @Test(.timeLimit(.minutes(1)))
    func runAndWaitReturnsOutputEvenForDisabledTask() async throws {
        let container = try makeContainer()
        let task = job("Report", script: "echo hello-from-shortcuts", in: container)
        task.isEnabled = false
        let runtime = runtime(container)

        let result = try #require(await runtime.runAndWait(task, reason: "Shortcuts"))

        #expect(result.outcome == .succeeded)
        #expect(result.output.contains("hello-from-shortcuts"))
        #expect(GetCronTaskLastRunIntent.summary(of: task).contains("hello-from-shortcuts"))
    }

    @Test(.timeLimit(.minutes(1)))
    func lastFailureIsShownUntilTheTaskSucceeds() async throws {
        let container = try makeContainer()
        let task = job("Flaky", script: "exit 1", in: container)
        let runtime = runtime(container)

        runtime.runNow(task, modelContext: container.mainContext)
        try await waitUntilIdle(runtime)

        let failure = try #require(runtime.lastFailure)
        #expect(failure.jobID == task.id)
        #expect(failure.runID == task.runs.first?.id)
        #expect(runtime.menuBarSymbol == "exclamationmark.triangle.fill")

        var step = WorkflowStep(actionType: .shellScript, title: "Script")
        step.setConfiguration(ShellScriptConfiguration(script: "true", workingDirectory: NSTemporaryDirectory()))
        task.workflowSteps = [step]
        runtime.runNow(task, modelContext: container.mainContext)
        try await waitUntilIdle(runtime)

        #expect(runtime.lastFailure == nil)
        #expect(runtime.menuBarSymbol == "calendar.badge.clock")
    }

    @Test(.timeLimit(.minutes(1)))
    func openingLastFailureRequestsItsHistory() async throws {
        let container = try makeContainer()
        let task = job("Broken", script: "exit 2", in: container)
        let runtime = runtime(container)

        runtime.runNow(task, modelContext: container.mainContext)
        try await waitUntilIdle(runtime)
        runtime.showLastFailure()

        #expect(runtime.lastFailure == nil)
        #expect(runtime.navigationRequest?.jobID == task.id)
        #expect(runtime.navigationRequest?.runID == task.runs.first?.id)
    }

    @Test func pausedSchedulerHasItsOwnIcon() throws {
        let runtime = runtime(try makeContainer())
        runtime.isSchedulerPaused = true
        #expect(runtime.menuBarSymbol == "pause.circle.fill")
    }
}
