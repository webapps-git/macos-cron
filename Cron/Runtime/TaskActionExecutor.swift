import AppKit
import AVFoundation
import CoreAudio
import Darwin
import Foundation
import UserNotifications

/// Scheduler services available to a workflow started by `TaskRuntime`.
struct WorkflowContext: Sendable {
    var jobName: String
    /// The event that started the run (`{file}`, `{app}`), if any.
    var event: EventOccurrence?
    var handleTaskAction: @MainActor @Sendable (TaskActionType, [String]) -> TaskExecutionResult
}

enum TaskActionExecutor {
    @concurrent
    nonisolated static func runWorkflow(_ steps: [WorkflowStep], context: WorkflowContext? = nil) async -> TaskExecutionResult {
        let startedAt = Date()
        var outputChunks: [String] = []
        var stepResults: [StepRunResult] = []
        var variables = WorkflowVariables(
            taskName: context?.jobName ?? "",
            date: startedAt,
            file: context?.event?.file ?? "",
            app: context?.event?.app ?? ""
        )

        func finish(exitCode: Int32, shouldStop: Bool = false, wasCancelled: Bool = false, stoppedByCondition: Bool = false) -> TaskExecutionResult {
            TaskExecutionResult(
                startedAt: startedAt,
                finishedAt: Date(),
                exitCode: exitCode,
                output: outputChunks.isEmpty ? "No enabled workflow actions." : outputChunks.joined(separator: "\n\n"),
                shouldStop: shouldStop,
                wasCancelled: wasCancelled,
                stoppedByCondition: stoppedByCondition,
                steps: stepResults
            )
        }

        for (index, step) in steps.enumerated() where step.isEnabled {
            if Task.isCancelled {
                outputChunks.append("[Cron] Workflow stopped by user.")
                return finish(exitCode: ShellScriptRunner.cancelledExitCode, shouldStop: true, wasCancelled: true)
            }

            guard step.isConfigured else {
                let message = "Action is enabled but not configured."
                outputChunks.append("[\(index + 1)] \(step.title)\n\(message)")
                stepResults.append(StepRunResult(title: step.title, actionType: step.actionType.rawValue, outcome: .failed, startedAt: Date(), duration: 0, exitCode: 1, output: message))
                return finish(exitCode: 1)
            }

            let (result, attempts) = await runWithRetries(step, variables: variables, context: context)
            outputChunks.append("[\(index + 1)] \(step.title)\n\(result.output)")
            stepResults.append(StepRunResult(
                title: step.title,
                actionType: step.actionType.rawValue,
                outcome: RunOutcome(stepResult: result, actionType: step.actionType),
                startedAt: result.startedAt,
                duration: result.finishedAt.timeIntervalSince(result.startedAt),
                exitCode: Int(result.exitCode),
                output: result.output,
                attempts: attempts
            ))
            variables.previousOutput = result.output
            variables.stepOutputs[index + 1] = result.output

            if result.wasCancelled || Task.isCancelled {
                return finish(exitCode: ShellScriptRunner.cancelledExitCode, shouldStop: true, wasCancelled: true)
            }

            if isConditionNotMet(result, step) {
                switch step.whenConditionNotMet {
                case .finish:
                    return finish(exitCode: 0, shouldStop: true, stoppedByCondition: true)
                case .fail:
                    return finish(exitCode: 1)
                case .continueWorkflow:
                    continue
                }
            }

            if result.shouldStop {
                return finish(exitCode: result.exitCode, shouldStop: true)
            }

            if result.exitCode != 0 {
                if step.onError == .continueWorkflow {
                    continue
                }

                return finish(exitCode: result.exitCode)
            }
        }

        return finish(exitCode: 0)
    }

    /// Runs the step with placeholders filled in and its `CRON_*` variables set, retrying failed
    /// attempts when the step asks for it. Returns the last attempt and the number of attempts.
    nonisolated private static func runWithRetries(_ step: WorkflowStep, variables: WorkflowVariables, context: WorkflowContext?) async -> (TaskExecutionResult, Int) {
        let prepared = variables.applied(to: step)
        let maximumAttempts = step.onError == .retry ? 1 + min(max(step.retryCount, 0), WorkflowStep.retryCountRange.upperBound) : 1
        let delay = min(max(step.retryDelaySeconds, WorkflowStep.retryDelayRange.lowerBound), WorkflowStep.retryDelayRange.upperBound)
        let environment = variables.environment

        func attempt() async -> TaskExecutionResult {
            await WorkflowVariables.$processEnvironment.withValue(environment) {
                await run(prepared, previousOutput: variables.previousOutput, context: context)
            }
        }

        var result = await attempt()
        var attempts = 1

        while attempts < maximumAttempts && isFailure(result, step) && !result.wasCancelled && !Task.isCancelled {
            do {
                // Stop cancels the wait as well.
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                break
            }

            result = await attempt()
            attempts += 1
        }

        if attempts > 1 {
            result.output = "[Cron] Attempt \(attempts) of \(maximumAttempts)\n\(result.output)"
        }

        return (result, attempts)
    }

    nonisolated private static func isConditionNotMet(_ result: TaskExecutionResult, _ step: WorkflowStep) -> Bool {
        step.actionType.isCondition && result.conditionMet == false
    }

    /// An error, as opposed to success, an unmet condition or a stop/finish action.
    nonisolated private static func isFailure(_ result: TaskExecutionResult, _ step: WorkflowStep) -> Bool {
        result.exitCode != 0 && !result.shouldStop && !isConditionNotMet(result, step)
    }

    nonisolated static func run(_ step: WorkflowStep, previousOutput: String = "", context: WorkflowContext? = nil) async -> TaskExecutionResult {
        switch step.actionType {
        case .shellScript:
            return await ShellScriptRunner.run(ShellScriptRequest(step: step))
        case .openURL:
            let target = step.configuration(URLConfiguration.self).url.trimmed
            return await runMainActorAction {
                guard let url = URL(string: target), url.scheme != nil else {
                    throw TaskActionError.invalidURL(target)
                }

                guard NSWorkspace.shared.open(url) else {
                    throw TaskActionError.openFailed(target)
                }

                return "Opened URL: \(target)"
            }
        case .openItem:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runMainActorAction {
                let url = URL(fileURLWithPath: path)

                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TaskActionError.pathNotFound(url.path)
                }

                guard NSWorkspace.shared.open(url) else {
                    throw TaskActionError.openFailed(url.path)
                }

                return "Opened item: \(url.path)"
            }
        case .quitApplication:
            let config = step.configuration(NameConfiguration.self)
            let name = config.name.trimmed
            return await runMainActorAction {
                // Exact name or bundle identifier only: a substring match could quit the wrong app
                // ("Code" would also match "Xcode"). No force quit, so the app can save its work.
                let query = name
                let ownPID = ProcessInfo.processInfo.processIdentifier
                let matches = NSWorkspace.shared.runningApplications.filter { app in
                    app.processIdentifier != ownPID
                        && (app.bundleIdentifier == query
                            || app.localizedName?.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame)
                }

                guard !matches.isEmpty else {
                    throw TaskActionError.applicationNotFound(query)
                }

                let refused = matches.filter { !$0.terminate() }
                guard refused.isEmpty else {
                    throw TaskActionError.quitFailed(query)
                }

                return "Quit application: \(matches.compactMap(\.localizedName).joined(separator: ", "))"
            }
        case .compressItem:
            let config = step.configuration(TransferConfiguration.self)
            let destination = config.destination.trimmed
            let source = config.source.trimmed
            return await ShellScriptRunner.run(ShellScriptRequest(command: "ditto -c -k --sequesterRsrc --keepParent \(shellQuoted(source)) \(shellQuoted(destination))"))
        case .convertLineEndings:
            let config = step.configuration(TransferConfiguration.self)
            let destination = config.destination.trimmed
            let source = config.source.trimmed
            return await runDetachedAction {
                let source = URL(fileURLWithPath: source)
                let destination = URL(fileURLWithPath: destination)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw TaskActionError.pathNotFound(source.path)
                }

                let text = try String(contentsOf: source, encoding: .utf8)
                let converted = text
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                try converted.write(to: destination, atomically: true, encoding: .utf8)
                return "Converted line endings: \(destination.path)"
            }
        case .copyItem:
            let config = step.configuration(TransferConfiguration.self)
            let destination = config.destination.trimmed
            let source = config.source.trimmed
            return await runDetachedAction {
                let source = URL(fileURLWithPath: source)
                var destination = URL(fileURLWithPath: destination)
                var isDirectory: ObjCBool = false

                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw TaskActionError.pathNotFound(source.path)
                }

                if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    destination.appendPathComponent(source.lastPathComponent)
                }

                try FileManager.default.copyItem(at: source, to: destination)
                return "Copied \(source.path) to \(destination.path)"
            }
        case .createFolder:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runDetachedAction {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return "Created folder: \(url.path)"
            }
        case .decompressItem:
            let config = step.configuration(TransferConfiguration.self)
            let destination = config.destination.trimmed
            let source = config.source.trimmed
            return await ShellScriptRunner.run(ShellScriptRequest(command: "mkdir -p \(shellQuoted(destination)) && ditto -x -k \(shellQuoted(source)) \(shellQuoted(destination))"))
        case .deleteItem:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runDetachedAction {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TaskActionError.pathNotFound(url.path)
                }

                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
                return "Moved to trash: \(url.path)"
            }
        case .emptyTrash:
            return await ShellScriptRunner.run(ShellScriptRequest(command: "osascript -e 'tell application \"Finder\" to empty trash'"))
        case .lockItem:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await ShellScriptRunner.run(ShellScriptRequest(command: "chflags uchg \(shellQuoted(path))"))
        case .moveItem:
            let config = step.configuration(TransferConfiguration.self)
            let destination = config.destination.trimmed
            let source = config.source.trimmed
            return await runDetachedAction {
                let source = URL(fileURLWithPath: source)
                var destination = URL(fileURLWithPath: destination)
                var isDirectory: ObjCBool = false

                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw TaskActionError.pathNotFound(source.path)
                }

                if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    destination.appendPathComponent(source.lastPathComponent)
                }

                try FileManager.default.moveItem(at: source, to: destination)
                return "Moved \(source.path) to \(destination.path)"
            }
        case .printItem:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await ShellScriptRunner.run(ShellScriptRequest(command: "lp \(shellQuoted(path))"))
        case .renameItem:
            let config = step.configuration(RenameConfiguration.self)
            let newName = config.newName.trimmed
            let path = config.path.trimmed
            return await runDetachedAction {
                let source = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw TaskActionError.pathNotFound(source.path)
                }

                let destination = source.deletingLastPathComponent().appendingPathComponent(newName)
                try FileManager.default.moveItem(at: source, to: destination)
                return "Renamed \(source.path) to \(destination.lastPathComponent)"
            }
        case .replaceTextInFile:
            let config = step.configuration(ReplaceTextConfiguration.self)
            let find = config.find
            let path = config.path.trimmed
            let replacement = config.replacement
            return await runDetachedAction {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TaskActionError.pathNotFound(url.path)
                }

                let text = try String(contentsOf: url, encoding: .utf8)
                let replaced = text.replacingOccurrences(of: find, with: replacement)
                try replaced.write(to: url, atomically: true, encoding: .utf8)
                return "Replaced text in: \(url.path)"
            }
        case .retrieveFolderContents:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runDetachedAction {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TaskActionError.pathNotFound(url.path)
                }

                let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return contents.isEmpty ? "Folder is empty: \(url.path)" : contents.joined(separator: "\n")
            }
        case .retrieveHomeDirectory:
            let now = Date()
            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 0, output: NSHomeDirectory())
        case .retrieveVolumes:
            return await runDetachedAction {
                let volumes = try FileManager.default.contentsOfDirectory(atPath: "/Volumes")
                return volumes.isEmpty ? "No mounted volumes." : volumes.joined(separator: "\n")
            }
        case .unlockItem:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await ShellScriptRunner.run(ShellScriptRequest(command: "chflags nouchg \(shellQuoted(path))"))
        case .writeTextFile:
            let config = step.configuration(WriteTextConfiguration.self)
            let path = config.path.trimmed
            let text = config.text
            return await runDetachedAction {
                let url = URL(fileURLWithPath: path)
                let parent = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                return "Wrote \(text.count) characters to: \(url.path)"
            }
        case .speakText:
            let config = step.configuration(TextConfiguration.self)
            let text = config.text.trimmed
            return await runMainActorAction {
                SpeechActionSpeaker.shared.speak(text)
                return "Speaking text: \(text)"
            }
        case .playAudioFile:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runMainActorAction {
                let url = URL(fileURLWithPath: path)
                guard let sound = NSSound(contentsOf: url, byReference: true) else {
                    throw TaskActionError.openFailed(url.path)
                }

                sound.play()
                return "Playing audio file: \(url.path)"
            }
        case .playAlertSound:
            return await runMainActorAction {
                NSSound.beep()
                return "Played alert sound."
            }
        case .checkInternet:
            return await checkInternetConnection()
        case .timeMachineStatus:
            var result = await ShellScriptRunner.run(ShellScriptRequest(command: "tmutil status"))
            if result.exitCode == 0 {
                let isRunning = timeMachineIsBackingUp(result.output)
                result.conditionMet = isRunning
                result.exitCode = isRunning ? 0 : 1
            }
            return result
        case .startTimeMachineBackup:
            return await ShellScriptRunner.run(ShellScriptRequest(command: "tmutil startbackup --auto"))
        case .stopTimeMachineBackup:
            return await ShellScriptRunner.run(ShellScriptRequest(command: "tmutil stopbackup"))
        case .sleepComputer:
            return await ShellScriptRunner.run(ShellScriptRequest(command: "pmset sleepnow"))
        case .restartComputer:
            return await ShellScriptRunner.run(ShellScriptRequest(command: "osascript -e 'tell application \"System Events\" to restart'"))
        case .shutdownComputer:
            return await ShellScriptRunner.run(ShellScriptRequest(command: "osascript -e 'tell application \"System Events\" to shut down'"))
        case .retrieveDate:
            let now = Date().formatted(date: .abbreviated, time: .standard)
            return TaskExecutionResult(startedAt: Date(), finishedAt: Date(), exitCode: 0, output: now)
        case .compareText:
            let config = step.configuration(CompareTextConfiguration.self)
            let first = config.first
            let second = config.second
            let now = Date()
            let isEqual = first == second
            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: isEqual ? 0 : 1, output: isEqual ? "Strings are equal." : "Strings are different.", conditionMet: isEqual)
        case .specifyText:
            let config = step.configuration(TextConfiguration.self)
            let text = config.text.trimmed
            let now = Date()
            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 0, output: text)
        case .displayTextInputDialog:
            let config = step.configuration(TextConfiguration.self)
            let text = config.text.trimmed
            return await runMainActorAction {
                let alert = NSAlert()
                let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
                alert.messageText = text
                alert.accessoryView = input
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                let response = alert.runModal()
                return response == .alertFirstButtonReturn ? input.stringValue : ""
            }
        case .displayFileSelectionDialog:
            return await runMainActorAction {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                return panel.runModal() == .OK ? (panel.url?.path ?? "") : ""
            }
        case .takeScreenshot:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await ShellScriptRunner.run(ShellScriptRequest(command: "screencapture -x \(shellQuoted(path))"))
        case .setDesktopBackground:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runMainActorAction {
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw TaskActionError.pathNotFound(url.path)
                }

                for screen in NSScreen.screens {
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen)
                }

                return "Set desktop background image: \(url.path)"
            }
        case .retrieveOSName:
            let osNameStartedAt = Date()
            return TaskExecutionResult(startedAt: osNameStartedAt, finishedAt: Date(), exitCode: 0, output: "macOS")
        case .retrieveOSVersion:
            let versionStartedAt = Date()
            return TaskExecutionResult(startedAt: versionStartedAt, finishedAt: Date(), exitCode: 0, output: ProcessInfo.processInfo.operatingSystemVersionString)
        case .checkTasksRunning, .deleteTasks, .disableTasks, .enableTasks, .executeTasks, .stopTasks, .pauseScheduler, .resumeScheduler:
            let names = step.configuration(TaskNamesConfiguration.self).names.map(\.trimmed).filter { !$0.isEmpty }
            let actionType = step.actionType

            guard let context else {
                let now = Date()
                if actionType == .checkTasksRunning {
                    return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 0, output: "Task runtime is active.", conditionMet: true)
                }

                return TaskExecutionResult(
                    startedAt: now,
                    finishedAt: now,
                    exitCode: 1,
                    output: "Task management action requires scheduler context for task: \(names.joined(separator: ", "))"
                )
            }

            var result = await MainActor.run {
                context.handleTaskAction(actionType, names)
            }
            if actionType == .checkTasksRunning {
                result.conditionMet = result.exitCode == 0
            }
            return result
        case .retrieveCurrentTask:
            let now = Date()
            guard let context else {
                return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 1, output: "Current task is only known when the workflow is run by the scheduler.")
            }

            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 0, output: context.jobName)
        case .pauseExecution:
            let config = step.configuration(DurationConfiguration.self)
            let seconds = config.seconds
            return await pause(seconds: seconds)
        case .stopExecution:
            let now = Date()
            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 0, output: "Workflow stopped.", shouldStop: true)
        case .finishExecution:
            let now = Date()
            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 0, output: "Workflow finished.", shouldStop: true)
        case .displayDialog:
            let config = step.configuration(TextConfiguration.self)
            let text = config.text.trimmed
            return await runMainActorAction {
                let alert = NSAlert()
                alert.messageText = text
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return "Displayed dialog: \(text)"
            }
        case .retrieveEnvironmentVariable:
            let config = step.configuration(NameConfiguration.self)
            let name = config.name.trimmed
            let now = Date()
            let value = ProcessInfo.processInfo.environment[name] ?? ""
            return TaskExecutionResult(
                startedAt: now,
                finishedAt: Date(),
                exitCode: value.isEmpty ? 1 : 0,
                output: value.isEmpty ? "Environment variable not found: \(name)" : "\(name)=\(value)"
            )
        case .executeAppleScript:
            let config = step.configuration(AppleScriptConfiguration.self)
            let script = config.script
            return await ShellScriptRunner.run(ShellScriptRequest(command: "printf %s \(shellQuoted(script)) | /usr/bin/osascript", timeoutSeconds: step.timeoutSeconds))
        case .runShortcut:
            let config = step.configuration(ShortcutConfiguration.self)
            let arguments = config.arguments
            let name = config.name.trimmed
            var command = "/usr/bin/shortcuts run \(shellQuoted(name))"
            if !arguments.isEmpty {
                command += " \(arguments)"
            }
            return await ShellScriptRunner.run(ShellScriptRequest(command: command, timeoutSeconds: step.timeoutSeconds))
        case .showNotification:
            let config = step.configuration(NotificationConfiguration.self)
            let body = config.body
            let title = config.title.trimmed
            return await showNotification(title: title.isEmpty ? "Cron" : title, body: body)
        case .sendHTTPRequest:
            return await sendHTTPRequest(step.configuration(HTTPRequestConfiguration.self))
        case .checkFileExists:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            let now = Date()
            let exists = FileManager.default.fileExists(atPath: path)
            return TaskExecutionResult(
                startedAt: now,
                finishedAt: Date(),
                exitCode: exists ? 0 : 1,
                output: exists ? "Path exists: \(path)" : "Path does not exist: \(path)",
                conditionMet: exists
            )
        case .waitForFile:
            let config = step.configuration(WaitForFileConfiguration.self)
            let path = config.path.trimmed
            let timeoutSeconds = config.timeoutSeconds
            return await waitForPath(path, timeout: timeoutSeconds)
        case .checkProcessRunning:
            let config = step.configuration(NameConfiguration.self)
            let name = config.name.trimmed
            return await checkProcessRunning(name)
        case .terminateProcess:
            let config = step.configuration(NameConfiguration.self)
            let name = config.name.trimmed
            return await terminateProcess(name)
        case .getClipboardText:
            return await runMainActorAction {
                NSPasteboard.general.string(forType: .string) ?? ""
            }
        case .setClipboardText:
            let config = step.configuration(TextConfiguration.self)
            let text = config.text.trimmed
            return await runMainActorAction {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return "Wrote \(text.count) characters to clipboard."
            }
        case .savePreviousOutput:
            let config = step.configuration(PathConfiguration.self)
            let path = config.path.trimmed
            return await runDetachedAction {
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try previousOutput.write(to: url, atomically: true, encoding: .utf8)
                return "Saved previous output to: \(url.path)"
            }
        case .volumeControl:
            let config = step.configuration(VolumeConfiguration.self)
            let operation = config.operation
            let amount = min(max(config.amount.rounded(), operation.amountRange.lowerBound), operation.amountRange.upperBound)
            return await runDetachedAction {
                try SystemOutputVolume.apply(operation: operation, amount: amount)
            }
        }
    }

    private nonisolated static func runMainActorAction(_ action: @escaping @MainActor () throws -> String) async -> TaskExecutionResult {
        let startedAt = Date()

        do {
            let output = try await MainActor.run {
                try action()
            }

            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 0, output: output)
        } catch {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: -1, output: error.localizedDescription)
        }
    }

    @concurrent
    private nonisolated static func runDetachedAction(_ action: @escaping @Sendable () throws -> String) async -> TaskExecutionResult {
        let startedAt = Date()

        do {
            let output = try action()
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 0, output: output)
        } catch {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: -1, output: error.localizedDescription)
        }
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// `tmutil status` prints `Running = 1;` while a backup is in progress.
    nonisolated static func timeMachineIsBackingUp(_ status: String) -> Bool {
        status.range(of: #"\bRunning\s*=\s*1\s*;"#, options: .regularExpression) != nil
    }

    private nonisolated static func checkInternetConnection() async -> TaskExecutionResult {
        let startedAt = Date()

        do {
            var request = URLRequest(url: URL(string: "https://www.apple.com/library/test/success.html")!)
            request.timeoutInterval = 8
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if (200..<400).contains(statusCode) {
                return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 0, output: "Internet connection is available.", conditionMet: true)
            }

            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: "Unexpected HTTP status: \(statusCode)", conditionMet: false)
        } catch {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: error.localizedDescription, conditionMet: false)
        }
    }

    private nonisolated static func sendHTTPRequest(_ config: HTTPRequestConfiguration) async -> TaskExecutionResult {
        let startedAt = Date()
        let address = config.url.trimmed
        let method = config.method.trimmed

        guard let url = URL(string: address), url.scheme != nil else {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: "Invalid URL: \(address)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = max(1, min(config.timeoutSeconds, 300))
        urlRequest.httpMethod = method.isEmpty ? "GET" : method.uppercased()

        let headerLines = config.headers
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        for line in headerLines {
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        if !config.body.isEmpty {
            urlRequest.httpBody = Data(config.body.utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let output = "HTTP \(statusCode)\n\(body)"
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: (200..<400).contains(statusCode) ? 0 : 1, output: output)
        } catch {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: error.localizedDescription)
        }
    }

    private nonisolated static func waitForPath(_ path: String, timeout: Double) async -> TaskExecutionResult {
        let startedAt = Date()
        let deadline = Date().addingTimeInterval(max(0.1, min(timeout, 86_400)))

        while Date() <= deadline {
            if FileManager.default.fileExists(atPath: path) {
                return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 0, output: "Path exists: \(path)")
            }

            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: ShellScriptRunner.cancelledExitCode, output: "Stopped waiting for path: \(path)", wasCancelled: true)
            }
        }

        return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: "Timed out waiting for path: \(path)")
    }

    private nonisolated static func checkProcessRunning(_ query: String) async -> TaskExecutionResult {
        if let pid = Int32(query) {
            let isRunning = kill(pid, 0) == 0
            let now = Date()
            return TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: isRunning ? 0 : 1, output: isRunning ? "Process is running: \(pid)" : "Process is not running: \(pid)", conditionMet: isRunning)
        }

        var result = await ShellScriptRunner.run(ShellScriptRequest(command: "/usr/bin/pgrep -fl \(shellQuoted(query))"))

        // pgrep: 0 = found, 1 = nothing found, anything else = error (e.g. invalid pattern).
        switch result.exitCode {
        case 0:
            result.conditionMet = true
            return result
        case 1:
            return TaskExecutionResult(startedAt: result.startedAt, finishedAt: result.finishedAt, exitCode: 1, output: "Process is not running: \(query)", conditionMet: false)
        default:
            return result
        }
    }

    private nonisolated static func terminateProcess(_ query: String) async -> TaskExecutionResult {
        let now = Date()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        if let pid = Int32(query) {
            guard pid > 1, pid != ownPID else {
                return TaskExecutionResult(startedAt: now, finishedAt: Date(), exitCode: 1, output: "Refusing to terminate process: \(pid)")
            }

            guard kill(pid, SIGTERM) == 0 else {
                return TaskExecutionResult(startedAt: now, finishedAt: Date(), exitCode: 1, output: "Could not terminate process: \(pid)")
            }

            return TaskExecutionResult(startedAt: now, finishedAt: Date(), exitCode: 0, output: "Terminated process: \(pid)")
        }

        // Exact process name only (`pkill -x`). `pkill -f` matched any command line containing
        // the text, which could hit unrelated processes or Cron itself.
        if query.compare(ProcessInfo.processInfo.processName, options: .caseInsensitive) == .orderedSame {
            return TaskExecutionResult(startedAt: now, finishedAt: Date(), exitCode: 1, output: "Refusing to terminate Cron itself.")
        }

        return await ShellScriptRunner.run(ShellScriptRequest(command: "/usr/bin/pkill -x \(shellQuoted(query))"))
    }

    private nonisolated static func showNotification(title: String, body: String) async -> TaskExecutionResult {
        let startedAt = Date()
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else {
                return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: "Notification permission was not granted.")
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(identifier: "cron-\(UUID().uuidString)", content: content, trigger: nil)
            try await center.add(request)

            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 0, output: "Displayed notification: \(title)")
        } catch {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: error.localizedDescription)
        }
    }

    private nonisolated static func pause(seconds: Double) async -> TaskExecutionResult {
        let startedAt = Date()
        let clampedSeconds = max(0.1, min(seconds, 86_400))
        let nanoseconds = UInt64(clampedSeconds * 1_000_000_000)

        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 0, output: "Paused for \(clampedSeconds) seconds.")
        } catch {
            return TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: 1, output: error.localizedDescription)
        }
    }
}

private extension TaskExecutionResult {
    func withExitCode(_ exitCode: Int32) -> TaskExecutionResult {
        TaskExecutionResult(startedAt: startedAt, finishedAt: finishedAt, exitCode: exitCode, output: output, shouldStop: shouldStop)
    }
}

nonisolated private enum SystemOutputVolume {
    private static let outputScope = AudioObjectPropertyScope(kAudioDevicePropertyScopeOutput)
    private static let mainElement = AudioObjectPropertyElement(kAudioObjectPropertyElementMain)

    static func apply(operation: VolumeControlOperation, amount: Double) throws -> String {
        let deviceID = try defaultOutputDeviceID()

        switch operation {
        case .setVolume:
            let target = scalar(percent: amount)
            try setVolumeScalar(target, for: deviceID)
            return "System output volume set to \(percentText(target))."
        case .increaseVolume:
            let current = try volumeScalar(for: deviceID)
            let target = min(1, current + scalar(percent: amount))
            try setVolumeScalar(target, for: deviceID)
            return "System output volume increased to \(percentText(target))."
        case .decreaseVolume:
            let current = try volumeScalar(for: deviceID)
            let target = max(0, current - scalar(percent: amount))
            try setVolumeScalar(target, for: deviceID)
            return "System output volume decreased to \(percentText(target))."
        case .mute:
            try setMute(true, for: deviceID)
            return "System output muted."
        case .unmute:
            try setMute(false, for: deviceID)
            return "System output unmuted."
        case .toggleMute:
            let muted = try muteState(for: deviceID)
            try setMute(!muted, for: deviceID)
            return !muted ? "System output muted." : "System output unmuted."
        }
    }

    private static func defaultOutputDeviceID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioHardwarePropertyDefaultOutputDevice),
            mScope: AudioObjectPropertyScope(kAudioObjectPropertyScopeGlobal),
            mElement: mainElement
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID), "Read default output device")

        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw SystemOutputVolumeError.noOutputDevice
        }

        return deviceID
    }

    private static func volumeScalar(for deviceID: AudioObjectID) throws -> Float32 {
        if let master = try? floatProperty(kAudioDevicePropertyVolumeScalar, for: deviceID, element: mainElement) {
            return master
        }

        let channelValues = (1...8).compactMap { channel in
            try? floatProperty(kAudioDevicePropertyVolumeScalar, for: deviceID, element: AudioObjectPropertyElement(channel))
        }

        guard !channelValues.isEmpty else {
            throw SystemOutputVolumeError.unsupported("The default output device does not expose writable volume.")
        }

        return channelValues.reduce(0, +) / Float32(channelValues.count)
    }

    private static func setVolumeScalar(_ value: Float32, for deviceID: AudioObjectID) throws {
        if try setFloatProperty(kAudioDevicePropertyVolumeScalar, value: value, for: deviceID, element: mainElement) {
            return
        }

        var didSetAnyChannel = false
        for channel in 1...8 {
            if try setFloatProperty(kAudioDevicePropertyVolumeScalar, value: value, for: deviceID, element: AudioObjectPropertyElement(channel)) {
                didSetAnyChannel = true
            }
        }

        guard didSetAnyChannel else {
            throw SystemOutputVolumeError.unsupported("The default output device does not allow changing volume.")
        }
    }

    private static func muteState(for deviceID: AudioObjectID) throws -> Bool {
        if let master = try? integerProperty(kAudioDevicePropertyMute, for: deviceID, element: mainElement) {
            return master != 0
        }

        let channelValues = (1...8).compactMap { channel in
            try? integerProperty(kAudioDevicePropertyMute, for: deviceID, element: AudioObjectPropertyElement(channel))
        }

        guard !channelValues.isEmpty else {
            throw SystemOutputVolumeError.unsupported("The default output device does not expose mute state.")
        }

        return channelValues.contains { $0 != 0 }
    }

    private static func setMute(_ muted: Bool, for deviceID: AudioObjectID) throws {
        let value: UInt32 = muted ? 1 : 0
        if try setIntegerProperty(kAudioDevicePropertyMute, value: value, for: deviceID, element: mainElement) {
            return
        }

        var didSetAnyChannel = false
        for channel in 1...8 {
            if try setIntegerProperty(kAudioDevicePropertyMute, value: value, for: deviceID, element: AudioObjectPropertyElement(channel)) {
                didSetAnyChannel = true
            }
        }

        guard didSetAnyChannel else {
            throw SystemOutputVolumeError.unsupported("The default output device does not allow changing mute state.")
        }
    }

    private static func floatProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioObjectID, element: AudioObjectPropertyElement) throws -> Float32 {
        var address = propertyAddress(selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw SystemOutputVolumeError.missingProperty
        }

        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value), "Read output volume")
        return value
    }

    private static func integerProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioObjectID, element: AudioObjectPropertyElement) throws -> UInt32 {
        var address = propertyAddress(selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw SystemOutputVolumeError.missingProperty
        }

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value), "Read output mute")
        return value
    }

    private static func setFloatProperty(_ selector: AudioObjectPropertySelector, value: Float32, for deviceID: AudioObjectID, element: AudioObjectPropertyElement) throws -> Bool {
        var address = propertyAddress(selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address), try isSettable(deviceID: deviceID, address: &address) else {
            return false
        }

        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        try check(AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableValue), "Set output volume")
        return true
    }

    private static func setIntegerProperty(_ selector: AudioObjectPropertySelector, value: UInt32, for deviceID: AudioObjectID, element: AudioObjectPropertyElement) throws -> Bool {
        var address = propertyAddress(selector, element: element)
        guard AudioObjectHasProperty(deviceID, &address), try isSettable(deviceID: deviceID, address: &address) else {
            return false
        }

        var mutableValue = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &mutableValue), "Set output mute")
        return true
    }

    private static func isSettable(deviceID: AudioObjectID, address: inout AudioObjectPropertyAddress) throws -> Bool {
        var settable = DarwinBoolean(false)
        try check(AudioObjectIsPropertySettable(deviceID, &address, &settable), "Check whether output property is settable")
        return settable.boolValue
    }

    private static func propertyAddress(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: outputScope, mElement: element)
    }

    private static func scalar(percent: Double) -> Float32 {
        Float32(min(max(percent, 0), 100) / 100)
    }

    private static func percentText(_ scalar: Float32) -> String {
        "\(Int((scalar * 100).rounded()))%"
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemOutputVolumeError.coreAudio(operation: operation, status: status)
        }
    }
}

nonisolated private enum SystemOutputVolumeError: LocalizedError {
    case noOutputDevice
    case missingProperty
    case unsupported(String)
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice:
            return "No default output audio device is available."
        case .missingProperty:
            return "The default output device does not expose the requested audio property."
        case .unsupported(let message):
            return message
        case .coreAudio(let operation, let status):
            return "\(operation) failed with CoreAudio status \(status)."
        }
    }
}

@MainActor
private final class SpeechActionSpeaker {
    static let shared = SpeechActionSpeaker()

    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
    }
}

nonisolated enum TaskActionError: LocalizedError {
    case invalidURL(String)
    case pathNotFound(String)
    case openFailed(String)
    case applicationNotFound(String)
    case quitFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid URL: \(value)"
        case .pathNotFound(let path):
            return "Path does not exist: \(path)"
        case .openFailed(let target):
            return "macOS could not open: \(target)"
        case .applicationNotFound(let query):
            return "Running application not found: \(query)"
        case .quitFailed(let query):
            return "macOS could not quit application: \(query)"
        }
    }
}
