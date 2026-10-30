import AppKit
import Combine
import Foundation
import SwiftData
import UserNotifications

@MainActor
final class TaskRuntime: ObservableObject {
    @Published private(set) var runningJobIDs: Set<UUID> = []
    @Published private(set) var lastRuntimeMessage = L("Ready")
    /// The most recent failed run, shown in the menu bar until that task succeeds or it is opened.
    @Published private(set) var lastFailure: FailureRecord?
    /// Set to show a task's history in the main window (menu bar, notification buttons).
    @Published var navigationRequest: NavigationRequest?
    /// Changed to open the main window (Cron opened again from Finder or Spotlight).
    @Published private(set) var mainWindowRequest = UUID()
    @Published var storeRecoveryNotice: String?
    @Published var isSchedulerPaused: Bool {
        didSet {
            defaults.set(isSchedulerPaused, forKey: AppSettingsKeys.schedulerPaused)
            lastRuntimeMessage = isSchedulerPaused ? L("Scheduler paused") : L("Ready")
        }
    }

    private var didTriggerLaunch = false
    private let modelContainer: ModelContainer?
    private let defaults: UserDefaults
    // nonisolated(unsafe): written only on the main actor; deinit reads them after the last
    // reference is gone, so there is no concurrent access. (isolated deinit needs macOS 15.4.)
    nonisolated(unsafe) private var scheduleTimer: Timer?
    nonisolated(unsafe) private var workspaceObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private var applicationObservers: [NSObjectProtocol] = []
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var sleepPreventingJobIDs: Set<UUID> = []
    private var activityToken: NSObjectProtocol?
    private var activityPreventsSleep = false
    private var screenSnapshot = ScreenSnapshot.current()
    private var eventMonitors: EventMonitors?
    private var monitorRefreshTask: Task<Void, Never>?
    /// Folder events that arrived while their task was running, started one by one afterwards.
    private var folderEventQueues: [UUID: [(occurrence: EventOccurrence, chain: Set<UUID>)]] = [:]
    private var reportedFullQueues: Set<UUID> = []
    /// "job ID|path" of files waiting to stop changing before their task starts.
    private var filesWaitingToSettle: Set<String> = []

    /// A scheduled time counts as missed when the check comes later than this
    /// (one regular check interval plus tolerance).
    static let missedRunThreshold: TimeInterval = 90
    static let folderEventQueueLimit = 100
    /// "Before sleep" tasks get this long before Cron lets the Mac sleep (macOS waits at most 30 s).
    static let beforeSleepTimeLimit: TimeInterval = 25

    init(modelContainer: ModelContainer? = nil, storeRecoveryNotice: String? = nil, defaults: UserDefaults = .standard) {
        self.modelContainer = modelContainer
        self.storeRecoveryNotice = storeRecoveryNotice
        self.defaults = defaults
        self.isSchedulerPaused = defaults.bool(forKey: AppSettingsKeys.schedulerPaused)
    }

    deinit {
        scheduleTimer?.invalidate()

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        for observer in applicationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func isRunning(_ job: ScheduledJob) -> Bool {
        runningJobIDs.contains(job.id)
    }

    func startBackgroundScheduling() {
        guard scheduleTimer == nil else {
            return
        }

        if let storeRecoveryNotice {
            Task {
                await TaskCompletionNotifier.show(title: "Cron", body: storeRecoveryNotice)
            }
        }

        pruneAllHistory()
        triggerLaunchOnceFromStore()
        evaluateScheduleFromStore()

        // Checks run once a minute, right after each full minute (scheduling has minute precision).
        // `.common` keeps the timer firing while a menu is open or a modal dialog is shown.
        let firstFire = Self.nextFullMinute(after: Date()).addingTimeInterval(0.5)
        let timer = Timer(fire: firstFire, interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleTimerFired()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer

        installObservers()
        startEventMonitors()
    }

    private func scheduleTimerFired() {
        evaluateScheduleFromStore(now: Date())
        // Also picks up tasks imported, deleted or enabled elsewhere.
        refreshEventMonitorsNow()
    }

    static func nextFullMinute(after date: Date, calendar: Calendar = .current) -> Date {
        let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        return minuteStart.addingTimeInterval(60)
    }

    func evaluateScheduleFromStore(now: Date = Date(), ignoringPause: Bool = false) {
        guard ignoringPause || !isSchedulerPaused else {
            return
        }

        guard let modelContext else {
            lastRuntimeMessage = L("Scheduler storage is not available.")
            return
        }

        evaluateSchedule(jobs: fetchJobs(modelContext), modelContext: modelContext, now: now)
    }

    /// Runs every job whose `nextRunAt` has passed. A time that passed long ago (Mac asleep,
    /// Cron not running) runs once or is skipped, depending on the job's missed-run policy.
    func evaluateSchedule(jobs: [ScheduledJob], modelContext: ModelContext, now: Date = Date()) {
        guard !isSchedulerPaused else {
            return
        }

        var changed = false

        for job in jobs {
            guard let due = job.nextRunAt else {
                job.nextRunAt = job.nextRunDate(after: now)
                changed = changed || job.nextRunAt != nil
                continue
            }

            guard due <= now else {
                continue
            }

            let isLate = now.timeIntervalSince(due) > Self.missedRunThreshold
            job.nextRunAt = job.nextRunDate(after: now)
            changed = true

            if isLate, job.missedRunPolicy == .skip {
                continue
            }

            run(job, modelContext: modelContext, reason: L("Schedule"), requiresEnabledTask: true)
        }

        if changed {
            save(modelContext)
        }
    }

    func triggerFromStore(_ event: EventKind, chain: Set<UUID> = []) {
        triggerFromStore(EventOccurrence(kind: event), chain: chain)
    }

    /// Returns the IDs of the jobs that started.
    @discardableResult
    func triggerFromStore(_ occurrence: EventOccurrence, chain: Set<UUID> = []) -> [UUID] {
        guard !isSchedulerPaused else {
            return []
        }

        guard let modelContext else {
            lastRuntimeMessage = L("Scheduler storage is not available.")
            return []
        }

        return trigger(occurrence, jobs: fetchJobs(modelContext), modelContext: modelContext, chain: chain)
    }

    func triggerLaunchOnceFromStore() {
        guard !isSchedulerPaused else {
            return
        }

        guard let modelContext else {
            lastRuntimeMessage = L("Scheduler storage is not available.")
            return
        }

        triggerLaunchOnce(jobs: fetchJobs(modelContext), modelContext: modelContext)
    }

    func triggerLaunchOnce(jobs: [ScheduledJob], modelContext: ModelContext) {
        guard !didTriggerLaunch else {
            return
        }

        didTriggerLaunch = true
        trigger(.appLaunch, jobs: jobs, modelContext: modelContext)
    }

    /// Starts every job listening for `event`, except jobs already in `chain`.
    /// `chain` holds the jobs whose completion led to this event, so tasks reacting to each other
    /// ("when another task stops") cannot ping-pong forever.
    func trigger(_ event: EventKind, jobs: [ScheduledJob], modelContext: ModelContext, chain: Set<UUID> = []) {
        trigger(EventOccurrence(kind: event), jobs: jobs, modelContext: modelContext, chain: chain)
    }

    /// Returns the IDs of the jobs that started.
    @discardableResult
    func trigger(_ occurrence: EventOccurrence, jobs: [ScheduledJob], modelContext: ModelContext, chain: Set<UUID> = []) -> [UUID] {
        guard !isSchedulerPaused else {
            return []
        }

        let now = Date()
        var started: [UUID] = []

        for job in jobs where !chain.contains(job.id) && job.canRun(at: now) {
            guard let matched = job.trigger(matching: occurrence), !isCoolingDown(job, now: now) else {
                continue
            }

            if matched.waitUntilStable, case .file(let path, let change) = occurrence.detail, change != .removed {
                deliverWhenSettled(occurrence, path: path, jobID: job.id, chain: chain)
                continue
            }

            if deliver(occurrence, to: job, modelContext: modelContext, chain: chain) {
                started.append(job.id)
            }
        }

        return started
    }

    /// "Not more often than every X minutes" for runs started by events.
    private func isCoolingDown(_ job: ScheduledJob, now: Date) -> Bool {
        guard job.eventCooldownMinutes > 0, let lastEventRunAt = job.lastEventRunAt else {
            return false
        }

        return now.timeIntervalSince(lastEventRunAt) < TimeInterval(job.eventCooldownMinutes * 60)
    }

    /// Starts the job for the event. A file event for a running job waits in the job's queue
    /// instead of being dropped (unless the job limits how often events may start it).
    @discardableResult
    private func deliver(_ occurrence: EventOccurrence, to job: ScheduledJob, modelContext: ModelContext, chain: Set<UUID>) -> Bool {
        if occurrence.kind == .folder, runningJobIDs.contains(job.id), job.eventCooldownMinutes == 0 {
            enqueue(occurrence, chain: chain, for: job, modelContext: modelContext)
            return false
        }

        guard run(job, modelContext: modelContext, reason: occurrence.reason, requiresEnabledTask: true, event: occurrence, chain: chain) else {
            return false
        }

        job.lastEventRunAt = Date()
        return true
    }

    private func deliverWhenSettled(_ occurrence: EventOccurrence, path: String, jobID: UUID, chain: Set<UUID>) {
        let key = "\(jobID.uuidString)|\(path)"

        // Further events for the same file while it is still being written are covered by this wait.
        guard filesWaitingToSettle.insert(key).inserted else {
            return
        }

        Task { @MainActor [weak self] in
            let settled = await FileStability.waitUntilStable(path)

            guard let self else {
                return
            }

            self.filesWaitingToSettle.remove(key)

            guard settled, !self.isSchedulerPaused, let modelContext = self.modelContext,
                  let job = self.fetchJobs(modelContext).first(where: { $0.id == jobID }),
                  job.canRun(at: Date()), job.trigger(matching: occurrence) != nil, !self.isCoolingDown(job, now: Date()) else {
                return
            }

            self.deliver(occurrence, to: job, modelContext: modelContext, chain: chain)
        }
    }

    private func enqueue(_ occurrence: EventOccurrence, chain: Set<UUID>, for job: ScheduledJob, modelContext: ModelContext) {
        var queue = folderEventQueues[job.id, default: []]

        guard queue.count < Self.folderEventQueueLimit else {
            // One history entry per full queue, not one per skipped file.
            if reportedFullQueues.insert(job.id).inserted {
                let now = Date()
                let message = L("Too many files are waiting. Further file events are skipped until the waiting files are processed.")
                let step = StepRunResult(title: L("Folder events"), outcome: .failed, startedAt: now, exitCode: 1, output: message)
                recordHistory(
                    TaskExecutionResult(startedAt: now, finishedAt: now, exitCode: 1, output: message, steps: [step]),
                    reason: occurrence.reason,
                    job: job,
                    modelContext: modelContext
                )
                save(modelContext)
            }
            return
        }

        queue.append((occurrence, chain))
        folderEventQueues[job.id] = queue
    }

    private func runNextQueuedEvent(jobID: UUID) {
        guard var queue = folderEventQueues[jobID], !queue.isEmpty else {
            folderEventQueues[jobID] = nil
            reportedFullQueues.remove(jobID)
            return
        }

        let next = queue.removeFirst()
        folderEventQueues[jobID] = queue.isEmpty ? nil : queue

        if queue.isEmpty {
            reportedFullQueues.remove(jobID)
        }

        guard let modelContext, !isSchedulerPaused, let job = fetchJobs(modelContext).first(where: { $0.id == jobID }),
              run(job, modelContext: modelContext, reason: next.occurrence.reason, requiresEnabledTask: true, event: next.occurrence, chain: next.chain) else {
            // The task was deleted, disabled or cannot run: the waiting files are dropped.
            folderEventQueues[jobID] = nil
            reportedFullQueues.remove(jobID)
            return
        }

        job.lastEventRunAt = Date()
    }

    func runNow(_ job: ScheduledJob, modelContext: ModelContext) {
        run(job, modelContext: modelContext, reason: L("Manual run"), requiresEnabledTask: false)
    }

    func stop(_ job: ScheduledJob) {
        stop(jobID: job.id)
    }

    func stop(jobID: UUID) {
        runningTasks[jobID]?.cancel()
    }

    func stopAll() {
        for task in runningTasks.values {
            task.cancel()
        }
    }

    /// Runs all jobs whose next scheduled time has already passed, without waiting for the next check.
    func runDueTasksNow() {
        evaluateScheduleFromStore(ignoringPause: true)
    }

    /// Recomputes the next run of a job after its schedule or settings changed.
    func rescheduleIfNeeded(_ job: ScheduledJob) {
        job.nextRunAt = job.nextRunDate(after: Date())
        refreshEventMonitors()
    }

    // MARK: Links, Shortcuts, menu bar

    enum URLRunResult: Equatable {
        case started(String)
        case rejected(String)
    }

    /// Starts the task named in a `webapps-cron://` link. Like an event: only enabled tasks that
    /// allow links, and not while the scheduler is paused.
    @discardableResult
    func handleURL(_ url: URL) -> URLRunResult {
        guard let modelContext else {
            return .rejected(L("Scheduler storage is not available."))
        }

        let result = handleURL(url, jobs: fetchJobs(modelContext), modelContext: modelContext)

        switch result {
        case .started(let name):
            lastRuntimeMessage = "\(L("Started by a link")): \(name)"
        case .rejected(let reason):
            lastRuntimeMessage = "\(L("Link rejected")): \(reason)"
        }

        return result
    }

    func handleURL(_ url: URL, jobs: [ScheduledJob], modelContext: ModelContext) -> URLRunResult {
        let reference: URLCommand.TaskReference

        switch URLCommand.parse(url) {
        case .success(.run(let value)):
            reference = value
        case .failure(.unknownCommand(let command)):
            return .rejected("\(L("Unknown command")): \(command)")
        case .failure(.missingTask):
            return .rejected(L("The link names no task."))
        case .failure(.wrongScheme):
            return .rejected(L("Not a Cron link."))
        }

        let matches: [ScheduledJob]

        switch reference {
        case .id(let id):
            matches = jobs.filter { $0.id == id }
        case .name(let name):
            matches = jobs.filter { $0.name.trimmed.caseInsensitiveCompare(name) == .orderedSame }
        }

        guard let job = matches.first else {
            return .rejected(L("Task not found."))
        }

        guard matches.count == 1 else {
            return .rejected(L("Several tasks have this name."))
        }

        guard job.allowsURLTrigger else {
            return .rejected("\(L("The task does not accept links")): \(job.name)")
        }

        guard !isSchedulerPaused else {
            return .rejected(L("Scheduler paused"))
        }

        guard run(job, modelContext: modelContext, reason: L("Link"), requiresEnabledTask: true) else {
            return .rejected("\(L("The task cannot run now")): \(job.name)")
        }

        return .started(job.name)
    }

    /// All tasks, for the menu bar and Shortcuts.
    func allJobs() -> [ScheduledJob] {
        modelContext.map(fetchJobs) ?? []
    }

    func job(withID id: UUID) -> ScheduledJob? {
        allJobs().first { $0.id == id }
    }

    /// Starts the task like "Run now" and waits until it finishes (Shortcuts). Returns `nil` when
    /// the task did not start (already running, no runnable actions).
    func runAndWait(_ job: ScheduledJob, reason: String) async -> (outcome: RunOutcome, output: String)? {
        guard let modelContext, run(job, modelContext: modelContext, reason: reason, requiresEnabledTask: false),
              let task = runningTasks[job.id] else {
            return nil
        }

        await task.value

        let lastRun = job.isDeleted ? nil : job.runs.max { $0.startedAt < $1.startedAt }
        let output = lastRun.map { $0.steps.map(\.output).joined(separator: "\n\n") } ?? job.lastOutput
        return (lastRun?.outcome ?? (job.lastExitCode == 0 ? .succeeded : .failed), output)
    }

    func setEnabled(_ isEnabled: Bool, for job: ScheduledJob) {
        job.isEnabled = isEnabled
        job.updatedAt = Date()
        rescheduleIfNeeded(job)

        if let modelContext {
            save(modelContext)
        }
    }

    /// Opens the task's history in the main window, at `runID` if given.
    func showHistory(jobID: UUID, runID: UUID?) {
        navigationRequest = NavigationRequest(jobID: jobID, runID: runID)
    }

    func requestMainWindow() {
        mainWindowRequest = UUID()
    }

    /// "Last error" in the menu bar: opens that run and clears the error mark.
    func showLastFailure() {
        guard let lastFailure else {
            return
        }

        self.lastFailure = nil
        showHistory(jobID: lastFailure.jobID, runID: lastFailure.runID)
    }

    /// "Run again" in a notification.
    func runAgain(jobID: UUID) {
        guard let modelContext, let job = job(withID: jobID) else {
            return
        }

        runNow(job, modelContext: modelContext)
    }

    /// SF Symbol of the menu bar icon: paused, running, last run failed, idle.
    var menuBarSymbol: String {
        if isSchedulerPaused {
            return "pause.circle.fill"
        }

        if !runningJobIDs.isEmpty {
            return "play.circle.fill"
        }

        return lastFailure == nil ? "calendar.badge.clock" : "exclamationmark.triangle.fill"
    }

    private func updateLastFailure(jobID: UUID, jobName: String, runID: UUID, outcome: RunOutcome) {
        switch outcome {
        case .failed, .timedOut:
            lastFailure = FailureRecord(jobID: jobID, jobName: jobName, runID: runID)
        case .succeeded, .conditionNotMet:
            if lastFailure?.jobID == jobID {
                lastFailure = nil
            }
        case .cancelled:
            break
        }
    }

    // MARK: Event monitors

    /// Updates watched folders and idle polling after task events or settings changed. Waits a
    /// moment, so typing a folder path does not watch every intermediate folder.
    func refreshEventMonitors() {
        monitorRefreshTask?.cancel()
        monitorRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard !Task.isCancelled else {
                return
            }

            self?.refreshEventMonitorsNow()
        }
    }

    private func refreshEventMonitorsNow() {
        guard let eventMonitors, let modelContext else {
            return
        }

        let triggers = fetchJobs(modelContext).filter(\.isEnabled).flatMap(\.eventTriggers)
        let folderRoots = Set(triggers.filter { $0.kind == .folder }.map { FolderPath.normalized($0.folderPath) }.filter { !$0.isEmpty })
        eventMonitors.update(folderRoots: folderRoots, watchesIdle: triggers.contains { $0.kind == .idle })
    }

    private func startEventMonitors() {
        guard eventMonitors == nil else {
            return
        }

        let monitors = EventMonitors { [weak self] occurrence in
            self?.triggerFromStore(occurrence)
        } onWillSleep: { [weak self] allowSleep in
            guard let self else {
                allowSleep()
                return
            }

            self.prepareForSleep(allowSleep)
        }
        monitors.start()
        eventMonitors = monitors
        refreshEventMonitorsNow()
    }

    /// Starts the "before sleep" tasks and lets the Mac sleep when they finish, at the latest after
    /// `beforeSleepTimeLimit`. Sleep cannot be prevented.
    private func prepareForSleep(_ allowSleep: @escaping @MainActor () -> Void) {
        let started = Set(triggerFromStore(EventOccurrence(kind: .beforeSleep)))

        guard !started.isEmpty else {
            allowSleep()
            return
        }

        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.beforeSleepTimeLimit)

            while let self, Date() < deadline, !self.runningJobIDs.isDisjoint(with: started) {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            allowSleep()
        }
    }

    private var modelContext: ModelContext? {
        modelContainer?.mainContext
    }

    private func fetchJobs(_ modelContext: ModelContext) -> [ScheduledJob] {
        let descriptor = FetchDescriptor<ScheduledJob>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            lastRuntimeMessage = "\(L("Load failed")): \(error.localizedDescription)"
            return []
        }
    }

    private func installObservers() {
        guard workspaceObservers.isEmpty && applicationObservers.isEmpty else {
            return
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, EventKind)] = [
            (NSWorkspace.didWakeNotification, .systemWake),
            (NSWorkspace.screensDidWakeNotification, .screenWake),
            (NSWorkspace.screensDidSleepNotification, .screenSleep),
            (NSWorkspace.didMountNotification, .volumeMounted),
            (NSWorkspace.didUnmountNotification, .volumeUnmounted)
        ]

        for (name, event) in workspaceEvents {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.triggerFromStore(event)
                }
            })
        }

        for (name, launched) in [(NSWorkspace.didLaunchApplicationNotification, true), (NSWorkspace.didTerminateApplicationNotification, false)] {
            workspaceObservers.append(workspaceCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                let detail = EventOccurrence.Detail.application(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "", launched: launched)

                Task { @MainActor [weak self] in
                    self?.triggerFromStore(EventOccurrence(kind: .application, detail: detail))
                }
            })
        }

        // Catch up right after waking: missed times run once or are skipped (missed-run policy).
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateScheduleFromStore()
            }
        })

        applicationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.screenParametersDidChange()
            }
        })

        // Clock or time zone changes shift every computed time; start over from now.
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            applicationObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recomputeAllNextRuns()
                }
            })
        }
    }

    private func recomputeAllNextRuns() {
        guard let modelContext else {
            return
        }

        let now = Date()
        for job in fetchJobs(modelContext) {
            job.nextRunAt = job.nextRunDate(after: now)
        }
        save(modelContext)
    }

    private func screenParametersDidChange() {
        let previous = screenSnapshot
        let current = ScreenSnapshot.current()
        screenSnapshot = current

        if current.count > previous.count {
            triggerFromStore(.screenConnected)
        } else if current.count < previous.count {
            triggerFromStore(.screenDisconnected)
        } else if current.frames != previous.frames {
            triggerFromStore(.screenResolutionChanged)
        }
    }

    /// Starts the job's workflow. Returns false if the job did not start.
    @discardableResult
    private func run(
        _ job: ScheduledJob,
        modelContext: ModelContext,
        reason: String,
        requiresEnabledTask: Bool,
        event: EventOccurrence? = nil,
        chain: Set<UUID> = []
    ) -> Bool {
        guard !runningJobIDs.contains(job.id) else {
            return false
        }

        if requiresEnabledTask, !job.canRun(at: Date()) {
            return false
        }

        if let loadError = job.workflowLoadError {
            recordFailureWithoutRun(job, reason: reason, output: "\(L("Workflow data could not be read."))\n\(loadError)", modelContext: modelContext)
            return false
        }

        let steps = job.workflowSteps

        guard steps.contains(where: { $0.isEnabled && $0.isConfigured }) else {
            recordFailureWithoutRun(job, reason: reason, output: L("No enabled and configured workflow actions."), modelContext: modelContext)
            return false
        }

        let jobID = job.id
        let jobName = job.name
        let chain = chain.union([jobID])
        let context = WorkflowContext(jobName: jobName, event: event) { [weak self] actionType, names in
            self?.handleTaskAction(actionType, names: names, from: jobID, chain: chain)
                ?? TaskExecutionResult(startedAt: Date(), finishedAt: Date(), exitCode: 1, output: "Scheduler is not available.")
        }

        runningJobIDs.insert(jobID)
        if job.preventsSleep {
            sleepPreventingJobIDs.insert(jobID)
        }
        updateActivity()
        job.status = .running
        job.lastRunReason = reason
        job.updatedAt = Date()
        lastRuntimeMessage = "\(L("Running")) \(job.name)"
        save(modelContext)

        trigger(EventOccurrence(kind: .otherTaskStarted, detail: .task(name: jobName, outcome: nil)), jobs: fetchJobs(modelContext), modelContext: modelContext, chain: chain)

        runningTasks[jobID] = Task {
            let result = await TaskActionExecutor.runWorkflow(steps, context: context)

            runningJobIDs.remove(jobID)
            sleepPreventingJobIDs.remove(jobID)
            runningTasks[jobID] = nil
            updateActivity()

            // The task may have been deleted while it was running.
            guard !job.isDeleted, job.modelContext != nil else {
                folderEventQueues[jobID] = nil
                return
            }

            job.recordExecution(result, reason: reason)
            let runID = recordHistory(result, reason: reason, job: job, modelContext: modelContext)
            updateLastFailure(jobID: jobID, jobName: jobName, runID: runID, outcome: RunOutcome(workflowResult: result))
            notifyIfNeeded(job: job, result: result, runID: runID)

            let reachedMaximum = job.hasReachedMaximumExecutions
            let shouldDelete = reachedMaximum && job.maximumExecutionsBehavior == .deleteTask

            if reachedMaximum && job.maximumExecutionsBehavior == .disableTask {
                job.isEnabled = false
                job.nextRunAt = nil
            }

            lastRuntimeMessage = "\(job.name): \(job.status.title)"

            if shouldDelete {
                modelContext.delete(job)
            }

            save(modelContext)

            let outcome = RunOutcome(workflowResult: result)

            if result.wasCancelled {
                triggerFromStore(EventOccurrence(kind: .otherTaskCancelled, detail: .task(name: jobName, outcome: outcome)), chain: chain)
            }

            triggerFromStore(EventOccurrence(kind: .otherTaskFinished, detail: .task(name: jobName, outcome: outcome)), chain: chain)

            if shouldDelete {
                folderEventQueues[jobID] = nil
            } else {
                runNextQueuedEvent(jobID: jobID)
            }
        }

        return true
    }

    // MARK: Run history

    @discardableResult
    private func recordHistory(_ result: TaskExecutionResult, reason: String, job: ScheduledJob, modelContext: ModelContext) -> UUID {
        let run = TaskRun(
            startedAt: result.startedAt,
            finishedAt: result.finishedAt,
            reason: reason,
            outcome: RunOutcome(workflowResult: result),
            exitCode: Int(result.exitCode),
            steps: RunHistory.cappedSteps(result.steps)
        )
        modelContext.insert(run)
        run.job = job
        pruneHistory(of: job, modelContext: modelContext)
        return run.id
    }

    /// Deletes runs older than the retention period and beyond the per-task limit (Settings).
    func pruneHistory(of job: ScheduledJob, modelContext: ModelContext, now: Date = Date()) {
        let expired = RunHistory.runsToPrune(
            job.runs,
            startedAt: \.startedAt,
            now: now,
            retentionDays: RunHistory.retentionDays(in: defaults),
            maxRuns: RunHistory.maxRunsPerTask(in: defaults)
        )

        for run in expired {
            modelContext.delete(run)
        }
    }

    private func pruneAllHistory() {
        guard let modelContext else {
            return
        }

        for job in fetchJobs(modelContext) {
            pruneHistory(of: job, modelContext: modelContext)
        }
        save(modelContext)
    }

    private func recordFailureWithoutRun(_ job: ScheduledJob, reason: String, output: String, modelContext: ModelContext) {
        job.status = .failed
        job.lastRunReason = reason
        job.lastOutput = output
        job.lastExitCode = 1
        job.updatedAt = Date()
        let result = TaskExecutionResult(
            startedAt: job.updatedAt,
            finishedAt: job.updatedAt,
            exitCode: 1,
            output: output
        )
        lastFailure = FailureRecord(jobID: job.id, jobName: job.name, runID: nil)
        notifyIfNeeded(job: job, result: result, runID: nil)
        save(modelContext)
    }

    /// Task-management workflow actions (enable/disable/delete/execute/stop tasks, scheduler control).
    private func handleTaskAction(_ actionType: TaskActionType, names: [String], from sourceJobID: UUID, chain: Set<UUID>) -> TaskExecutionResult {
        let startedAt = Date()

        func result(_ exitCode: Int32, _ output: String) -> TaskExecutionResult {
            TaskExecutionResult(startedAt: startedAt, finishedAt: Date(), exitCode: exitCode, output: output)
        }

        guard let modelContext else {
            return result(1, "Scheduler storage is not available.")
        }

        switch actionType {
        case .pauseScheduler:
            isSchedulerPaused = true
            return result(0, "Task scheduler paused.")
        case .resumeScheduler:
            isSchedulerPaused = false
            return result(0, "Task scheduler resumed.")
        case .checkTasksRunning:
            let others = runningJobIDs.subtracting([sourceJobID])
            let jobs = fetchJobs(modelContext)

            if names.isEmpty {
                return others.isEmpty ? result(1, "No other tasks are running.") : result(0, "Running tasks: \(others.count)")
            }

            let running = jobs.filter { job in others.contains(job.id) && names.contains { $0.caseInsensitiveCompare(job.name) == .orderedSame } }
            return running.isEmpty ? result(1, "Tasks are not running: \(names.joined(separator: ", "))") : result(0, "Running: \(running.map(\.name).joined(separator: ", "))")
        default:
            break
        }

        let jobs = fetchJobs(modelContext)
        let targets = jobs.filter { job in
            names.contains { $0.caseInsensitiveCompare(job.name) == .orderedSame }
        }
        let missing = names.filter { name in !targets.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

        guard !targets.isEmpty else {
            return result(1, "Tasks not found: \(names.joined(separator: ", "))")
        }

        var lines: [String] = []

        for job in targets {
            switch actionType {
            case .enableTasks:
                job.isEnabled = true
                job.updatedAt = Date()
                job.nextRunAt = job.nextRunDate(after: Date())
                lines.append("Enabled: \(job.name)")
            case .disableTasks:
                job.isEnabled = false
                job.updatedAt = Date()
                job.nextRunAt = nil
                lines.append("Disabled: \(job.name)")
            case .deleteTasks:
                guard job.id != sourceJobID else {
                    lines.append("Skipped (current task): \(job.name)")
                    continue
                }

                stop(jobID: job.id)
                lines.append("Deleted: \(job.name)")
                modelContext.delete(job)
            case .stopTasks:
                guard job.id != sourceJobID else {
                    lines.append("Skipped (current task): \(job.name)")
                    continue
                }

                if runningJobIDs.contains(job.id) {
                    stop(jobID: job.id)
                    lines.append("Stopped: \(job.name)")
                } else {
                    lines.append("Not running: \(job.name)")
                }
            case .executeTasks:
                guard !chain.contains(job.id) else {
                    lines.append("Skipped (already in this chain): \(job.name)")
                    continue
                }

                guard job.triggers(.triggeredByTask) else {
                    lines.append("Skipped (event \"When another task triggers this task\" is off): \(job.name)")
                    continue
                }

                let started = run(job, modelContext: modelContext, reason: EventKind.triggeredByTask.reason, requiresEnabledTask: true, chain: chain)
                lines.append(started ? "Started: \(job.name)" : "Not started (disabled, running or outside its validity period): \(job.name)")
            default:
                break
            }
        }

        if !missing.isEmpty {
            lines.append("Not found: \(missing.joined(separator: ", "))")
        }

        save(modelContext)
        return result(missing.isEmpty ? 0 : 1, lines.joined(separator: "\n"))
    }

    /// Keeps App Nap from throttling the app while workflows run; jobs with "prevent sleep"
    /// also keep the Mac awake until they finish.
    private func updateActivity() {
        let wantsActivity = !runningJobIDs.isEmpty
        let wantsNoSleep = !sleepPreventingJobIDs.isEmpty

        if let activityToken, !wantsActivity || wantsNoSleep != activityPreventsSleep {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }

        if wantsActivity, activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: wantsNoSleep ? [.userInitiated, .idleSystemSleepDisabled] : .userInitiatedAllowingIdleSystemSleep,
                reason: "Running Cron tasks"
            )
            activityPreventsSleep = wantsNoSleep
        }
    }

    private func notifyIfNeeded(job: ScheduledJob, result: TaskExecutionResult, runID: UUID?) {
        switch job.notificationMode {
        case .never:
            return
        case .errorsOnly where result.exitCode == 0:
            return
        default:
            break
        }

        let title = result.stoppedByCondition ? L("Condition not met") : (result.exitCode == 0 ? L("Task succeeded") : L("Task failed"))
        let body = result.exitCode == 0
            ? "\(job.name)\n\(L("Exit code")): \(result.exitCode)"
            : "\(job.name)\n\(L("Exit code")): \(result.exitCode)\n\(Self.notificationOutput(result.output))"

        let failed = result.exitCode != 0
        var userInfo = [TaskCompletionNotifier.jobIDKey: job.id.uuidString]
        userInfo[TaskCompletionNotifier.runIDKey] = runID?.uuidString

        Task {
            await TaskCompletionNotifier.show(
                title: title,
                body: body,
                category: failed ? TaskCompletionNotifier.failureCategory : TaskCompletionNotifier.resultCategory,
                userInfo: userInfo
            )
        }
    }

    private static func notificationOutput(_ output: String) -> String {
        let trimmed = output.trimmed

        guard !trimmed.isEmpty else {
            return L("No output.")
        }

        if trimmed.count <= 240 {
            return trimmed
        }

        return "\(trimmed.prefix(240))..."
    }

    private func save(_ modelContext: ModelContext) {
        do {
            try modelContext.save()
        } catch {
            lastRuntimeMessage = "\(L("Save failed")): \(error.localizedDescription)"
        }
    }
}

private struct ScreenSnapshot {
    var count: Int
    var frames: [CGRect]

    static func current() -> ScreenSnapshot {
        let frames = NSScreen.screens.map(\.frame)
        return ScreenSnapshot(count: frames.count, frames: frames)
    }
}

enum TaskCompletionNotifier {
    /// Notification with "Show result"; the failure category adds "Run again".
    static let resultCategory = "cron.task-result"
    static let failureCategory = "cron.task-failure"
    nonisolated static let showResultAction = "cron.show-result"
    nonisolated static let runAgainAction = "cron.run-again"
    nonisolated static let jobIDKey = "jobID"
    nonisolated static let runIDKey = "runID"

    /// Registered at launch, before any notification can be answered.
    static func registerCategories() {
        let showResult = UNNotificationAction(identifier: showResultAction, title: L("Show result"), options: [.foreground])
        let runAgain = UNNotificationAction(identifier: runAgainAction, title: L("Run again"), options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: resultCategory, actions: [showResult], intentIdentifiers: []),
            UNNotificationCategory(identifier: failureCategory, actions: [showResult, runAgain], intentIdentifiers: [])
        ])
    }

    static func show(title: String, body: String, category: String? = nil, userInfo: [String: String] = [:]) async {
        let center = UNUserNotificationCenter.current()

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])

            guard granted else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.userInfo = userInfo

            if let category {
                content.categoryIdentifier = category
            }

            let request = UNNotificationRequest(
                identifier: "cron.task-completion.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            try await center.add(request)
        } catch {
            NSLog("Cron: could not show task completion notification: \(error.localizedDescription)")
        }
    }
}

struct FailureRecord: Equatable {
    var jobID: UUID
    var jobName: String
    /// `nil` when the task could not start at all (no history entry).
    var runID: UUID?
}

struct NavigationRequest: Equatable {
    /// Distinguishes repeated requests for the same run.
    var id = UUID()
    var jobID: UUID
    var runID: UUID?
}
