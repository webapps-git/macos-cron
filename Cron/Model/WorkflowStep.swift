import Foundation

// MARK: - Action configurations

/// Settings of one workflow action. Every property has a default, so configurations stored by
/// older versions decode with the missing fields filled in (see `DefaultDecoding`).
nonisolated protocol StepConfiguration: DefaultDecodable, Hashable, Sendable {}

nonisolated struct EmptyConfiguration: StepConfiguration {}

nonisolated struct PathConfiguration: StepConfiguration {
    var path = ""
}

nonisolated struct TransferConfiguration: StepConfiguration {
    var source = ""
    var destination = ""
}

nonisolated struct TextConfiguration: StepConfiguration {
    var text = ""
}

/// Application, process or environment variable name.
nonisolated struct NameConfiguration: StepConfiguration {
    var name = ""
}

nonisolated struct URLConfiguration: StepConfiguration {
    var url = ""
}

nonisolated struct AppleScriptConfiguration: StepConfiguration {
    var script = ""
}

nonisolated struct ShellScriptConfiguration: StepConfiguration {
    var mode = JobCommandMode.inlineScript
    var shellPath = "/bin/zsh"
    var script = ""
    var scriptFile = ""
    var arguments = ""
    var workingDirectory = ""
    var environment = ""
}

nonisolated struct RenameConfiguration: StepConfiguration {
    var path = ""
    var newName = ""
}

nonisolated struct ReplaceTextConfiguration: StepConfiguration {
    var path = ""
    var find = ""
    var replacement = ""
}

nonisolated struct WriteTextConfiguration: StepConfiguration {
    var path = ""
    var text = ""
}

nonisolated struct CompareTextConfiguration: StepConfiguration {
    var first = ""
    var second = ""
}

nonisolated struct DurationConfiguration: StepConfiguration {
    var seconds: Double = 5
}

nonisolated struct WaitForFileConfiguration: StepConfiguration {
    var path = ""
    var timeoutSeconds: Double = 30
}

nonisolated struct ShortcutConfiguration: StepConfiguration {
    var name = ""
    /// Extra command line arguments passed to `shortcuts run`.
    var arguments = ""
}

nonisolated struct NotificationConfiguration: StepConfiguration {
    var title = "Cron"
    var body = ""
}

nonisolated struct HTTPRequestConfiguration: StepConfiguration {
    var url = ""
    var method = "GET"
    /// One `Name: value` header per line.
    var headers = ""
    var body = ""
    var timeoutSeconds: Double = 30
}

nonisolated struct VolumeConfiguration: StepConfiguration {
    var operation = VolumeControlOperation.setVolume
    var amount: Double = 50
}

nonisolated struct TaskNamesConfiguration: StepConfiguration {
    var names: [String] = []
}

/// The configuration of a step; the case is determined by the step's action type
/// (`TaskActionType.defaultConfiguration`).
nonisolated enum ActionConfiguration: Hashable, Sendable {
    case empty(EmptyConfiguration)
    case path(PathConfiguration)
    case transfer(TransferConfiguration)
    case text(TextConfiguration)
    case name(NameConfiguration)
    case url(URLConfiguration)
    case appleScript(AppleScriptConfiguration)
    case shellScript(ShellScriptConfiguration)
    case rename(RenameConfiguration)
    case replaceText(ReplaceTextConfiguration)
    case writeText(WriteTextConfiguration)
    case compareText(CompareTextConfiguration)
    case duration(DurationConfiguration)
    case waitForFile(WaitForFileConfiguration)
    case shortcut(ShortcutConfiguration)
    case notification(NotificationConfiguration)
    case httpRequest(HTTPRequestConfiguration)
    case volume(VolumeConfiguration)
    case taskNames(TaskNamesConfiguration)

    init<C: StepConfiguration>(_ configuration: C) {
        switch configuration {
        case let value as PathConfiguration: self = .path(value)
        case let value as TransferConfiguration: self = .transfer(value)
        case let value as TextConfiguration: self = .text(value)
        case let value as NameConfiguration: self = .name(value)
        case let value as URLConfiguration: self = .url(value)
        case let value as AppleScriptConfiguration: self = .appleScript(value)
        case let value as ShellScriptConfiguration: self = .shellScript(value)
        case let value as RenameConfiguration: self = .rename(value)
        case let value as ReplaceTextConfiguration: self = .replaceText(value)
        case let value as WriteTextConfiguration: self = .writeText(value)
        case let value as CompareTextConfiguration: self = .compareText(value)
        case let value as DurationConfiguration: self = .duration(value)
        case let value as WaitForFileConfiguration: self = .waitForFile(value)
        case let value as ShortcutConfiguration: self = .shortcut(value)
        case let value as NotificationConfiguration: self = .notification(value)
        case let value as HTTPRequestConfiguration: self = .httpRequest(value)
        case let value as VolumeConfiguration: self = .volume(value)
        case let value as TaskNamesConfiguration: self = .taskNames(value)
        default: self = .empty(EmptyConfiguration())
        }
    }

    /// The stored configuration as `C`, or `nil` when the step holds another kind.
    func value<C: StepConfiguration>(_ type: C.Type) -> C? {
        switch self {
        case .empty(let value): return value as? C
        case .path(let value): return value as? C
        case .transfer(let value): return value as? C
        case .text(let value): return value as? C
        case .name(let value): return value as? C
        case .url(let value): return value as? C
        case .appleScript(let value): return value as? C
        case .shellScript(let value): return value as? C
        case .rename(let value): return value as? C
        case .replaceText(let value): return value as? C
        case .writeText(let value): return value as? C
        case .compareText(let value): return value as? C
        case .duration(let value): return value as? C
        case .waitForFile(let value): return value as? C
        case .shortcut(let value): return value as? C
        case .notification(let value): return value as? C
        case .httpRequest(let value): return value as? C
        case .volume(let value): return value as? C
        case .taskNames(let value): return value as? C
        }
    }

    fileprivate func encode(to container: inout KeyedEncodingContainer<WorkflowStep.CodingKeys>, forKey key: WorkflowStep.CodingKeys) throws {
        switch self {
        case .empty(let value): try container.encode(value, forKey: key)
        case .path(let value): try container.encode(value, forKey: key)
        case .transfer(let value): try container.encode(value, forKey: key)
        case .text(let value): try container.encode(value, forKey: key)
        case .name(let value): try container.encode(value, forKey: key)
        case .url(let value): try container.encode(value, forKey: key)
        case .appleScript(let value): try container.encode(value, forKey: key)
        case .shellScript(let value): try container.encode(value, forKey: key)
        case .rename(let value): try container.encode(value, forKey: key)
        case .replaceText(let value): try container.encode(value, forKey: key)
        case .writeText(let value): try container.encode(value, forKey: key)
        case .compareText(let value): try container.encode(value, forKey: key)
        case .duration(let value): try container.encode(value, forKey: key)
        case .waitForFile(let value): try container.encode(value, forKey: key)
        case .shortcut(let value): try container.encode(value, forKey: key)
        case .notification(let value): try container.encode(value, forKey: key)
        case .httpRequest(let value): try container.encode(value, forKey: key)
        case .volume(let value): try container.encode(value, forKey: key)
        case .taskNames(let value): try container.encode(value, forKey: key)
        }
    }

    /// Decodes the configuration for `actionType`, filling missing fields with defaults.
    fileprivate static func decode(for actionType: TaskActionType, from json: JSONValue?) throws -> ActionConfiguration {
        switch actionType.defaultConfiguration {
        case .empty: return .empty(EmptyConfiguration())
        case .path: return .path(try DefaultDecoding.decode(PathConfiguration.self, from: json))
        case .transfer: return .transfer(try DefaultDecoding.decode(TransferConfiguration.self, from: json))
        case .text: return .text(try DefaultDecoding.decode(TextConfiguration.self, from: json))
        case .name: return .name(try DefaultDecoding.decode(NameConfiguration.self, from: json))
        case .url: return .url(try DefaultDecoding.decode(URLConfiguration.self, from: json))
        case .appleScript: return .appleScript(try DefaultDecoding.decode(AppleScriptConfiguration.self, from: json))
        case .shellScript: return .shellScript(try DefaultDecoding.decode(ShellScriptConfiguration.self, from: json))
        case .rename: return .rename(try DefaultDecoding.decode(RenameConfiguration.self, from: json))
        case .replaceText: return .replaceText(try DefaultDecoding.decode(ReplaceTextConfiguration.self, from: json))
        case .writeText: return .writeText(try DefaultDecoding.decode(WriteTextConfiguration.self, from: json))
        case .compareText: return .compareText(try DefaultDecoding.decode(CompareTextConfiguration.self, from: json))
        case .duration: return .duration(try DefaultDecoding.decode(DurationConfiguration.self, from: json))
        case .waitForFile: return .waitForFile(try DefaultDecoding.decode(WaitForFileConfiguration.self, from: json))
        case .shortcut: return .shortcut(try DefaultDecoding.decode(ShortcutConfiguration.self, from: json))
        case .notification: return .notification(try DefaultDecoding.decode(NotificationConfiguration.self, from: json))
        case .httpRequest: return .httpRequest(try DefaultDecoding.decode(HTTPRequestConfiguration.self, from: json))
        case .volume: return .volume(try DefaultDecoding.decode(VolumeConfiguration.self, from: json))
        case .taskNames: return .taskNames(try DefaultDecoding.decode(TaskNamesConfiguration.self, from: json))
        }
    }
}

// MARK: - Step policies

/// What the workflow does when a step fails.
nonisolated enum StepErrorPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case stop
    /// The step is recorded as failed, the workflow goes on and the run still succeeds
    /// (like `continue-on-error` in GitHub Actions).
    case continueWorkflow = "continue"
    case retry

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .stop:
            return "Stop the workflow"
        case .continueWorkflow:
            return "Continue with the next action"
        case .retry:
            return "Retry, then stop"
        }
    }
}

/// What the workflow does when a condition action is not met.
nonisolated enum ConditionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Ends the run without an error.
    case finish
    case fail
    case continueWorkflow = "continue"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .finish:
            return "Finish without an error"
        case .fail:
            return "Finish with an error"
        case .continueWorkflow:
            return "Continue with the next action"
        }
    }
}

// MARK: - Workflow step

nonisolated struct WorkflowStep: Codable, Identifiable, Hashable, Sendable {
    static let retryCountRange = 1...10
    static let retryDelayRange: ClosedRange<Double> = 1...3_600

    var id: UUID
    var actionType: TaskActionType
    var title: String
    var isEnabled: Bool
    /// Time limit for actions that run a process (shell script, AppleScript, Shortcuts); 0 = none.
    /// With retries it applies to each attempt.
    var timeoutSeconds: Double
    var configuration: ActionConfiguration
    var onError = StepErrorPolicy.stop
    /// Retries after the first attempt (`onError == .retry`).
    var retryCount = 3
    var retryDelaySeconds: Double = 10
    /// Only used by condition actions (`TaskActionType.isCondition`).
    var whenConditionNotMet = ConditionPolicy.finish

    init(id: UUID = UUID(), actionType: TaskActionType, title: String, isEnabled: Bool = true, timeoutSeconds: Double = 0, configuration: ActionConfiguration? = nil) {
        self.id = id
        self.actionType = actionType
        self.title = title
        self.isEnabled = isEnabled
        self.timeoutSeconds = timeoutSeconds
        self.configuration = configuration ?? actionType.defaultConfiguration
    }

    @MainActor
    static func make(actionType: TaskActionType) -> WorkflowStep {
        WorkflowStep(actionType: actionType, title: actionType.title)
    }

    /// Typed access to the configuration; returns defaults if the step holds another kind.
    func configuration<C: StepConfiguration>(_ type: C.Type) -> C {
        configuration.value(C.self) ?? C()
    }

    mutating func setConfiguration<C: StepConfiguration>(_ value: C) {
        configuration = ActionConfiguration(value)
    }

    fileprivate enum CodingKeys: String, CodingKey {
        case id, type, title, isEnabled, timeoutSeconds, config, onError, retryCount, retryDelaySeconds, whenConditionNotMet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeName = try container.decode(String.self, forKey: .type)

        guard let actionType = TaskActionType(rawValue: typeName) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown action type: \(typeName)")
        }

        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.actionType = actionType
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? actionType.rawValue
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 0
        self.configuration = try ActionConfiguration.decode(
            for: actionType,
            from: try container.decodeIfPresent(JSONValue.self, forKey: .config)
        )
        // Steps saved before these fields existed keep the old behavior (stop on error, finish on unmet condition).
        self.onError = try container.decodeIfPresent(StepErrorPolicy.self, forKey: .onError) ?? .stop
        self.retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 3
        self.retryDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .retryDelaySeconds) ?? 10
        self.whenConditionNotMet = try container.decodeIfPresent(ConditionPolicy.self, forKey: .whenConditionNotMet) ?? .finish
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(actionType.rawValue, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try configuration.encode(to: &container, forKey: .config)
        try container.encode(onError, forKey: .onError)
        try container.encode(retryCount, forKey: .retryCount)
        try container.encode(retryDelaySeconds, forKey: .retryDelaySeconds)
        try container.encode(whenConditionNotMet, forKey: .whenConditionNotMet)
    }

    /// Whether the configuration has text fields, where `{previous}` and the like can be used.
    var hasTextFields: Bool {
        switch configuration {
        case .empty, .duration, .volume:
            return false
        default:
            return true
        }
    }

    /// Whether the step has everything it needs to run.
    var isConfigured: Bool {
        switch configuration {
        case .empty:
            return true
        case .path(let value):
            return !value.path.trimmed.isEmpty
        case .transfer(let value):
            return !value.source.trimmed.isEmpty && !value.destination.trimmed.isEmpty
        case .text(let value):
            // Compare/specify-like texts may legitimately be empty only for specifyText.
            return actionType == .specifyText || !value.text.trimmed.isEmpty
        case .name(let value):
            return !value.name.trimmed.isEmpty
        case .url(let value):
            return !value.url.trimmed.isEmpty
        case .appleScript(let value):
            return !value.script.trimmed.isEmpty
        case .shellScript(let value):
            return value.mode == .inlineScript ? !value.script.trimmed.isEmpty : !value.scriptFile.trimmed.isEmpty
        case .rename(let value):
            return !value.path.trimmed.isEmpty && !value.newName.trimmed.isEmpty
        case .replaceText(let value):
            return !value.path.trimmed.isEmpty
        case .writeText(let value):
            return !value.path.trimmed.isEmpty
        case .compareText:
            return true
        case .duration(let value):
            return value.seconds > 0
        case .waitForFile(let value):
            return !value.path.trimmed.isEmpty && value.timeoutSeconds > 0
        case .shortcut(let value):
            return !value.name.trimmed.isEmpty
        case .notification(let value):
            return !value.body.trimmed.isEmpty
        case .httpRequest(let value):
            return !value.url.trimmed.isEmpty
        case .volume(let value):
            return value.operation.amountRange.contains(value.amount.rounded()) || !value.operation.usesAmount
        case .taskNames(let value):
            return actionType == .checkTasksRunning || value.names.contains { !$0.trimmed.isEmpty }
        }
    }
}

extension TaskActionType {
    /// Configuration a new step of this type starts with; its case defines the stored shape.
    nonisolated var defaultConfiguration: ActionConfiguration {
        let home = NSHomeDirectory()

        switch self {
        case .shellScript:
            return .shellScript(ShellScriptConfiguration(script: "echo \"Hello from Cron\"\ndate", workingDirectory: home))
        case .executeAppleScript:
            return .appleScript(AppleScriptConfiguration(script: "display notification \"Hello from Cron\" with title \"Cron\""))
        case .openURL:
            return .url(URLConfiguration(url: "https://example.com"))
        case .sendHTTPRequest:
            return .httpRequest(HTTPRequestConfiguration(url: "https://example.com"))
        case .openItem:
            return .path(PathConfiguration(path: home))
        case .createFolder:
            return .path(PathConfiguration(path: "\(home)/Desktop/Cron Output"))
        case .deleteItem, .lockItem, .unlockItem, .printItem, .playAudioFile, .setDesktopBackground, .checkFileExists:
            return .path(PathConfiguration())
        case .retrieveFolderContents:
            return .path(PathConfiguration(path: home))
        case .takeScreenshot:
            return .path(PathConfiguration(path: "\(home)/Desktop/screenshot.png"))
        case .savePreviousOutput:
            return .path(PathConfiguration(path: "\(home)/Desktop/Cron Output/output.txt"))
        case .copyItem, .moveItem, .compressItem, .convertLineEndings, .decompressItem:
            return .transfer(TransferConfiguration())
        case .renameItem:
            return .rename(RenameConfiguration())
        case .replaceTextInFile:
            return .replaceText(ReplaceTextConfiguration())
        case .writeTextFile:
            return .writeText(WriteTextConfiguration(path: "\(home)/Desktop/Cron Output/output.txt", text: "Hello from Cron"))
        case .speakText, .setClipboardText:
            return .text(TextConfiguration(text: "Cron task finished"))
        case .specifyText, .displayDialog, .displayTextInputDialog:
            return .text(TextConfiguration())
        case .compareText:
            return .compareText(CompareTextConfiguration())
        case .quitApplication, .checkProcessRunning, .terminateProcess:
            return .name(NameConfiguration())
        case .retrieveEnvironmentVariable:
            return .name(NameConfiguration(name: "PATH"))
        case .pauseExecution:
            return .duration(DurationConfiguration(seconds: 5))
        case .waitForFile:
            return .waitForFile(WaitForFileConfiguration())
        case .runShortcut:
            return .shortcut(ShortcutConfiguration())
        case .showNotification:
            return .notification(NotificationConfiguration(title: "Cron", body: "Cron task finished"))
        case .volumeControl:
            return .volume(VolumeConfiguration())
        case .checkTasksRunning, .deleteTasks, .disableTasks, .enableTasks, .executeTasks, .stopTasks:
            return .taskNames(TaskNamesConfiguration())
        case .emptyTrash, .retrieveHomeDirectory, .retrieveVolumes, .playAlertSound, .checkInternet,
             .timeMachineStatus, .startTimeMachineBackup, .stopTimeMachineBackup, .sleepComputer,
             .restartComputer, .shutdownComputer, .retrieveDate, .displayFileSelectionDialog,
             .retrieveOSName, .retrieveOSVersion, .stopExecution, .finishExecution, .getClipboardText,
             .pauseScheduler, .resumeScheduler, .retrieveCurrentTask:
            return .empty(EmptyConfiguration())
        }
    }
}

nonisolated extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
