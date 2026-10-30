import Darwin
import Foundation

nonisolated struct ShellScriptRequest: Sendable {
    var shellPath: String
    var command: String
    var workingDirectory: String
    var environmentText: String
    var timeoutSeconds: Double

    init(shellPath: String = "/bin/zsh", command: String, workingDirectory: String = NSHomeDirectory(), environmentText: String = "", timeoutSeconds: Double = 0) {
        self.shellPath = shellPath
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentText = environmentText
        self.timeoutSeconds = timeoutSeconds
    }

    /// Request for a "Execute shell script" step.
    nonisolated init(step: WorkflowStep) {
        let config = step.configuration(ShellScriptConfiguration.self)
        let selectedShell = config.shellPath.trimmed
        let shell = selectedShell.isEmpty ? "/bin/zsh" : selectedShell
        let scriptCommand: String

        switch config.mode {
        case .inlineScript:
            scriptCommand = config.script
        case .scriptFile:
            let path = config.scriptFile.trimmed
            let arguments = config.arguments.trimmed
            scriptCommand = arguments.isEmpty ? "\(Self.shellQuoted(shell)) \(Self.shellQuoted(path))" : "\(Self.shellQuoted(shell)) \(Self.shellQuoted(path)) \(arguments)"
        }

        self.shellPath = shell
        self.command = scriptCommand
        self.workingDirectory = config.workingDirectory.trimmed
        self.environmentText = config.environment
        self.timeoutSeconds = max(0, step.timeoutSeconds)
    }

    nonisolated var isConfigured: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

nonisolated struct TaskExecutionResult: Sendable {
    var startedAt: Date
    var finishedAt: Date
    var exitCode: Int32
    var output: String
    var shouldStop: Bool = false
    var wasCancelled: Bool = false
    /// Set by condition actions: `false` = condition not met (as opposed to an error running the check).
    var conditionMet: Bool?
    /// The workflow ended early because a condition was not met (`ConditionPolicy.finish`).
    var stoppedByCondition = false
    /// Per-step results when this is the result of a whole workflow.
    var steps: [StepRunResult] = []
}

enum ShellScriptRunner {
    /// Exit code reported when the script exceeded its time limit (same convention as `timeout(1)`).
    nonisolated static let timeoutExitCode: Int32 = 124
    /// Exit code reported when the run was stopped by the user.
    nonisolated static let cancelledExitCode: Int32 = 130

    nonisolated static func run(_ request: ShellScriptRequest) async -> TaskExecutionResult {
        let startedAt = Date()
        var workingDirectoryURL: URL?

        if !request.workingDirectory.isEmpty {
            guard let url = validDirectoryURL(for: request.workingDirectory) else {
                return TaskExecutionResult(
                    startedAt: startedAt,
                    finishedAt: Date(),
                    exitCode: -1,
                    output: "Working directory does not exist or is not a directory: \(request.workingDirectory)"
                )
            }

            workingDirectoryURL = url
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.shellPath.isEmpty ? "/bin/zsh" : request.shellPath)
        process.arguments = ["-lc", request.command]
        process.currentDirectoryURL = workingDirectoryURL
        process.environment = environment(from: request.environmentText)

        let controller = ShellProcessController(process: process)

        if Task.isCancelled {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: cancelledExitCode, output: "Cancelled before start.", wasCancelled: true)
        }

        let outcome = await withTaskCancellationHandler {
            await controller.runToCompletion(timeoutSeconds: request.timeoutSeconds)
        } onCancel: {
            controller.stop(reason: .cancelled)
        }

        var output = outcome.output
        var exitCode = outcome.terminationStatus

        if outcome.launchError != nil {
            exitCode = -1
        }

        switch outcome.stopReason {
        case .timedOut:
            exitCode = timeoutExitCode
            output += "\n[Cron] Script stopped after exceeding the time limit of \(Int(request.timeoutSeconds)) seconds."
        case .cancelled:
            exitCode = cancelledExitCode
            output += "\n[Cron] Script stopped by user."
        case nil:
            break
        }

        return TaskExecutionResult(
            startedAt: startedAt,
            finishedAt: Date(),
            exitCode: exitCode,
            output: output,
            wasCancelled: outcome.stopReason == .cancelled
        )
    }

    nonisolated private static func environment(from text: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let valueStart = line.index(after: separator)
            let value = String(line[valueStart...])

            if !key.isEmpty {
                environment[key] = value
            }
        }

        // Set last, so the values seen by the script are always the workflow's own.
        environment.merge(WorkflowVariables.processEnvironment) { _, workflowValue in workflowValue }
        return environment
    }

    nonisolated private static func validDirectoryURL(for path: String) -> URL? {
        var isDirectory: ObjCBool = false

        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }
}

/// Runs one `Process` without blocking Swift concurrency threads: output is drained by
/// `readabilityHandler` while the process runs and completion is signalled by `terminationHandler`.
/// All mutable state is guarded by `lock`.
nonisolated private final class ShellProcessController: @unchecked Sendable {
    enum StopReason: Equatable {
        case timedOut
        case cancelled
    }

    struct Outcome {
        var output: String
        var terminationStatus: Int32
        var stopReason: StopReason?
        var launchError: Error?
    }

    /// Keeps at most this many bytes of combined stdout/stderr (the tail is kept).
    private static let outputByteLimit = 2_000_000
    /// How long to wait for pipe EOF after the shell exits (background children may keep pipes open).
    private static let drainGracePeriod: TimeInterval = 2
    /// How long SIGTERM gets before SIGKILL.
    private static let killGracePeriod: TimeInterval = 5

    private let process: Process
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()

    private var buffer = Data()
    private var droppedBytes = 0
    private var openStreams = 2
    private var hasTerminated = false
    private var isFinished = false
    private var stopReason: StopReason?
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(process: Process) {
        self.process = process
    }

    func runToCompletion(timeoutSeconds: Double) async -> Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            process.standardOutput = outputPipe
            process.standardError = errorPipe
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                self?.consume(handle)
            }
            process.terminationHandler = { [weak self] _ in
                self?.processDidTerminate()
            }

            do {
                try process.run()
            } catch {
                outputPipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                finish(launchError: error)
                return
            }

            lock.lock()
            let alreadyStopped = stopReason != nil
            lock.unlock()

            if alreadyStopped {
                sendTerminationSignals()
            }

            if timeoutSeconds > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    self?.stop(reason: .timedOut)
                }
            }
        }
    }

    func stop(reason: StopReason) {
        lock.lock()
        let shouldSignal = !isFinished && stopReason == nil
        if shouldSignal {
            stopReason = reason
        }
        let isRunning = process.isRunning
        lock.unlock()

        if shouldSignal, isRunning {
            sendTerminationSignals()
        }
    }

    private func sendTerminationSignals() {
        let pid = process.processIdentifier
        guard pid > 0 else {
            return
        }

        process.terminate()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.killGracePeriod) { [weak self] in
            guard let self, self.process.isRunning else {
                return
            }

            kill(pid, SIGKILL)
        }
    }

    private func consume(_ handle: FileHandle) {
        let data = handle.availableData

        lock.lock()
        if data.isEmpty {
            handle.readabilityHandler = nil
            openStreams -= 1
        } else {
            buffer.append(data)
            if buffer.count > Self.outputByteLimit {
                let overflow = buffer.count - Self.outputByteLimit
                buffer.removeFirst(overflow)
                droppedBytes += overflow
            }
        }
        let canFinish = hasTerminated && openStreams <= 0
        lock.unlock()

        if canFinish {
            finish(launchError: nil)
        }
    }

    private func processDidTerminate() {
        lock.lock()
        hasTerminated = true
        let canFinish = openStreams <= 0
        lock.unlock()

        if canFinish {
            finish(launchError: nil)
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.drainGracePeriod) { [weak self] in
                self?.finish(launchError: nil)
            }
        }
    }

    private func finish(launchError: Error?) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }

        isFinished = true
        self.continuation = nil
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil

        var output = String(decoding: buffer, as: UTF8.self)
        if droppedBytes > 0 {
            output = "[Output truncated: first \(droppedBytes) bytes dropped]\n" + output
        }
        if let launchError {
            output = launchError.localizedDescription
        }

        let outcome = Outcome(
            output: output,
            terminationStatus: launchError == nil ? process.terminationStatus : -1,
            stopReason: stopReason,
            launchError: launchError
        )
        lock.unlock()

        continuation.resume(returning: outcome)
    }
}
