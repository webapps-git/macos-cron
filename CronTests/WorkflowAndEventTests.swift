import Foundation
import SwiftData
import Testing
@testable import Cron

private func step<C: StepConfiguration>(_ type: TaskActionType, _ config: C) -> WorkflowStep {
    var step = WorkflowStep(actionType: type, title: type.rawValue)
    step.setConfiguration(config)
    return step
}

private func shell(_ script: String) -> WorkflowStep {
    step(.shellScript, ShellScriptConfiguration(script: script, workingDirectory: NSTemporaryDirectory()))
}

private func text(_ value: String) -> WorkflowStep {
    step(.specifyText, TextConfiguration(text: value))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("CronTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Workflow error handling and conditions")
struct WorkflowPolicyTests {
    @Test func stepSavedBeforePoliciesKeepsOldBehavior() throws {
        let json = #"{"id":"6F0B7D2E-8C1A-4C2B-9C55-2D7F0E7C1A11","type":"specifyText","title":"Old","isEnabled":true,"timeoutSeconds":0,"config":{"text":"x"}}"#
        let decoded = try JSONDecoder().decode(WorkflowStep.self, from: Data(json.utf8))

        #expect(decoded.onError == .stop)
        #expect(decoded.whenConditionNotMet == .finish)
        #expect(decoded.retryCount == 3)
        #expect(decoded.configuration(TextConfiguration.self).text == "x")
    }

    @Test func stopOnErrorIsTheDefault() async {
        let result = await TaskActionExecutor.runWorkflow([shell("exit 3"), text("after")])

        #expect(result.exitCode == 3)
        #expect(!result.output.contains("after"))
        #expect(RunOutcome(workflowResult: result) == .failed)
    }

    @Test func continueOnErrorRunsNextStepAndSucceeds() async {
        var failing = shell("exit 3")
        failing.onError = .continueWorkflow
        let result = await TaskActionExecutor.runWorkflow([failing, text("after")])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("after"))
        #expect(result.steps.map(\.outcome) == [.failed, .succeeded])
        #expect(RunOutcome(workflowResult: result) == .succeeded)
    }

    @Test(.timeLimit(.minutes(1)))
    func retryRepeatsUntilSuccess() async throws {
        let counter = try temporaryDirectory().appendingPathComponent("count").path
        var flaky = shell("n=$(cat '\(counter)' 2>/dev/null || echo 0); n=$((n+1)); echo $n > '\(counter)'; [ $n -ge 3 ]")
        flaky.onError = .retry
        flaky.retryCount = 3
        flaky.retryDelaySeconds = 1
        let result = await TaskActionExecutor.runWorkflow([flaky])

        #expect(result.exitCode == 0)
        #expect(result.steps.first?.attempts == 3)
        #expect(result.output.contains("Attempt 3 of 4"))
    }

    @Test(.timeLimit(.minutes(1)))
    func retryGivesUpAfterTheLastAttempt() async {
        var failing = shell("exit 1")
        failing.onError = .retry
        failing.retryCount = 1
        failing.retryDelaySeconds = 1
        let result = await TaskActionExecutor.runWorkflow([failing, text("after")])

        #expect(result.exitCode == 1)
        #expect(result.steps.first?.attempts == 2)
        #expect(!result.output.contains("after"))
    }

    @Test(arguments: [
        (ConditionPolicy.finish, Int32(0), RunOutcome.conditionNotMet, false),
        (ConditionPolicy.fail, Int32(1), RunOutcome.failed, false),
        (ConditionPolicy.continueWorkflow, Int32(0), RunOutcome.succeeded, true)
    ])
    func unmetCondition(policy: ConditionPolicy, exitCode: Int32, outcome: RunOutcome, runsNextStep: Bool) async {
        var condition = step(.compareText, CompareTextConfiguration(first: "a", second: "b"))
        condition.whenConditionNotMet = policy
        let result = await TaskActionExecutor.runWorkflow([condition, text("after")])

        #expect(result.exitCode == exitCode)
        #expect(RunOutcome(workflowResult: result) == outcome)
        #expect(result.steps.first?.outcome == .conditionNotMet)
        #expect(result.output.contains("after") == runsNextStep)
    }

    @Test func metConditionContinues() async {
        let result = await TaskActionExecutor.runWorkflow([step(.compareText, CompareTextConfiguration(first: "a", second: "a")), text("after")])

        #expect(result.exitCode == 0)
        #expect(result.output.contains("after"))
    }

    @Test func timeMachineStatusIsACondition() {
        let running = "Backup session status:\n{\n    ClientID = \"com.apple.backupd\";\n    Running = 1;\n}"
        let idle = "Backup session status:\n{\n    ClientID = \"com.apple.backupd\";\n    Running = 0;\n}"

        #expect(TaskActionExecutor.timeMachineIsBackingUp(running))
        #expect(!TaskActionExecutor.timeMachineIsBackingUp(idle))
    }
}

@Suite("Workflow variables")
struct WorkflowVariablesTests {
    @Test func placeholdersAreReplaced() throws {
        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 5, second: 30)))
        let variables = WorkflowVariables(taskName: "Backup", date: date, previousOutput: "out", stepOutputs: [1: "one"], file: "/tmp/a.pdf", app: "Safari")

        let result = variables.substitute(in: "{previous}|{task}|{step:1}|{step:9}|{date}|{time}|{file}|{app}|{unknown}|{other:value}|{")

        #expect(result == "out|Backup|one||2026-10-30|14-05-30|/tmp/a.pdf|Safari|{unknown}|{other:value}|{")
    }

    @Test func urlValuesAreEncodedAndScriptsStayUnchanged() {
        let variables = WorkflowVariables(previousOutput: "a b&c")

        let url = variables.applied(to: step(.openURL, URLConfiguration(url: "https://example.org/?q={previous}")))
        let script = variables.applied(to: step(.shellScript, ShellScriptConfiguration(script: "echo {previous}", workingDirectory: "/tmp/{previous}")))
        let shortcut = variables.applied(to: step(.runShortcut, ShortcutConfiguration(name: "{previous}", arguments: "--input {previous}")))

        #expect(url.configuration(URLConfiguration.self).url == "https://example.org/?q=a%20b%26c")
        #expect(script.configuration(ShellScriptConfiguration.self).script == "echo {previous}")
        #expect(script.configuration(ShellScriptConfiguration.self).workingDirectory == "/tmp/a b&c")
        #expect(shortcut.configuration(ShortcutConfiguration.self).name == "a b&c")
        #expect(shortcut.configuration(ShortcutConfiguration.self).arguments == "--input {previous}")
    }

    @Test func workflowPassesOutputsBetweenSteps() async {
        let result = await TaskActionExecutor.runWorkflow([text("hello"), text("{previous} {step:1}!")])

        #expect(result.steps.last?.output == "hello hello!")
    }

    @Test func scriptsGetValuesOnlyAsEnvironment() async {
        // The previous output looks like a command: it must reach the script as data, not code.
        let result = await TaskActionExecutor.runWorkflow([
            text("$(echo injected)"),
            shell("printf '%s|%s|%s' \"$CRON_PREVIOUS_OUTPUT\" \"$CRON_STEP_1_OUTPUT\" '{previous}'")
        ])

        #expect(result.steps.last?.output == "$(echo injected)|$(echo injected)|{previous}")
    }

    @Test func environmentValuesAreCapped() {
        let long = String(repeating: "a", count: 100_000) + "END"
        let outputs = Dictionary(uniqueKeysWithValues: (1...10).map { ($0, long) })
        let environment = WorkflowVariables(previousOutput: long, stepOutputs: outputs).environment

        let previous = environment["CRON_PREVIOUS_OUTPUT"] ?? ""
        let total = environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 }

        #expect(previous.utf8.count == WorkflowVariables.environmentValueLimit)
        #expect(previous.hasSuffix("END"))
        #expect(total <= WorkflowVariables.environmentTotalLimit)
        #expect(environment["CRON_STEP_10_OUTPUT"] != nil)
        #expect(environment["CRON_STEP_1_OUTPUT"] == nil)
    }
}

@Suite("Event triggers")
struct EventTriggerTests {
    @Test func folderTriggerMatchesFolderPatternAndChange() throws {
        let root = FolderPath.normalized(try temporaryDirectory().path)
        var trigger = EventTrigger(kind: .folder)
        trigger.folderPath = root
        trigger.namePattern = "*.pdf, *.JPG"

        func file(_ path: String, _ change: FileChange = .created) -> EventOccurrence {
            EventOccurrence(kind: .folder, detail: .file(path: path, change: change))
        }

        #expect(trigger.matches(file("\(root)/a.pdf")))
        #expect(trigger.matches(file("\(root)/photo.jpg")))
        #expect(!trigger.matches(file("\(root)/a.txt")))
        #expect(!trigger.matches(file("\(root)/sub/a.pdf")))
        #expect(!trigger.matches(file("\(root)/a.pdf", .modified)))
        #expect(!trigger.matches(file("\(root)-other/a.pdf")))

        trigger.includeSubfolders = true
        trigger.onModified = true
        #expect(trigger.matches(file("\(root)/sub/a.pdf")))
        #expect(trigger.matches(file("\(root)/a.pdf", .modified)))
    }

    @Test func applicationTriggerMatchesBundleIDOrName() {
        var trigger = EventTrigger(kind: .application)
        trigger.appName = "Safari"
        trigger.appBundleID = "com.apple.Safari"

        func app(_ bundleID: String, _ name: String, launched: Bool = true) -> EventOccurrence {
            EventOccurrence(kind: .application, detail: .application(bundleID: bundleID, name: name, launched: launched))
        }

        #expect(trigger.matches(app("com.apple.Safari", "Safari")))
        #expect(!trigger.matches(app("com.apple.Safari", "Safari", launched: false)))
        #expect(!trigger.matches(app("com.example.Safari", "Safari")))

        trigger.appBundleID = ""
        trigger.onQuit = true
        #expect(trigger.matches(app("any.id", "safari", launched: false)))
    }

    @Test(arguments: [(25, 19, true), (19, 18, false), (21, 20, false), (20, 19, true)])
    func batteryTriggerFiresOnceWhenCrossingDown(previous: Int, current: Int, fires: Bool) {
        let trigger = EventTrigger(kind: .batteryLow)
        #expect(trigger.matches(EventOccurrence(kind: .batteryLow, detail: .battery(previous: previous, current: current))) == fires)
    }

    @Test func idleTriggerFiresAtThresholdAndOnReturn() {
        var trigger = EventTrigger(kind: .idle)
        trigger.idleMinutes = 10

        func idle(_ previous: TimeInterval, _ current: TimeInterval) -> EventOccurrence {
            EventOccurrence(kind: .idle, detail: .idle(previous: previous, current: current))
        }

        #expect(trigger.matches(idle(590, 600)))
        #expect(!trigger.matches(idle(600, 700)))
        #expect(!trigger.matches(idle(700, 3)))

        trigger.onIdleEnd = true
        #expect(trigger.matches(idle(700, 3)))
        #expect(!trigger.matches(idle(300, 3)))
    }

    @Test func otherTaskTriggerFiltersTaskAndResult() {
        var trigger = EventTrigger(kind: .otherTaskFinished)
        trigger.taskNames = ["Backup"]
        trigger.taskOutcome = .failed

        func finished(_ name: String, _ outcome: RunOutcome) -> EventOccurrence {
            EventOccurrence(kind: .otherTaskFinished, detail: .task(name: name, outcome: outcome))
        }

        #expect(trigger.matches(finished("backup", .timedOut)))
        #expect(!trigger.matches(finished("Backup", .succeeded)))
        #expect(!trigger.matches(finished("Other", .failed)))

        trigger.taskNames = []
        trigger.taskOutcome = .succeeded
        #expect(trigger.matches(finished("Other", .conditionNotMet)))
    }

    @Test func triggerSavedBeforeParametersDecodes() throws {
        let json = #"[{"id":"6F0B7D2E-8C1A-4C2B-9C55-2D7F0E7C1A11","kind":"systemWake"}]"#
        let triggers = try DefaultDecoding.decodeList(EventTrigger.self, from: json).get()

        #expect(triggers.map(\.kind) == [.systemWake])
        #expect(triggers.first?.matches(EventOccurrence(kind: .systemWake)) == true)
    }
}

@MainActor
@Suite("Folder events", .serialized)
struct FolderEventTests {
    private func waitFor(_ condition: () -> Bool, seconds: Double = 10) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func watcherReportsCreatedAndRemovedFiles() async throws {
        let root = FolderPath.normalized(try temporaryDirectory().path)
        var changes: [(String, FileChange)] = []
        let watcher = FolderWatcher(root: root) { path, change in changes.append((path, change)) }
        #expect(watcher.start())
        defer { watcher.stop() }

        let file = "\(root)/report.pdf"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        try await waitFor { changes.contains { $0 == (file, .created) } }
        try FileManager.default.removeItem(atPath: file)
        try await waitFor { changes.contains { $0 == (file, .removed) } }

        #expect(changes.contains { $0 == (file, .created) })
        #expect(changes.contains { $0 == (file, .removed) })
    }

    @Test(.timeLimit(.minutes(1)))
    func stableFileIsReportedAndMissingFileIsNot() async throws {
        let file = try temporaryDirectory().appendingPathComponent("done.txt")
        try Data("x".utf8).write(to: file)

        #expect(await FileStability.waitUntilStable(file.path, quietSeconds: 1))
        #expect(!(await FileStability.waitUntilStable(file.path + "-missing", quietSeconds: 1)))
    }

    @Test(.timeLimit(.minutes(1)))
    func filesArrivingDuringARunWaitAndGetFileVariable() async throws {
        let container = try makeContainer()
        let root = FolderPath.normalized(try temporaryDirectory().path)
        let job = ScheduledJob(name: "Inbox")
        job.notificationMode = .never
        var trigger = EventTrigger(kind: .folder)
        trigger.folderPath = root
        trigger.waitUntilStable = false
        job.eventTriggers = [trigger]
        job.workflowSteps = [text("{file}"), shell("sleep 1")]
        container.mainContext.insert(job)

        let defaults = UserDefaults(suiteName: "CronTests.\(UUID().uuidString)")!
        let runtime = TaskRuntime(modelContainer: container, defaults: defaults)

        for name in ["a.txt", "b.txt"] {
            runtime.trigger(EventOccurrence(kind: .folder, detail: .file(path: "\(root)/\(name)", change: .created)), jobs: [job], modelContext: container.mainContext)
        }

        try await waitFor({ job.runs.count == 2 && !runtime.isRunning(job) }, seconds: 20)

        let outputs = job.runs.compactMap { $0.steps.first?.output }.sorted()
        #expect(outputs == ["\(root)/a.txt", "\(root)/b.txt"])
    }

    @Test(.timeLimit(.minutes(1)))
    func failedTaskStartsTaskWaitingForItsError() async throws {
        let container = try makeContainer()
        let failing = ScheduledJob(name: "Backup")
        failing.notificationMode = .never
        failing.workflowSteps = [shell("exit 1")]
        let follower = ScheduledJob(name: "Alert")
        follower.notificationMode = .never
        var trigger = EventTrigger(kind: .otherTaskFinished)
        trigger.taskNames = ["Backup"]
        trigger.taskOutcome = .failed
        follower.eventTriggers = [trigger]
        follower.workflowSteps = [text("ok")]
        container.mainContext.insert(failing)
        container.mainContext.insert(follower)

        let defaults = UserDefaults(suiteName: "CronTests.\(UUID().uuidString)")!
        let runtime = TaskRuntime(modelContainer: container, defaults: defaults)
        runtime.runNow(failing, modelContext: container.mainContext)

        try await waitFor { follower.runs.count == 1 && !runtime.isRunning(follower) }

        #expect(failing.runs.first?.outcome == .failed)
        #expect(follower.runs.count == 1)
    }
}
