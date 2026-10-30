import AppKit
import SwiftData
import SwiftUI

struct ActionCatalogCategory: Identifiable, Hashable {
    var id: String
    var titleKey: String
    var symbol: String

    var title: String {
        L(titleKey)
    }
}

struct ActionCatalogItem: Identifiable, Hashable {
    var id: String
    var categoryIDs: [String]
    var actionType: TaskActionType
    var titleKey: String
    var symbol: String
    var descriptionKey: String

    var title: String {
        L(titleKey)
    }

    var description: String {
        L(descriptionKey)
    }

    func belongs(to categoryID: String) -> Bool {
        categoryIDs.contains(categoryID)
    }

    var categoryTitles: String {
        categoryIDs.map { ActionCatalog.categoryTitle(for: $0) }.joined(separator: " / ")
    }
}

enum ActionCatalog {
    static let libraryID = "library"

    static let categories = [
        ActionCatalogCategory(id: libraryID, titleKey: "Library", symbol: "books.vertical.fill"),
        ActionCatalogCategory(id: "applications", titleKey: "Applications", symbol: "app.dashed"),
        ActionCatalogCategory(id: "audio", titleKey: "Audio", symbol: "speaker.wave.2.fill"),
        ActionCatalogCategory(id: "backup", titleKey: "Backup", symbol: "clock.arrow.circlepath"),
        ActionCatalogCategory(id: "conditions", titleKey: "Conditions", symbol: "checkmark.circle"),
        ActionCatalogCategory(id: "date", titleKey: "Date and time", symbol: "calendar"),
        ActionCatalogCategory(id: "files", titleKey: "Files and folders", symbol: "folder"),
        ActionCatalogCategory(id: "flow", titleKey: "Flow control", symbol: "arrow.triangle.branch"),
        ActionCatalogCategory(id: "image", titleKey: "Image processing", symbol: "photo"),
        ActionCatalogCategory(id: "interactions", titleKey: "Interactions", symbol: "macwindow"),
        ActionCatalogCategory(id: "internet", titleKey: "Internet & network", symbol: "network"),
        ActionCatalogCategory(id: "system", titleKey: "System", symbol: "desktopcomputer"),
        ActionCatalogCategory(id: "tasks", titleKey: "Tasks", symbol: "gearshape.2"),
        ActionCatalogCategory(id: "text", titleKey: "Text", symbol: "textformat"),
        ActionCatalogCategory(id: "variables", titleKey: "Variables", symbol: "curlybraces")
    ]

    static let items = [
        item("open-app-file-folder", ["applications", "files"], .openItem),
        item("execute-applescript", ["applications", "system"], .executeAppleScript),
        item("quit-application", ["applications"], .quitApplication),
        item("run-shortcut", ["applications", "system"], .runShortcut),

        item("play-alert-sound", ["audio"], .playAlertSound),
        item("play-audio-file", ["audio"], .playAudioFile),
        item("speak-text-audio", ["audio", "text"], .speakText),
        item("control-system-volume", ["audio", "system"], .volumeControl),

        item("check-time-machine", ["backup", "conditions", "system"], .timeMachineStatus),
        item("copy-files-backup", ["backup", "files"], .copyItem),
        item("start-time-machine", ["backup"], .startTimeMachineBackup),
        item("stop-time-machine", ["backup"], .stopTimeMachineBackup),

        item("check-internet-condition", ["conditions", "internet"], .checkInternet),
        item("check-file-exists", ["conditions", "files"], .checkFileExists),
        item("check-process-running", ["conditions", "system"], .checkProcessRunning),
        item("check-tasks-running-condition", ["conditions", "tasks"], .checkTasksRunning),
        item("compare-text-strings-condition", ["conditions", "text"], .compareText),

        item("retrieve-date", ["date", "variables"], .retrieveDate),


        item("compress-files", ["files"], .compressItem),
        item("convert-line-endings", ["files"], .convertLineEndings),
        item("create-files", ["files"], .writeTextFile, "Create files"),
        item("create-folders", ["files"], .createFolder),
        item("decompress-files", ["files"], .decompressItem),
        item("delete-files", ["files"], .deleteItem),
        item("display-file-selection", ["files", "interactions"], .displayFileSelectionDialog),
        item("duplicate-files", ["files"], .copyItem, "Duplicate files and folders"),
        item("empty-trash", ["files", "system"], .emptyTrash),
        item("lock-files", ["files"], .lockItem),
        item("move-files", ["files"], .moveItem),
        item("print-files", ["files"], .printItem),
        item("rename-files", ["files"], .renameItem),
        item("replace-text-files", ["files", "text"], .replaceTextInFile),
        item("retrieve-folder-contents", ["files"], .retrieveFolderContents),
        item("retrieve-home-files", ["files", "variables"], .retrieveHomeDirectory),
        item("retrieve-volumes-files", ["files", "variables"], .retrieveVolumes),
        item("unlock-files", ["files"], .unlockItem),
        item("wait-for-file", ["files", "flow"], .waitForFile),
        item("save-previous-output", ["files", "text"], .savePreviousOutput),
        item("write-text-file-files", ["files", "text"], .writeTextFile),

        item("finish-execution", ["flow"], .finishExecution),
        item("pause-execution", ["flow"], .pauseExecution),
        item("stop-execution", ["flow"], .stopExecution),

        item("set-desktop-background-image", ["image", "system"], .setDesktopBackground),
        item("take-screenshot", ["image", "system"], .takeScreenshot),

        item("display-dialog", ["interactions"], .displayDialog),
        item("display-text-input", ["interactions", "text"], .displayTextInputDialog),
        item("get-clipboard-text", ["interactions", "text", "variables"], .getClipboardText),
        item("set-clipboard-text", ["interactions", "text"], .setClipboardText),
        item("show-notification", ["interactions", "system"], .showNotification),

        item("open-url", ["internet", "system"], .openURL),
        item("send-http-request", ["internet"], .sendHTTPRequest),

        item("execute-shell-script", ["system"], .shellScript),
        item("activate-stand-by", ["system"], .sleepComputer),
        item("restart-computer", ["system"], .restartComputer),
        item("retrieve-env-system", ["system", "variables"], .retrieveEnvironmentVariable),
        item("retrieve-os-name", ["system", "variables"], .retrieveOSName),
        item("retrieve-os-version", ["system", "variables"], .retrieveOSVersion),
        item("shutdown-computer", ["system"], .shutdownComputer),
        item("terminate-process", ["system"], .terminateProcess),

        item("delete-tasks", ["tasks"], .deleteTasks),
        item("disable-tasks", ["tasks"], .disableTasks),
        item("enable-tasks", ["tasks"], .enableTasks),
        item("execute-tasks", ["tasks"], .executeTasks),
        item("pause-task-scheduler", ["tasks"], .pauseScheduler),
        item("resume-task-scheduler", ["tasks"], .resumeScheduler),
        item("retrieve-current-task", ["tasks", "variables"], .retrieveCurrentTask),
        item("stop-tasks", ["tasks"], .stopTasks),

        item("specify-text", ["text"], .specifyText),

    ]

    private static func item(
        _ id: String,
        _ categoryIDs: [String],
        _ actionType: TaskActionType,
        _ title: String? = nil,
        _ symbol: String? = nil,
        _ description: String? = nil
    ) -> ActionCatalogItem {
        ActionCatalogItem(
            id: id,
            categoryIDs: categoryIDs,
            actionType: actionType,
            titleKey: title ?? actionType.titleKey,
            symbol: symbol ?? actionType.symbol,
            descriptionKey: description ?? actionType.descriptionKey
        )
    }

    static func categoryTitle(for id: String) -> String {
        categories.first(where: { $0.id == id })?.title ?? L("Library")
    }
}
