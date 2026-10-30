import Foundation

nonisolated enum JobCommandMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case inlineScript
    case scriptFile

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .inlineScript:
            return "Inline script"
        case .scriptFile:
            return "Script file"
        }
    }

    @MainActor
    var title: String {
        L(titleKey)
    }
}

nonisolated enum VolumeControlOperation: String, CaseIterable, Identifiable, Codable, Sendable {
    case setVolume
    case increaseVolume
    case decreaseVolume
    case mute
    case unmute
    case toggleMute

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .setVolume:
            return "Set volume"
        case .increaseVolume:
            return "Increase volume"
        case .decreaseVolume:
            return "Decrease volume"
        case .mute:
            return "Mute"
        case .unmute:
            return "Unmute"
        case .toggleMute:
            return "Toggle mute"
        }
    }

    @MainActor
    var title: String {
        L(titleKey)
    }

    var usesAmount: Bool {
        switch self {
        case .setVolume, .increaseVolume, .decreaseVolume:
            return true
        case .mute, .unmute, .toggleMute:
            return false
        }
    }

    var amountTitleKey: String {
        switch self {
        case .setVolume:
            return "Volume"
        case .increaseVolume, .decreaseVolume:
            return "Step"
        case .mute, .unmute, .toggleMute:
            return "Volume"
        }
    }

    var amountRange: ClosedRange<Double> {
        switch self {
        case .setVolume:
            return 0...100
        case .increaseVolume, .decreaseVolume:
            return 1...100
        case .mute, .unmute, .toggleMute:
            return 0...100
        }
    }
}

nonisolated enum TaskActionType: String, CaseIterable, Identifiable, Codable, Sendable {
    case shellScript
    case openURL
    case openItem
    case quitApplication
    case compressItem
    case convertLineEndings
    case copyItem
    case createFolder
    case decompressItem
    case deleteItem
    case emptyTrash
    case lockItem
    case moveItem
    case printItem
    case renameItem
    case replaceTextInFile
    case retrieveFolderContents
    case retrieveHomeDirectory
    case retrieveVolumes
    case unlockItem
    case writeTextFile
    case speakText
    case playAudioFile
    case playAlertSound
    case checkInternet
    case timeMachineStatus
    case startTimeMachineBackup
    case stopTimeMachineBackup
    case sleepComputer
    case restartComputer
    case shutdownComputer
    case retrieveDate
    case compareText
    case specifyText
    case displayTextInputDialog
    case displayFileSelectionDialog
    case takeScreenshot
    case setDesktopBackground
    case retrieveOSName
    case retrieveOSVersion
    case checkTasksRunning
    case deleteTasks
    case disableTasks
    case enableTasks
    case executeTasks
    case stopTasks
    case pauseScheduler
    case resumeScheduler
    case retrieveCurrentTask
    case pauseExecution
    case stopExecution
    case finishExecution
    case displayDialog
    case retrieveEnvironmentVariable
    case executeAppleScript
    case runShortcut
    case showNotification
    case sendHTTPRequest
    case checkFileExists
    case waitForFile
    case checkProcessRunning
    case terminateProcess
    case getClipboardText
    case setClipboardText
    case savePreviousOutput
    case volumeControl

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .shellScript:
            return "Execute shell script"
        case .openURL:
            return "Open URL"
        case .openItem:
            return "Open applications, files and folders"
        case .quitApplication:
            return "Quit an application"
        case .compressItem:
            return "Compress files and folders"
        case .convertLineEndings:
            return "Convert line endings"
        case .copyItem:
            return "Copy files and folders"
        case .createFolder:
            return "Create folders"
        case .decompressItem:
            return "Decompress files and folders"
        case .deleteItem:
            return "Delete files and folders"
        case .emptyTrash:
            return "Empty trash"
        case .lockItem:
            return "Lock files and folders"
        case .moveItem:
            return "Move files and folders"
        case .printItem:
            return "Print files"
        case .renameItem:
            return "Rename files and folders"
        case .replaceTextInFile:
            return "Replace text in files"
        case .retrieveFolderContents:
            return "Retrieve folder contents"
        case .retrieveHomeDirectory:
            return "Retrieve user home directory"
        case .retrieveVolumes:
            return "Retrieve volumes and drives"
        case .unlockItem:
            return "Unlock files and folders"
        case .writeTextFile:
            return "Write text to file"
        case .speakText:
            return "Speak text"
        case .playAudioFile:
            return "Play an audio file"
        case .playAlertSound:
            return "Play alert sound"
        case .checkInternet:
            return "Check Internet connection"
        case .timeMachineStatus:
            return "Check if Time Machine is backing up data"
        case .startTimeMachineBackup:
            return "Start Time Machine backup"
        case .stopTimeMachineBackup:
            return "Stop Time Machine backup"
        case .sleepComputer:
            return "Activate stand by"
        case .restartComputer:
            return "Restart the computer"
        case .shutdownComputer:
            return "Shut down the computer"
        case .retrieveDate:
            return "Retrieve current date and time"
        case .compareText:
            return "Compare text strings"
        case .specifyText:
            return "Specify a text string"
        case .displayTextInputDialog:
            return "Display text input dialog"
        case .displayFileSelectionDialog:
            return "Display file selection dialog"
        case .takeScreenshot:
            return "Take screenshot"
        case .setDesktopBackground:
            return "Set desktop background image"
        case .retrieveOSName:
            return "Retrieve operating system name"
        case .retrieveOSVersion:
            return "Retrieve operating system version"
        case .checkTasksRunning:
            return "Check if tasks are running"
        case .deleteTasks:
            return "Delete tasks"
        case .disableTasks:
            return "Disable tasks"
        case .enableTasks:
            return "Enable tasks"
        case .executeTasks:
            return "Execute tasks"
        case .stopTasks:
            return "Stop tasks"
        case .pauseScheduler:
            return "Pause task scheduler"
        case .resumeScheduler:
            return "Resume task scheduler"
        case .retrieveCurrentTask:
            return "Retrieve current task"
        case .pauseExecution:
            return "Pause execution"
        case .stopExecution:
            return "Stop execution"
        case .finishExecution:
            return "Finish execution"
        case .displayDialog:
            return "Display dialog box"
        case .retrieveEnvironmentVariable:
            return "Retrieve environment variable"
        case .executeAppleScript:
            return "Execute AppleScript"
        case .runShortcut:
            return "Run shortcut"
        case .showNotification:
            return "Show notification"
        case .sendHTTPRequest:
            return "Send HTTP request"
        case .checkFileExists:
            return "Check if file or folder exists"
        case .waitForFile:
            return "Wait for file or folder"
        case .checkProcessRunning:
            return "Check if process is running"
        case .terminateProcess:
            return "Terminate process"
        case .getClipboardText:
            return "Get clipboard text"
        case .setClipboardText:
            return "Set clipboard text"
        case .savePreviousOutput:
            return "Save previous output to file"
        case .volumeControl:
            return "Control system volume"
        }
    }

    @MainActor
    var title: String {
        L(titleKey)
    }

    var symbol: String {
        switch self {
        case .shellScript:
            return "terminal.fill"
        case .openURL:
            return "globe"
        case .openItem:
            return "arrow.up.right.square"
        case .quitApplication:
            return "xmark.app"
        case .compressItem:
            return "archivebox"
        case .convertLineEndings:
            return "line.3.horizontal"
        case .copyItem:
            return "doc.on.doc"
        case .createFolder:
            return "folder.badge.plus"
        case .decompressItem:
            return "archivebox"
        case .deleteItem:
            return "minus.circle.fill"
        case .emptyTrash:
            return "trash.fill"
        case .lockItem:
            return "lock"
        case .moveItem:
            return "arrow.right.doc.on.clipboard"
        case .printItem:
            return "printer"
        case .renameItem:
            return "text.cursor"
        case .replaceTextInFile:
            return "pencil.and.outline"
        case .retrieveFolderContents:
            return "folder.badge.questionmark"
        case .retrieveHomeDirectory:
            return "house"
        case .retrieveVolumes:
            return "externaldrive"
        case .unlockItem:
            return "lock.open"
        case .writeTextFile:
            return "square.and.pencil"
        case .speakText:
            return "speaker.wave.2.fill"
        case .playAudioFile:
            return "speaker.wave.2"
        case .playAlertSound:
            return "speaker.wave.3.fill"
        case .checkInternet:
            return "network"
        case .timeMachineStatus:
            return "clock.arrow.circlepath"
        case .startTimeMachineBackup:
            return "clock.arrow.circlepath"
        case .stopTimeMachineBackup:
            return "stop.circle"
        case .sleepComputer:
            return "moon.zzz.fill"
        case .restartComputer:
            return "arrow.clockwise"
        case .shutdownComputer:
            return "power"
        case .retrieveDate:
            return "calendar"
        case .compareText:
            return "textformat"
        case .specifyText:
            return "textformat.abc"
        case .displayTextInputDialog:
            return "keyboard"
        case .displayFileSelectionDialog:
            return "filemenu.and.selection"
        case .takeScreenshot:
            return "camera.viewfinder"
        case .setDesktopBackground:
            return "photo.on.rectangle"
        case .retrieveOSName:
            return "desktopcomputer"
        case .retrieveOSVersion:
            return "desktopcomputer"
        case .checkTasksRunning:
            return "gearshape.2"
        case .deleteTasks:
            return "minus.circle.fill"
        case .disableTasks:
            return "nosign"
        case .enableTasks:
            return "checkmark.circle"
        case .executeTasks:
            return "play.circle"
        case .stopTasks:
            return "stop.circle"
        case .pauseScheduler:
            return "pause.circle"
        case .resumeScheduler:
            return "play.circle.fill"
        case .retrieveCurrentTask:
            return "person.crop.circle.badge.questionmark"
        case .pauseExecution:
            return "pause.fill"
        case .stopExecution:
            return "stop.circle.fill"
        case .finishExecution:
            return "flag.checkered"
        case .displayDialog:
            return "macwindow"
        case .retrieveEnvironmentVariable:
            return "dollarsign"
        case .executeAppleScript:
            return "scroll"
        case .runShortcut:
            return "sparkles"
        case .showNotification:
            return "bell.badge"
        case .sendHTTPRequest:
            return "arrow.left.arrow.right"
        case .checkFileExists:
            return "doc.badge.magnifyingglass"
        case .waitForFile:
            return "hourglass.badge.plus"
        case .checkProcessRunning:
            return "cpu"
        case .terminateProcess:
            return "xmark.octagon"
        case .getClipboardText:
            return "clipboard"
        case .setClipboardText:
            return "clipboard.fill"
        case .savePreviousOutput:
            return "square.and.arrow.down"
        case .volumeControl:
            return "speaker.wave.2.circle"
        }
    }

    var descriptionKey: String {
        switch self {
        case .shellScript:
            return "Run an inline script or a script file with the selected shell."
        case .openURL:
            return "Open a URL using the default macOS browser."
        case .openItem:
            return "Open an application, file, or folder using macOS Launch Services."
        case .quitApplication:
            return "Quit a running macOS application by name or bundle identifier."
        case .compressItem:
            return "Create a zip archive from a selected file or folder."
        case .convertLineEndings:
            return "Convert a text file to Unix line endings."
        case .copyItem:
            return "Copy a file or folder to another path."
        case .createFolder:
            return "Create a folder with FileManager."
        case .decompressItem:
            return "Extract a zip archive to a selected folder."
        case .deleteItem:
            return "Move a file or folder to the trash."
        case .emptyTrash:
            return "Empty the current user's Trash."
        case .lockItem:
            return "Lock a file or folder with file flags."
        case .moveItem:
            return "Move a file or folder to another path."
        case .printItem:
            return "Send a file to the default printer."
        case .renameItem:
            return "Rename a file or folder in place."
        case .replaceTextInFile:
            return "Replace text inside a UTF-8 text file."
        case .retrieveFolderContents:
            return "Return the contents of a folder."
        case .retrieveHomeDirectory:
            return "Return the current user's home directory."
        case .retrieveVolumes:
            return "Return mounted volumes and drives."
        case .unlockItem:
            return "Unlock a file or folder with file flags."
        case .writeTextFile:
            return "Create or overwrite a text file with FileManager."
        case .speakText:
            return "Speak text with the macOS speech synthesizer."
        case .playAudioFile:
            return "Play a selected audio file with NSSound."
        case .playAlertSound:
            return "Play the system alert sound."
        case .checkInternet:
            return "Check network reachability by requesting a URL."
        case .timeMachineStatus:
            return "Return Time Machine backup status."
        case .startTimeMachineBackup:
            return "Start a Time Machine backup."
        case .stopTimeMachineBackup:
            return "Stop a running Time Machine backup."
        case .sleepComputer:
            return "Put the computer to sleep."
        case .restartComputer:
            return "Restart the computer."
        case .shutdownComputer:
            return "Shut down the computer."
        case .retrieveDate:
            return "Return the current date and time."
        case .compareText:
            return "Compare two text strings."
        case .specifyText:
            return "Return a configured text string."
        case .displayTextInputDialog:
            return "Show a text input dialog and return the entered text."
        case .displayFileSelectionDialog:
            return "Show a file selection dialog and return the selected path."
        case .takeScreenshot:
            return "Take a screenshot to a selected file path."
        case .setDesktopBackground:
            return "Set the desktop background to a selected image."
        case .retrieveOSName:
            return "Return the operating system name."
        case .retrieveOSVersion:
            return "Return the operating system version."
        case .checkTasksRunning:
            return "Return whether this app is currently running workflow actions."
        case .deleteTasks:
            return "Delete tasks by name."
        case .disableTasks:
            return "Disable tasks by name."
        case .enableTasks:
            return "Enable tasks by name."
        case .executeTasks:
            return "Run tasks by name. Starts only tasks that allow being triggered by another task."
        case .stopTasks:
            return "Stop running tasks by name."
        case .pauseScheduler:
            return "Pause the task scheduler."
        case .resumeScheduler:
            return "Resume the task scheduler."
        case .retrieveCurrentTask:
            return "Return the name of the task running this workflow."
        case .pauseExecution:
            return "Pause the workflow for a fixed number of seconds."
        case .stopExecution:
            return "Stop the workflow at this step."
        case .finishExecution:
            return "Finish the workflow successfully at this step."
        case .displayDialog:
            return "Show a simple modal dialog."
        case .retrieveEnvironmentVariable:
            return "Read an environment variable from the app process."
        case .executeAppleScript:
            return "Run an AppleScript source string with osascript."
        case .runShortcut:
            return "Run a macOS Shortcut by name."
        case .showNotification:
            return "Show a macOS notification."
        case .sendHTTPRequest:
            return "Send an HTTP request and return the response status and body."
        case .checkFileExists:
            return "Check whether a file or folder exists."
        case .waitForFile:
            return "Wait until a file or folder exists or the timeout expires."
        case .checkProcessRunning:
            return "Check whether a process is running by PID or name."
        case .terminateProcess:
            return "Terminate a process by PID or name."
        case .getClipboardText:
            return "Read text from the system clipboard."
        case .setClipboardText:
            return "Write text to the system clipboard."
        case .savePreviousOutput:
            return "Write the previous workflow action output to a file."
        case .volumeControl:
            return "Set, change, mute, or unmute the system output volume."
        }
    }

    @MainActor
    var description: String {
        L(descriptionKey)
    }
}

extension TaskActionType {
    /// Actions that start a process and therefore honor the step time limit.
    nonisolated var runsProcess: Bool {
        switch self {
        case .shellScript, .executeAppleScript, .runShortcut:
            return true
        default:
            return false
        }
    }

    /// Condition actions: an unmet condition is not an error (see `ConditionPolicy`).
    nonisolated var isCondition: Bool {
        switch self {
        case .checkFileExists, .checkInternet, .checkProcessRunning, .checkTasksRunning, .compareText, .timeMachineStatus:
            return true
        default:
            return false
        }
    }
}
