import AppKit
import SwiftData
import SwiftUI

extension Binding where Value == WorkflowStep {
    /// Binding to the step's typed configuration.
    func configuration<C: StepConfiguration>(_ type: C.Type) -> Binding<C> {
        Binding<C> {
            wrappedValue.configuration(C.self)
        } set: { newValue in
            wrappedValue.setConfiguration(newValue)
        }
    }
}

struct ActionStepConfigurationView: View {
    @Binding var step: WorkflowStep

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(step.title, systemImage: step.actionType.symbol)
                        .font(.headline)

                    Spacer()

                    Toggle(L("Enabled"), isOn: $step.isEnabled)
                }

                LabeledTextField(title: "Name", placeholder: step.actionType.title, text: $step.title)

                Text(step.actionType.description)
                    .foregroundStyle(.secondary)

                configurationFields

                if step.actionType.runsProcess {
                    HStack {
                        Text(L("Time limit (seconds, 0 = none)"))
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)

                        TextField("0", value: $step.timeoutSeconds, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                if step.actionType.isCondition {
                    HStack {
                        Text(L("When the condition is not met"))
                            .foregroundStyle(.secondary)
                            .frame(width: 140, alignment: .leading)

                        Picker(L("When the condition is not met"), selection: $step.whenConditionNotMet) {
                            ForEach(ConditionPolicy.allCases) { policy in
                                Text(L(policy.titleKey)).tag(policy)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                    }
                }

                if step.actionType != .stopExecution && step.actionType != .finishExecution {
                    StepErrorPolicyView(step: $step)
                }

                if step.hasTextFields {
                    Text(L("Text fields can use {previous}, {step:N}, {task}, {date}, {time}, {file} and {app}."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if step.actionType.runsProcess {
                    Text(L("In scripts these values are available as CRON_* environment variables."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var configurationFields: some View {
        let path = $step.configuration(PathConfiguration.self)
        let transfer = $step.configuration(TransferConfiguration.self)
        let text = $step.configuration(TextConfiguration.self)
        let name = $step.configuration(NameConfiguration.self)

        switch step.actionType {
        case .shellScript:
            ShellScriptStepConfigurationView(config: $step.configuration(ShellScriptConfiguration.self))
        case .openURL:
            LabeledTextField(title: "URL", placeholder: "https://example.com", text: $step.configuration(URLConfiguration.self).url)
        case .openItem:
            LabeledPathField(title: "Item", placeholder: "/Applications/TextEdit.app", text: path.path, canChooseFiles: true, canChooseDirectories: true)
        case .quitApplication:
            LabeledTextField(title: "Application", placeholder: "Safari or com.apple.Safari", text: name.name)
        case .compressItem:
            LabeledPathField(title: "Source", placeholder: "/path/to/source", text: transfer.source, canChooseFiles: true, canChooseDirectories: true)
            LabeledPathField(title: "Archive", placeholder: "\(NSHomeDirectory())/Desktop/archive.zip", text: transfer.destination, canChooseFiles: true, canChooseDirectories: false)
        case .convertLineEndings:
            LabeledPathField(title: "Source", placeholder: "/path/to/input.txt", text: transfer.source, canChooseFiles: true, canChooseDirectories: false)
            LabeledPathField(title: "Output", placeholder: "/path/to/output.txt", text: transfer.destination, canChooseFiles: true, canChooseDirectories: false)
        case .copyItem, .moveItem:
            LabeledPathField(title: "Source", placeholder: "/path/to/source", text: transfer.source, canChooseFiles: true, canChooseDirectories: true)
            LabeledPathField(title: "Destination", placeholder: "/path/to/destination", text: transfer.destination, canChooseFiles: true, canChooseDirectories: true)
        case .createFolder:
            LabeledPathField(title: "Folder path", placeholder: "\(NSHomeDirectory())/Desktop/Cron Output", text: path.path, canChooseFiles: false, canChooseDirectories: true)
        case .decompressItem:
            LabeledPathField(title: "Archive", placeholder: "/path/to/archive.zip", text: transfer.source, canChooseFiles: true, canChooseDirectories: false)
            LabeledPathField(title: "Destination", placeholder: "\(NSHomeDirectory())/Desktop/Cron Output", text: transfer.destination, canChooseFiles: false, canChooseDirectories: true)
        case .deleteItem, .lockItem, .unlockItem, .checkFileExists:
            LabeledPathField(title: "Item", placeholder: "/path/to/item", text: path.path, canChooseFiles: true, canChooseDirectories: true)
        case .printItem:
            LabeledPathField(title: "File", placeholder: "/path/to/file", text: path.path, canChooseFiles: true, canChooseDirectories: false)
        case .renameItem:
            let rename = $step.configuration(RenameConfiguration.self)
            LabeledPathField(title: "Item", placeholder: "/path/to/item", text: rename.path, canChooseFiles: true, canChooseDirectories: true)
            LabeledTextField(title: "New name", placeholder: "New filename", text: rename.newName)
        case .replaceTextInFile:
            let replace = $step.configuration(ReplaceTextConfiguration.self)
            LabeledPathField(title: "File", placeholder: "/path/to/file.txt", text: replace.path, canChooseFiles: true, canChooseDirectories: false)
            LabeledTextField(title: "Find", placeholder: "Text to find", text: replace.find)
            LabeledTextEditor(title: "Replace with", text: replace.replacement, monospaced: false, minHeight: 70)
        case .retrieveFolderContents:
            LabeledPathField(title: "Folder", placeholder: NSHomeDirectory(), text: path.path, canChooseFiles: false, canChooseDirectories: true)
        case .writeTextFile:
            let write = $step.configuration(WriteTextConfiguration.self)
            LabeledPathField(title: "File path", placeholder: "\(NSHomeDirectory())/Desktop/Cron Output/output.txt", text: write.path, canChooseFiles: true, canChooseDirectories: false)
            LabeledTextEditor(title: "Text", text: write.text, monospaced: true, minHeight: 120)
        case .speakText, .specifyText:
            LabeledTextEditor(title: "Text", text: text.text, monospaced: false, minHeight: 90)
        case .setClipboardText:
            LabeledTextEditor(title: "Clipboard text", text: text.text, monospaced: false, minHeight: 90)
        case .displayTextInputDialog:
            LabeledTextEditor(title: "Prompt", text: text.text, monospaced: false, minHeight: 90)
        case .displayDialog:
            LabeledTextEditor(title: "Message", text: text.text, monospaced: false, minHeight: 90)
        case .playAudioFile:
            LabeledPathField(title: "Audio file", placeholder: "/path/to/audio.aiff", text: path.path, canChooseFiles: true, canChooseDirectories: false)
        case .volumeControl:
            VolumeControlStepConfigurationView(config: $step.configuration(VolumeConfiguration.self))
        case .checkInternet:
            Text(L("Checks https://www.apple.com/library/test/success.html with an 8 second timeout."))
                .foregroundStyle(.secondary)
        case .compareText:
            let compare = $step.configuration(CompareTextConfiguration.self)
            LabeledTextEditor(title: "First text", text: compare.first, monospaced: false, minHeight: 70)
            LabeledTextEditor(title: "Second text", text: compare.second, monospaced: false, minHeight: 70)
        case .takeScreenshot:
            LabeledPathField(title: "Output file", placeholder: "\(NSHomeDirectory())/Desktop/screenshot.png", text: path.path, canChooseFiles: true, canChooseDirectories: false)
        case .setDesktopBackground:
            LabeledPathField(title: "Image", placeholder: "/path/to/image.jpg", text: path.path, canChooseFiles: true, canChooseDirectories: false)
        case .checkTasksRunning, .deleteTasks, .disableTasks, .enableTasks, .executeTasks, .stopTasks:
            LabeledTextEditor(title: "Task", text: taskNamesText, monospaced: false, minHeight: 60)
            Text(L("One task name per line."))
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pauseExecution:
            SecondsStepper(title: "Seconds", value: $step.configuration(DurationConfiguration.self).seconds)
        case .stopExecution:
            Text(L("Workflow stops when this step is reached."))
                .foregroundStyle(.secondary)
        case .finishExecution:
            Text(L("Workflow finishes successfully when this step is reached."))
                .foregroundStyle(.secondary)
        case .retrieveEnvironmentVariable:
            LabeledTextField(title: "Variable", placeholder: "PATH", text: name.name)
        case .executeAppleScript:
            LabeledTextEditor(title: "AppleScript", text: $step.configuration(AppleScriptConfiguration.self).script, monospaced: true, minHeight: 180)
        case .runShortcut:
            let shortcut = $step.configuration(ShortcutConfiguration.self)
            LabeledTextField(title: "Shortcut", placeholder: "Shortcut name", text: shortcut.name)
            LabeledTextField(title: "Arguments", placeholder: "Optional shortcut arguments", text: shortcut.arguments)
        case .showNotification:
            let notification = $step.configuration(NotificationConfiguration.self)
            LabeledTextField(title: "Notification title", placeholder: "Cron", text: notification.title)
            LabeledTextEditor(title: "Notification body", text: notification.body, monospaced: false, minHeight: 90)
        case .sendHTTPRequest:
            let http = $step.configuration(HTTPRequestConfiguration.self)
            LabeledTextField(title: "URL", placeholder: "https://example.com", text: http.url)
            LabeledTextField(title: "HTTP method", placeholder: "GET", text: http.method)
            LabeledTextEditor(title: "Headers", text: http.headers, monospaced: true, minHeight: 90)
            LabeledTextEditor(title: "Body", text: http.body, monospaced: true, minHeight: 120)
            SecondsStepper(title: "Timeout", value: http.timeoutSeconds, range: 1...300)
        case .waitForFile:
            let wait = $step.configuration(WaitForFileConfiguration.self)
            LabeledPathField(title: "Item", placeholder: "/path/to/item", text: wait.path, canChooseFiles: true, canChooseDirectories: true)
            SecondsStepper(title: "Timeout", value: wait.timeoutSeconds)
        case .checkProcessRunning, .terminateProcess:
            LabeledTextField(title: "Process", placeholder: "PID or process name", text: name.name)
        case .savePreviousOutput:
            LabeledPathField(title: "File path", placeholder: "\(NSHomeDirectory())/Desktop/Cron Output/output.txt", text: path.path, canChooseFiles: true, canChooseDirectories: false)
        case .emptyTrash, .retrieveHomeDirectory, .retrieveVolumes, .playAlertSound, .timeMachineStatus,
             .startTimeMachineBackup, .stopTimeMachineBackup, .sleepComputer, .restartComputer, .shutdownComputer,
             .retrieveDate, .displayFileSelectionDialog, .retrieveOSName, .retrieveOSVersion, .getClipboardText,
             .pauseScheduler, .resumeScheduler, .retrieveCurrentTask:
            Text(L("No configuration required."))
                .foregroundStyle(.secondary)
        }
    }

    /// Task names edited as one name per line.
    private var taskNamesText: Binding<String> {
        let names = $step.configuration(TaskNamesConfiguration.self).names
        return Binding {
            names.wrappedValue.joined(separator: "\n")
        } set: { text in
            names.wrappedValue = text.components(separatedBy: .newlines)
        }
    }
}

private struct StepErrorPolicyView: View {
    @Binding var step: WorkflowStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("On error"))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)

                Picker(L("On error"), selection: $step.onError) {
                    ForEach(StepErrorPolicy.allCases) { policy in
                        Text(L(policy.titleKey)).tag(policy)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }

            if step.onError == .retry {
                HStack(spacing: 16) {
                    Spacer()
                        .frame(width: 140)

                    Stepper(value: $step.retryCount, in: WorkflowStep.retryCountRange) {
                        Text("\(L("Retries")): \(step.retryCount)")
                            .frame(width: 110, alignment: .leading)
                    }

                    Stepper(value: $step.retryDelaySeconds, in: WorkflowStep.retryDelayRange, step: 5) {
                        Text("\(L("Every")) \(Int(step.retryDelaySeconds)) \(L("seconds"))")
                            .frame(width: 140, alignment: .leading)
                    }
                }
            } else if step.onError == .continueWorkflow {
                Text(L("The action is shown as failed in the history, but the task still succeeds."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 152)
            }
        }
    }
}

private struct SecondsStepper: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0.1...86_400

    var body: some View {
        HStack {
            Text(L(title))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            Stepper(value: $value, in: range, step: 1) {
                Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(L("seconds"))")
                    .frame(width: 120, alignment: .leading)
            }
        }
    }
}

struct ShellScriptStepConfigurationView: View {
    @Binding var config: ShellScriptConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Source"))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)

                Picker(L("Source"), selection: $config.mode) {
                    ForEach(JobCommandMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            LabeledTextField(title: "Shell", placeholder: "/bin/zsh", text: $config.shellPath)

            LabeledPathField(title: "Working directory", placeholder: NSHomeDirectory(), text: $config.workingDirectory, canChooseFiles: false, canChooseDirectories: true)

            if config.mode == .scriptFile {
                LabeledPathField(title: "Script file", placeholder: "/path/to/script.sh", text: $config.scriptFile, canChooseFiles: true, canChooseDirectories: false)
                LabeledTextField(title: "Arguments", placeholder: "Optional shell arguments", text: $config.arguments)
            } else {
                LabeledTextEditor(title: "Script", text: $config.script, monospaced: true, minHeight: 180)
            }

            LabeledTextEditor(title: "Environment", text: $config.environment, monospaced: true, minHeight: 74)
        }
    }
}

struct VolumeControlStepConfigurationView: View {
    @Binding var config: VolumeConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Operation"))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)

                Picker(L("Operation"), selection: $config.operation) {
                    ForEach(VolumeControlOperation.allCases) { operation in
                        Text(operation.title).tag(operation)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            if config.operation.usesAmount {
                HStack(spacing: 12) {
                    Text(L(config.operation.amountTitleKey))
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)

                    Slider(value: amount, in: config.operation.amountRange, step: 1)
                        .frame(maxWidth: 280)

                    Text("\(Int(amount.wrappedValue)) %")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)

                    Stepper(value: amount, in: config.operation.amountRange, step: 1) {
                        EmptyView()
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var amount: Binding<Double> {
        Binding {
            min(max(config.amount.rounded(), config.operation.amountRange.lowerBound), config.operation.amountRange.upperBound)
        } set: { newValue in
            config.amount = min(max(newValue.rounded(), config.operation.amountRange.lowerBound), config.operation.amountRange.upperBound)
        }
    }
}
