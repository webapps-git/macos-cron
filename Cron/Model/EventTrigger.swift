import Darwin
import Foundation

/// Kinds of events that can start a task.
nonisolated enum EventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case appLaunch
    case systemWake
    /// Shortly before the Mac goes to sleep (macOS waits at most about 30 seconds).
    case beforeSleep
    case screenWake
    case screenSleep
    case screenLocked
    case screenUnlocked
    case screenConnected
    case screenDisconnected
    case screenResolutionChanged
    case volumeMounted
    case volumeUnmounted
    /// A file in a folder was created, changed or deleted (`EventTrigger` folder fields).
    case folder
    /// A chosen application was launched or quit.
    case application
    case networkConnected
    case networkDisconnected
    case networkChanged
    case powerAdapter
    case batteryPower
    /// The battery dropped below `EventTrigger.batteryPercent`.
    case batteryLow
    /// No user input for `EventTrigger.idleMinutes`, or input again after that.
    case idle
    /// Another task ran the "Execute tasks" action naming this task.
    case triggeredByTask
    case otherTaskStarted
    case otherTaskCancelled
    case otherTaskFinished

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .appLaunch:
            return "When Cron starts"
        case .systemWake:
            return "When the system awakes from sleep mode"
        case .beforeSleep:
            return "Before the Mac goes to sleep"
        case .screenWake:
            return "When the screen wakes up"
        case .screenSleep:
            return "When the screen goes to sleep"
        case .screenLocked:
            return "When the screen is locked"
        case .screenUnlocked:
            return "When the screen is unlocked"
        case .screenConnected:
            return "When a screen is connected"
        case .screenDisconnected:
            return "When a screen is disconnected"
        case .screenResolutionChanged:
            return "When the screen resolution changes"
        case .volumeMounted:
            return "When volumes are inserted or drives are connected"
        case .volumeUnmounted:
            return "When volumes are ejected or drives are disconnected"
        case .folder:
            return "When files in a folder change"
        case .application:
            return "When an application is launched or quit"
        case .networkConnected:
            return "When the network connection is established"
        case .networkDisconnected:
            return "When the network connection is lost"
        case .networkChanged:
            return "When the network changes"
        case .powerAdapter:
            return "When the power adapter is connected"
        case .batteryPower:
            return "When the Mac switches to battery power"
        case .batteryLow:
            return "When the battery level drops below"
        case .idle:
            return "When the Mac is idle"
        case .triggeredByTask:
            return "When another task triggers this task"
        case .otherTaskStarted:
            return "When another task is executed"
        case .otherTaskCancelled:
            return "When the execution of another task is cancelled"
        case .otherTaskFinished:
            return "When the execution of another task stops"
        }
    }

    /// Kinds configured with parameters; a task may have several triggers of these kinds.
    var hasParameters: Bool {
        switch self {
        case .folder, .application, .batteryLow, .idle:
            return true
        default:
            return false
        }
    }
}

nonisolated enum FileChange: String, Codable, Sendable {
    case created
    case modified
    case removed
}

/// Which results of another task start this task ("When the execution of another task stops").
nonisolated enum TaskOutcomeFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case any
    /// Succeeded or condition not met.
    case succeeded
    /// Failed or time limit exceeded.
    case failed

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .any:
            return "With any result"
        case .succeeded:
            return "Successfully"
        case .failed:
            return "With an error"
        }
    }

    func matches(_ outcome: RunOutcome?) -> Bool {
        switch self {
        case .any:
            return true
        case .succeeded:
            return outcome == .succeeded || outcome == .conditionNotMet
        case .failed:
            return outcome == .failed || outcome == .timedOut
        }
    }
}

/// One event that starts a task. Parameters are defaulted fields, so triggers stored by older
/// versions decode unchanged (`DefaultDecoding`); each kind uses only its own fields.
nonisolated struct EventTrigger: DefaultDecodable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var kind = EventKind.appLaunch

    // .folder
    var folderPath = ""
    /// Glob patterns separated by commas, e.g. `*.pdf, *.jpg`; empty = every file.
    var namePattern = ""
    var includeSubfolders = false
    var onCreated = true
    var onModified = false
    var onRemoved = false
    /// Waits until the file stops changing (copy finished) before the task starts.
    var waitUntilStable = true

    // .application
    var appBundleID = ""
    var appName = ""
    var onLaunch = true
    var onQuit = false

    // .batteryLow
    var batteryPercent = 20

    // .idle
    var idleMinutes = 10
    var onIdleStart = true
    var onIdleEnd = false

    // .otherTaskStarted, .otherTaskCancelled, .otherTaskFinished
    /// Names of the tasks to react to; empty = any other task.
    var taskNames: [String] = []
    /// Only for `.otherTaskFinished`.
    var taskOutcome = TaskOutcomeFilter.any

    init() {}

    init(kind: EventKind) {
        self.kind = kind
    }

    func matches(_ occurrence: EventOccurrence) -> Bool {
        guard occurrence.kind == kind else {
            return false
        }

        switch occurrence.detail {
        case .none:
            return true
        case .file(let path, let change):
            return matchesFile(path: path, change: change)
        case .application(let bundleID, let name, let launched):
            guard launched ? onLaunch : onQuit else {
                return false
            }

            if !appBundleID.trimmed.isEmpty {
                return appBundleID.trimmed.caseInsensitiveCompare(bundleID) == .orderedSame
            }

            return !appName.trimmed.isEmpty && appName.trimmed.caseInsensitiveCompare(name) == .orderedSame
        case .battery(let previous, let current):
            // Once per discharge: only when the level crosses the threshold downwards.
            return previous >= batteryPercent && current < batteryPercent
        case .idle(let previous, let current):
            let threshold = TimeInterval(max(1, idleMinutes) * 60)

            if onIdleStart, previous < threshold, current >= threshold {
                return true
            }

            // Input again (the idle time went back) after an idle period of at least the threshold.
            return onIdleEnd && previous >= threshold && current < previous && current < threshold
        case .task(let name, let outcome):
            let names = taskNames.map(\.trimmed).filter { !$0.isEmpty }

            if !names.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                return false
            }

            return kind != .otherTaskFinished || taskOutcome.matches(outcome)
        }
    }

    private func matchesFile(path: String, change: FileChange) -> Bool {
        switch change {
        case .created where !onCreated, .modified where !onModified, .removed where !onRemoved:
            return false
        default:
            break
        }

        let root = FolderPath.normalized(folderPath)

        guard !root.isEmpty, path.hasPrefix(root + "/") else {
            return false
        }

        let relative = path.dropFirst(root.count + 1)

        if !includeSubfolders, relative.contains("/") {
            return false
        }

        return FolderPath.matches(name: (path as NSString).lastPathComponent, patterns: namePattern)
    }
}

nonisolated enum FolderPath {
    /// Absolute path without `~`, trailing slash and symbolic links, as FSEvents reports it
    /// (e.g. `/private/tmp` for `/tmp`). `realpath` is used because `resolvingSymlinksInPath`
    /// removes a leading `/private` again.
    static func normalized(_ path: String) -> String {
        let trimmed = path.trimmed

        guard !trimmed.isEmpty else {
            return ""
        }

        let standardized = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path

        guard let resolved = realpath(standardized, nil) else {
            return standardized
        }

        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Case-insensitive glob match against any of the comma-separated `patterns`; empty matches all.
    static func matches(name: String, patterns: String) -> Bool {
        let list = patterns.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }

        guard !list.isEmpty else {
            return true
        }

        return list.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }
}

/// Something that happened and may start tasks (`EventTrigger.matches`).
nonisolated struct EventOccurrence: Sendable {
    enum Detail: Sendable {
        case none
        case file(path: String, change: FileChange)
        case application(bundleID: String, name: String, launched: Bool)
        /// Battery level in percent before and after the change.
        case battery(previous: Int, current: Int)
        /// Seconds without user input at the previous and at this check.
        case idle(previous: TimeInterval, current: TimeInterval)
        case task(name: String, outcome: RunOutcome?)
    }

    var kind: EventKind
    var detail = Detail.none

    init(kind: EventKind, detail: Detail = .none) {
        self.kind = kind
        self.detail = detail
    }

    /// File path for `{file}` / `CRON_FILE`.
    var file: String {
        if case .file(let path, _) = detail {
            return path
        }

        return ""
    }

    /// Application name for `{app}` / `CRON_APP`.
    var app: String {
        if case .application(_, let name, _) = detail {
            return name
        }

        return ""
    }

    /// Shown as the run reason.
    var reasonKey: String {
        switch (kind, detail) {
        case (.folder, .file(_, .created)):
            return "File created"
        case (.folder, .file(_, .modified)):
            return "File changed"
        case (.folder, .file(_, .removed)):
            return "File deleted"
        case (.application, .application(_, _, true)):
            return "Application launched"
        case (.application, .application(_, _, false)):
            return "Application quit"
        case (.idle, .idle(let previous, let current)) where current < previous:
            return "Back from idle"
        default:
            return kind.reasonKey
        }
    }

    @MainActor
    var reason: String {
        switch detail {
        case .file(let path, _):
            return "\(L(reasonKey)): \((path as NSString).lastPathComponent)"
        case .application(_, let name, _):
            return "\(L(reasonKey)): \(name)"
        default:
            return L(reasonKey)
        }
    }
}

nonisolated extension EventKind {
    /// Shown as the run reason.
    var reasonKey: String {
        switch self {
        case .appLaunch:
            return "App launch"
        case .systemWake:
            return "System wake"
        case .beforeSleep:
            return "Before sleep"
        case .screenWake:
            return "Screen wake"
        case .screenSleep:
            return "Screen sleep"
        case .screenLocked:
            return "Screen locked"
        case .screenUnlocked:
            return "Screen unlocked"
        case .screenConnected, .screenDisconnected, .screenResolutionChanged:
            return "Screen configuration changed"
        case .volumeMounted:
            return "Volume mounted"
        case .volumeUnmounted:
            return "Volume unmounted"
        case .folder:
            return "File changed"
        case .application:
            return "Application launched"
        case .networkConnected:
            return "Network connected"
        case .networkDisconnected:
            return "Network lost"
        case .networkChanged:
            return "Network changed"
        case .powerAdapter:
            return "Power adapter connected"
        case .batteryPower:
            return "Battery power"
        case .batteryLow:
            return "Battery low"
        case .idle:
            return "Idle"
        case .triggeredByTask:
            return "Another task triggered"
        case .otherTaskStarted:
            return "Another task executed"
        case .otherTaskCancelled:
            return "Another task cancelled"
        case .otherTaskFinished:
            return "Another task stopped"
        }
    }

    @MainActor
    var reason: String {
        L(reasonKey)
    }
}
