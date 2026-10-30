import Foundation
import Testing
@testable import Cron

@Suite("Action executor")
struct ExecutorTests {
    private func step<C: StepConfiguration>(_ type: TaskActionType, _ config: C) -> WorkflowStep {
        var step = WorkflowStep(actionType: type, title: type.rawValue)
        step.setConfiguration(config)
        return step
    }

    private func shell(_ script: String, timeout: Double = 0, environment: String = "") -> WorkflowStep {
        var step = step(.shellScript, ShellScriptConfiguration(script: script, workingDirectory: NSTemporaryDirectory(), environment: environment))
        step.timeoutSeconds = timeout
        return step
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CronTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Simple actions

    @Test func specifyTextReturnsText() async {
        let result = await TaskActionExecutor.run(step(.specifyText, TextConfiguration(text: "hello")))
        #expect(result.exitCode == 0)
        #expect(result.output == "hello")
    }

    @Test(arguments: [("a", "a", Int32(0)), ("a", "b", Int32(1))])
    func compareText(first: String, second: String, expected: Int32) async {
        let result = await TaskActionExecutor.run(step(.compareText, CompareTextConfiguration(first: first, second: second)))
        #expect(result.exitCode == expected)
    }

    @Test func checkFileExists() async throws {
        let folder = try temporaryDirectory()

        let present = await TaskActionExecutor.run(step(.checkFileExists, PathConfiguration(path: folder.path)))
        let missing = await TaskActionExecutor.run(step(.checkFileExists, PathConfiguration(path: folder.appendingPathComponent("nope").path)))

        #expect(present.exitCode == 0)
        #expect(missing.exitCode == 1)
    }

    @Test func retrieveCurrentTaskNeedsScheduler() async {
        let result = await TaskActionExecutor.run(WorkflowStep(actionType: .retrieveCurrentTask, title: "Current"))
        #expect(result.exitCode != 0)
    }

    @Test func quitApplicationRequiresExactRunningApp() async {
        let result = await TaskActionExecutor.run(step(.quitApplication, NameConfiguration(name: "No Such App \(UUID().uuidString)")))
        #expect(result.exitCode != 0)
        #expect(result.output.contains("Running application not found"))
    }

    // MARK: Workflow control

    @Test func savePreviousOutputWritesPreviousStep() async throws {
        let file = try temporaryDirectory().appendingPathComponent("out.txt")
        let result = await TaskActionExecutor.runWorkflow([
            step(.specifyText, TextConfiguration(text: "previous output")),
            step(.savePreviousOutput, PathConfiguration(path: file.path))
        ])

        #expect(result.exitCode == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "previous output")
    }

    @Test func stopAndFinishEndTheWorkflow() async {
        let after = step(.specifyText, TextConfiguration(text: "after"))

        let stopped = await TaskActionExecutor.runWorkflow([WorkflowStep(actionType: .stopExecution, title: "Stop"), after])
        let finished = await TaskActionExecutor.runWorkflow([WorkflowStep(actionType: .finishExecution, title: "Finish"), after])

        #expect(stopped.shouldStop && !stopped.output.contains("after"))
        #expect(finished.exitCode == 0 && !finished.output.contains("after"))
    }

    @Test func disabledStepIsSkippedAndUnconfiguredStepFails() async {
        var disabled = step(.specifyText, TextConfiguration(text: "x"))
        disabled.isEnabled = false
        let skipped = await TaskActionExecutor.runWorkflow([disabled])
        #expect(skipped.exitCode == 0 && skipped.output.contains("No enabled"))

        let unconfigured = await TaskActionExecutor.runWorkflow([step(.openURL, URLConfiguration(url: ""))])
        #expect(unconfigured.exitCode == 1 && unconfigured.output.contains("not configured"))
    }

    // MARK: Processes

    @Test func shellScriptSeesEnvironment() async {
        let result = await TaskActionExecutor.run(shell("echo CRON_OK $CRON_TEST", environment: "CRON_TEST=ENV_OK"))
        #expect(result.exitCode == 0)
        #expect(result.output.contains("CRON_OK ENV_OK"))
    }

    @Test(.timeLimit(.minutes(1)))
    func timeLimitStopsScript() async {
        let started = Date()
        let result = await TaskActionExecutor.run(shell("sleep 10", timeout: 1))

        #expect(result.exitCode == ShellScriptRunner.timeoutExitCode)
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test(.timeLimit(.minutes(1)))
    func largeOutputIsTruncatedWithoutBlocking() async {
        let result = await TaskActionExecutor.run(shell("head -c 3000000 /dev/zero | tr '\\0' 'a'; echo; echo DONE >&2", timeout: 30))

        #expect(result.exitCode == 0)
        #expect(result.output.contains("[Output truncated"))
        #expect(result.output.contains("DONE"))
    }

    @Test(.timeLimit(.minutes(1)))
    func stopCancelsWorkflowAndSkipsLaterSteps() async throws {
        let started = Date()
        let task = Task {
            await TaskActionExecutor.runWorkflow([shell("sleep 10"), step(.specifyText, TextConfiguration(text: "after-cancel"))])
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let result = await task.value

        #expect(result.wasCancelled)
        #expect(result.exitCode == ShellScriptRunner.cancelledExitCode)
        #expect(!result.output.contains("after-cancel"))
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test func terminateProcessRefusesItself() async {
        let byName = await TaskActionExecutor.run(step(.terminateProcess, NameConfiguration(name: ProcessInfo.processInfo.processName)))
        let byPID = await TaskActionExecutor.run(step(.terminateProcess, NameConfiguration(name: String(ProcessInfo.processInfo.processIdentifier))))

        #expect(byName.exitCode != 0 && byName.output.contains("Refusing"))
        #expect(byPID.exitCode != 0 && byPID.output.contains("Refusing"))
    }
}
