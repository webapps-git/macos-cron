import AppKit
import CoreGraphics
import CoreServices
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Network
import SystemConfiguration

/// System event sources that are not plain notifications: folders (FSEvents), network, power,
/// idle time, screen lock and sleep. Events from the time Cron was not running are not delivered.
@MainActor
final class EventMonitors {
    private let onEvent: (EventOccurrence) -> Void
    private var folderWatchers: [String: FolderWatcher] = [:]
    private lazy var network = NetworkMonitor { [weak self] kind in self?.onEvent(EventOccurrence(kind: kind)) }
    private lazy var power = PowerMonitor { [weak self] occurrence in self?.onEvent(occurrence) }
    private lazy var idle = IdleMonitor { [weak self] occurrence in self?.onEvent(occurrence) }
    private lazy var screenLock = ScreenLockMonitor { [weak self] kind in self?.onEvent(EventOccurrence(kind: kind)) }
    private let sleep: SleepMonitor

    /// `onWillSleep` gets a completion to call when the Mac may go to sleep.
    init(onEvent: @escaping (EventOccurrence) -> Void, onWillSleep: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.onEvent = onEvent
        self.sleep = SleepMonitor(onWillSleep: onWillSleep)
    }

    func start() {
        network.start()
        power.start()
        screenLock.start()
        sleep.start()
    }

    /// Watches exactly `folderRoots` (normalized paths) and polls idle time only when a task needs it.
    func update(folderRoots: Set<String>, watchesIdle: Bool) {
        let existing = Set(folderRoots.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        })

        for root in Set(folderWatchers.keys).subtracting(existing) {
            folderWatchers[root]?.stop()
            folderWatchers[root] = nil
        }

        for root in existing.subtracting(folderWatchers.keys) {
            let watcher = FolderWatcher(root: root) { [weak self] path, change in
                self?.onEvent(EventOccurrence(kind: .folder, detail: .file(path: path, change: change)))
            }

            if watcher.start() {
                folderWatchers[root] = watcher
            }
        }

        idle.setActive(watchesIdle)
    }
}

// MARK: - Folders

/// FSEvents stream with file-level events for one folder and its subfolders.
@MainActor
final class FolderWatcher {
    private static let knownPathLimit = 10_000

    let root: String
    private let onChange: (String, FileChange) -> Void
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    /// Files already reported as created. FSEvents can repeat the "created" flag in later events
    /// for the same file, which then are modifications.
    private var knownPaths: Set<String> = []

    init(root: String, onChange: @escaping (String, FileChange) -> Void) {
        self.root = root
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    func start() -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            folderEventCallback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)

        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }

        self.stream = stream
        return true
    }

    func stop() {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            // Files only, without hidden ones (.DS_Store and the like change all the time).
            guard flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0,
                  !(path as NSString).lastPathComponent.hasPrefix(".") else {
                continue
            }

            if let change = change(path: path, flag: flag) {
                onChange(path, change)
            }
        }
    }

    private func change(path: String, flag: FSEventStreamEventFlags) -> FileChange? {
        // Flags of several changes can be combined in one event, so the file's current state decides.
        guard FileManager.default.fileExists(atPath: path) else {
            knownPaths.remove(path)
            return .removed
        }

        let createdOrMovedIn = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed)

        if flag & createdOrMovedIn != 0, !knownPaths.contains(path) {
            if knownPaths.count >= Self.knownPathLimit {
                knownPaths.removeAll()
            }

            knownPaths.insert(path)
            return .created
        }

        if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified) != 0 {
            return .modified
        }

        return nil
    }
}

private nonisolated func folderEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ count: Int,
    _ paths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else {
        return
    }

    // With kFSEventStreamCreateFlagUseCFTypes the paths are a CFArray of CFString.
    let pathList = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
    let flagList = Array(UnsafeBufferPointer(start: flags, count: count))

    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()

    // The stream is scheduled on the main queue.
    MainActor.assumeIsolated {
        watcher.handle(paths: pathList, flags: flagList)
    }
}

/// Waits until a file stops changing (e.g. a copy finished) before a task processes it.
nonisolated enum FileStability {
    /// `true` when the size and modification date stayed the same for `quietSeconds`
    /// (or `timeout` passed); `false` when the file disappeared or the wait was cancelled.
    @concurrent
    static func waitUntilStable(_ path: String, quietSeconds: Int = 3, timeout: TimeInterval = 600) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last: (UInt64, Date)?
        var quiet = 0

        while Date() < deadline {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return false
            }

            let snapshot = (
                (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                attributes[.modificationDate] as? Date ?? .distantPast
            )

            if let last, last == snapshot {
                quiet += 1

                if quiet >= quietSeconds {
                    return true
                }
            } else {
                quiet = 0
            }

            last = snapshot

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return false
            }
        }

        return true
    }
}

// MARK: - Network

/// Connection established / lost (NWPathMonitor) and network changed (primary interface or
/// router, SCDynamicStore `State:/Network/Global/IPv4`). Changes settle for 5 seconds, so one
/// Wi-Fi switch does not start a task several times.
@MainActor
final class NetworkMonitor {
    private static let globalIPv4Key = "State:/Network/Global/IPv4"
    private static let settleNanoseconds: UInt64 = 5_000_000_000

    private let onEvent: (EventKind) -> Void
    private let monitor = NWPathMonitor()
    nonisolated(unsafe) private var store: SCDynamicStore?
    private var isConnected = false
    private var reportedConnected: Bool?
    private var reportedSignature: String?
    private var settleTask: Task<Void, Never>?

    init(onEvent: @escaping (EventKind) -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        monitor.cancel()

        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied

            MainActor.assumeIsolated {
                self?.pathChanged(connected: connected)
            }
        }
        monitor.start(queue: .main)

        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)

        if let store = SCDynamicStoreCreate(nil, "Cron" as CFString, networkStoreCallback, &context) {
            SCDynamicStoreSetNotificationKeys(store, [Self.globalIPv4Key] as CFArray, nil)
            SCDynamicStoreSetDispatchQueue(store, .main)
            self.store = store
            reportedSignature = currentSignature()
        }
    }

    private func pathChanged(connected: Bool) {
        isConnected = connected

        // The first update describes the state at start, not a change (Apple Developer Forums 687477).
        guard reportedConnected != nil else {
            reportedConnected = connected
            return
        }

        scheduleSettle()
    }

    fileprivate func storeChanged() {
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settleNanoseconds)

            guard !Task.isCancelled else {
                return
            }

            self?.settle()
        }
    }

    private func settle() {
        if let reportedConnected, reportedConnected != isConnected {
            self.reportedConnected = isConnected
            onEvent(isConnected ? .networkConnected : .networkDisconnected)
        }

        if let signature = currentSignature() {
            if let reportedSignature, reportedSignature != signature {
                onEvent(.networkChanged)
            }

            reportedSignature = signature
        }
    }

    /// Primary interface, service and router; `nil` while there is no IPv4 network.
    private func currentSignature() -> String? {
        guard let store, let value = SCDynamicStoreCopyValue(store, Self.globalIPv4Key as CFString) as? [String: Any] else {
            return nil
        }

        let interface = value["PrimaryInterface"] as? String ?? ""
        let service = value["PrimaryService"] as? String ?? ""
        let router = value["Router"] as? String ?? ""
        return "\(interface)|\(service)|\(router)"
    }
}

private nonisolated func networkStoreCallback(_ store: SCDynamicStore, _ keys: CFArray, _ info: UnsafeMutableRawPointer?) {
    guard let info else {
        return
    }

    let monitor = Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue()

    // The store is scheduled on the main queue.
    MainActor.assumeIsolated {
        monitor.storeChanged()
    }
}

// MARK: - Power

/// Power adapter / battery (IOPowerSources) and battery level for "battery below X%".
@MainActor
final class PowerMonitor {
    private let onEvent: (EventOccurrence) -> Void
    nonisolated(unsafe) private var source: CFRunLoopSource?
    private var lastSourceType: String?
    private var lastPercent: Int?

    init(onEvent: @escaping (EventOccurrence) -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?.takeRetainedValue() else {
            return
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        (lastSourceType, lastPercent) = Self.readState()
    }

    fileprivate func changed() {
        let (sourceType, percent) = Self.readState()

        if let sourceType, let lastSourceType, sourceType != lastSourceType {
            if sourceType == kIOPSACPowerValue {
                onEvent(EventOccurrence(kind: .powerAdapter))
            } else if sourceType == kIOPSBatteryPowerValue {
                onEvent(EventOccurrence(kind: .batteryPower))
            }
        }

        if let percent, let lastPercent, percent != lastPercent, sourceType == kIOPSBatteryPowerValue {
            onEvent(EventOccurrence(kind: .batteryLow, detail: .battery(previous: lastPercent, current: percent)))
        }

        lastSourceType = sourceType ?? lastSourceType
        lastPercent = percent ?? lastPercent
    }

    /// Providing power source ("AC Power", "Battery Power", …) and internal battery level in percent
    /// (`nil` on a Mac without a battery).
    private static func readState() -> (String?, Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return (nil, nil)
        }

        let sourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Int?

        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for powerSource in list {
                guard
                    let description = IOPSGetPowerSourceDescription(info, powerSource)?.takeUnretainedValue() as? [String: Any],
                    description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                    let current = description[kIOPSCurrentCapacityKey] as? Int,
                    let maximum = description[kIOPSMaxCapacityKey] as? Int,
                    maximum > 0
                else {
                    continue
                }

                percent = current * 100 / maximum
            }
        }

        return (sourceType, percent)
    }
}

private nonisolated func powerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else {
        return
    }

    let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()

    // The run loop source is added to the main run loop.
    MainActor.assumeIsolated {
        monitor.changed()
    }
}

// MARK: - Idle

/// Time since the last keyboard, mouse or trackpad input. There is no notification for it, so it
/// is read once a minute, and every 5 seconds while the user is away, to notice the return quickly.
@MainActor
final class IdleMonitor {
    private let onEvent: (EventOccurrence) -> Void
    nonisolated(unsafe) private var timer: Timer?
    private var lastIdleSeconds: TimeInterval = 0

    init(onEvent: @escaping (EventOccurrence) -> Void) {
        self.onEvent = onEvent
    }

    deinit {
        timer?.invalidate()
    }

    func setActive(_ active: Bool) {
        if active, timer == nil {
            lastIdleSeconds = Self.idleSeconds()
            schedule(after: 60)
        } else if !active {
            timer?.invalidate()
            timer = nil
        }
    }

    private func schedule(after seconds: TimeInterval) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.check()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        guard timer != nil else {
            return
        }

        let idleSeconds = Self.idleSeconds()
        onEvent(EventOccurrence(kind: .idle, detail: .idle(previous: lastIdleSeconds, current: idleSeconds)))
        lastIdleSeconds = idleSeconds
        schedule(after: idleSeconds >= 55 ? 5 : 60)
    }

    private static func idleSeconds() -> TimeInterval {
        // kCGAnyInputEventType (~0); no permission needed.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

// MARK: - Screen lock

/// `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` are not documented by Apple but widely
/// used. `.deliverImmediately` is required: Cron is usually not the active app, and otherwise the
/// lock notification would arrive only after unlocking.
@MainActor
final class ScreenLockMonitor: NSObject {
    private let onEvent: (EventKind) -> Void

    init(onEvent: @escaping (EventKind) -> Void) {
        self.onEvent = onEvent
    }

    func start() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"), object: nil, suspensionBehavior: .deliverImmediately)
        center.addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func screenLocked() {
        onEvent(.screenLocked)
    }

    @objc private func screenUnlocked() {
        onEvent(.screenUnlocked)
    }
}

// MARK: - Sleep

/// "Before sleep" (Apple QA1340). macOS waits up to 30 seconds for an answer to
/// kIOMessageSystemWillSleep and cannot be stopped from sleeping; idle sleep is never vetoed.
@MainActor
final class SleepMonitor {
    // iokit_common_msg(…) values from IOMessage.h (the macros are not available in Swift).
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280

    private let onWillSleep: (@escaping @MainActor () -> Void) -> Void
    nonisolated(unsafe) private var rootPort: io_connect_t = 0
    nonisolated(unsafe) private var notifyPort: IONotificationPortRef?
    nonisolated(unsafe) private var notifier: io_object_t = 0

    init(onWillSleep: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.onWillSleep = onWillSleep
    }

    deinit {
        if rootPort != 0 {
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
        }

        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
        }
    }

    func start() {
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notifyPort, systemPowerCallback, &notifier)

        guard rootPort != 0, let notifyPort else {
            return
        }

        IONotificationPortSetDispatchQueue(notifyPort, .main)
    }

    /// `notificationID` is the message argument, needed to answer the message.
    fileprivate func handle(messageType: natural_t, notificationID: Int) {
        let rootPort = rootPort

        switch messageType {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case Self.systemWillSleep:
            var answered = false
            onWillSleep {
                guard !answered else {
                    return
                }

                answered = true
                IOAllowPowerChange(rootPort, notificationID)
            }
        default:
            break
        }
    }
}

private nonisolated func systemPowerCallback(_ refcon: UnsafeMutableRawPointer?, _ service: io_service_t, _ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
    guard let refcon else {
        return
    }

    let monitor = Unmanaged<SleepMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let notificationID = Int(bitPattern: argument)

    // The notification port is scheduled on the main queue.
    MainActor.assumeIsolated {
        monitor.handle(messageType: messageType, notificationID: notificationID)
    }
}
