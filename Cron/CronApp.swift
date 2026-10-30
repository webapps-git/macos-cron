import Foundation
import AppIntents
import AppKit
import Combine
import SwiftUI
import SwiftData
import UserNotifications

@main
struct CronApp: App {
    @NSApplicationDelegateAdaptor(CronApplicationDelegate.self) private var appDelegate

    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppSettingsKeys.languageIdentifier) private var languageIdentifier = AppLanguageOption.automaticIdentifier
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    @StateObject private var runtime: TaskRuntime

    private let sharedModelContainer: ModelContainer

    init() {
        // Unit tests run inside this app (test host): keep the user's tasks and scheduler out of it.
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let (modelContainer, storeRecoveryNotice) = isRunningTests ? (ModelContainerFactory.makeInMemory(), nil) : ModelContainerFactory.make()
        let taskRuntime = TaskRuntime(modelContainer: modelContainer, storeRecoveryNotice: storeRecoveryNotice)

        sharedModelContainer = modelContainer
        _runtime = StateObject(wrappedValue: taskRuntime)
        CronServices.runtime = taskRuntime
        // Shortcuts actions reach the runtime through @Dependency (CronIntents.swift).
        AppDependencyManager.shared.add(dependency: taskRuntime)

        if !isRunningTests {
            Task { @MainActor in
                taskRuntime.startBackgroundScheduling()
            }
        }
    }

    var body: some Scene {
        Window("Cron", id: CronWindowID.main) {
            ContentView()
                .id(languageIdentifier)
                .environmentObject(runtime)
                .environment(\.locale, appLocale)
                .preferredColorScheme(resolvedColorScheme)
                .background(
                    WindowChromeController(
                        autosaveName: "CronMainWindow",
                        appearanceModeRawValue: appearanceModeRawValue,
                        systemColorScheme: systemAppearance.colorScheme
                    )
                )
                .onAppear(perform: applyApplicationChrome)
                .onChange(of: appearanceModeRawValue) { _, _ in
                    applyApplicationChrome()
                }
                .onChange(of: systemAppearance.colorScheme) { _, _ in
                    applyApplicationChrome()
                }
        }
        .defaultSize(width: 1_440, height: 860)
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
        .modelContainer(sharedModelContainer)
        .commands {
            // Cron menu: About, Settings… (from the Settings scene), Quit.
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            // There is no help book.
            CommandGroup(replacing: .help) {}
        }

        Window(L("About Cron"), id: CronWindowID.about) {
            AboutView()
                .id(languageIdentifier)
                .environment(\.locale, appLocale)
                .preferredColorScheme(resolvedColorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            CronMenuBarView(runtime: runtime)
                .id(languageIdentifier)
                .environment(\.locale, appLocale)
                .modelContainer(sharedModelContainer)
        } label: {
            CronMenuBarLabel(runtime: runtime)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            AppSettingsView()
                .id(languageIdentifier)
                .environment(\.locale, appLocale)
                .preferredColorScheme(resolvedColorScheme)
                .background(
                    WindowChromeController(
                        autosaveName: "CronSettingsWindow",
                        appearanceModeRawValue: appearanceModeRawValue,
                        systemColorScheme: systemAppearance.colorScheme
                    )
                )
                .onAppear(perform: applyApplicationChrome)
                .onChange(of: appearanceModeRawValue) { _, _ in
                    applyApplicationChrome()
                }
                .onChange(of: systemAppearance.colorScheme) { _, _ in
                    applyApplicationChrome()
                }
        }
        .windowResizability(.contentMinSize)
    }

    private var appearanceMode: AppAppearanceMode {
        AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
    }

    private var resolvedColorScheme: ColorScheme {
        AppAppearanceResolver.colorScheme(for: appearanceMode, systemColorScheme: systemAppearance.colorScheme)
    }

    private var appLocale: Locale {
        let validatedIdentifier = AppLanguageOption.validatedIdentifier(languageIdentifier)
        return Locale(identifier: AppLanguageOption.localeIdentifier(for: validatedIdentifier))
    }

    private func applyApplicationChrome() {
        applyAppearance()
        ApplicationIconLoader.apply()
    }

    private func applyAppearance() {
        let appearance = AppAppearanceResolver.nsAppearance(
            for: appearanceMode,
            systemColorScheme: systemAppearance.colorScheme
        )

        NSApp.appearance = appearance

        for window in NSApp.windows {
            window.appearance = appearance
            window.contentView?.appearance = appearance
            window.invalidateShadow()
            window.contentView?.needsDisplay = true
        }
    }
}

private enum CronWindowID {
    static let main = "main-window"
    static let about = "about-window"
}

/// Switches between a menu bar–only app and a regular one. macOS shows the app's menu (Cron, Edit,
/// Window) only for regular apps, and the switch has to happen before a window is shown.
@MainActor
enum AppPresence {
    /// Call before opening a window (main window, Settings, About).
    static func showWindows() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        NSApp.activate(ignoringOtherApps: true)
        // The menu bar is updated once the policy change is processed; activate again afterwards.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Back to the menu bar only when no Cron window is left (`closing` is about to close).
    static func update(closing: NSWindow? = nil) {
        let hasAppWindow = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }

        if hasAppWindow {
            if NSApp.activationPolicy() != .regular {
                showWindows()
            }
        } else if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// "About Cron" in the Cron menu.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("About Cron")) {
            AppPresence.showWindows()
            openWindow(id: CronWindowID.about)
        }
    }
}

private struct AboutView: View {
    static let projectURL = URL(string: "https://github.com/webapps-git/macos-cron")!
    static let licenseURL = URL(string: "https://github.com/webapps-git/macos-cron/blob/main/LICENSE")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)

            Text("Cron")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 10)

            Text("\(L("Version")) \(version)")
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            Text(L("Task scheduler for the macOS menu bar."))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Divider()
                .padding(.vertical, 18)

            Text(copyright)
            Text(L("MIT License"))
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            HStack(spacing: 12) {
                Button(L("Project page")) {
                    NSWorkspace.shared.open(Self.projectURL)
                }

                Button(L("License")) {
                    NSWorkspace.shared.open(Self.licenseURL)
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 380)
    }
}

/// The runtime for code outside SwiftUI views (application delegate, notification answers).
@MainActor
enum CronServices {
    static weak var runtime: TaskRuntime?
}

private final class CronApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apple: the notification delegate must be set before the app finishes launching, or
        // answers to notifications can be lost.
        UNUserNotificationCenter.current().delegate = self
        TaskCompletionNotifier.registerCategories()
        registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Registered again: SwiftUI installs its own handler during launch.
        registerURLHandler()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowsChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowsChanged(_:)), name: NSWindow.willCloseNotification, object: nil)
    }

    /// Opening Cron again (Finder, Spotlight, Dock) while it runs shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            CronServices.runtime?.requestMainWindow()
        }

        return true
    }

    // MARK: Menu bar of the app

    /// macOS shows the app's menu (Cron, Edit, Window) only for regular apps. While the main window
    /// or Settings is open Cron is one (with a Dock icon); otherwise it lives only in the menu bar.
    @objc private func windowsChanged(_ notification: Notification) {
        let closing = notification.name == NSWindow.willCloseNotification ? notification.object as? NSWindow : nil
        AppPresence.update(closing: closing)
    }

    // MARK: Links

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else {
            return
        }

        CronServices.runtime?.handleURL(url)
    }

    // MARK: Notifications

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Also show notifications while a Cron window is in front.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let jobID = (userInfo[TaskCompletionNotifier.jobIDKey] as? String).flatMap(UUID.init(uuidString:))
        let runID = (userInfo[TaskCompletionNotifier.runIDKey] as? String).flatMap(UUID.init(uuidString:))

        guard let jobID else {
            return
        }

        await MainActor.run {
            switch action {
            case TaskCompletionNotifier.runAgainAction:
                CronServices.runtime?.runAgain(jobID: jobID)
            case TaskCompletionNotifier.showResultAction, UNNotificationDefaultActionIdentifier:
                CronServices.runtime?.showHistory(jobID: jobID, runID: runID)
            default:
                break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Status item icon. It is always on screen, so it also opens the main window when the runtime asks
/// for it (a notification's "Show result" has no SwiftUI view of its own).
private struct CronMenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var runtime: TaskRuntime

    var body: some View {
        Image(systemName: runtime.menuBarSymbol)
            .onChange(of: runtime.navigationRequest) { _, request in
                guard request != nil else {
                    return
                }

                AppPresence.showWindows()
                openWindow(id: CronWindowID.main)
            }
            .onChange(of: runtime.mainWindowRequest) { _, _ in
                AppPresence.showWindows()
                openWindow(id: CronWindowID.main)
            }
    }
}

private struct CronMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @ObservedObject var runtime: TaskRuntime

    var body: some View {
        Button(L("Show Cron window")) {
            AppPresence.showWindows()
            openWindow(id: CronWindowID.main)
        }

        RunTaskMenu(runtime: runtime)

        if let failure = runtime.lastFailure {
            Button("\(L("Last error")): \(failure.jobName)") {
                runtime.showLastFailure()
            }
        }

        Button(runtime.isSchedulerPaused ? L("Resume scheduler") : L("Pause scheduler")) {
            runtime.isSchedulerPaused.toggle()
        }

        Button(L("Run due tasks now")) {
            runtime.runDueTasksNow()
        }

        if !runtime.runningJobIDs.isEmpty {
            Button(L("Stop all running tasks")) {
                runtime.stopAll()
            }
        }

        Divider()

        Text(runtime.isSchedulerPaused ? L("Scheduler paused") : L("Running in background"))
        Text(runtime.lastRuntimeMessage)

        Divider()

        Button(L("Settings")) {
            AppPresence.showWindows()
            openSettings()
        }

        Button(L("About Cron")) {
            AppPresence.showWindows()
            openWindow(id: CronWindowID.about)
        }

        Divider()

        Button(L("Quit Cron")) {
            NSApp.terminate(nil)
        }
    }
}

private enum AppAppearanceResolver {
    static func colorScheme(for mode: AppAppearanceMode, systemColorScheme: ColorScheme) -> ColorScheme {
        switch mode {
        case .system:
            return systemColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func nsAppearance(for mode: AppAppearanceMode, systemColorScheme: ColorScheme) -> NSAppearance? {
        let colorScheme = colorScheme(for: mode, systemColorScheme: systemColorScheme)

        switch colorScheme {
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        @unknown default:
            return nil
        }
    }
}

@MainActor
private final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var colorScheme: ColorScheme

    // nonisolated(unsafe): set once in init on the main actor, read only in deinit.
    nonisolated(unsafe) private var notificationToken: NSObjectProtocol?

    init() {
        colorScheme = SystemAppearanceObserver.currentColorScheme()

        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.colorScheme = SystemAppearanceObserver.currentColorScheme()
            }
        }
    }

    deinit {
        if let notificationToken {
            DistributedNotificationCenter.default().removeObserver(notificationToken)
        }
    }

    nonisolated private static func currentColorScheme() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
}

private enum ApplicationIconLoader {
    static func apply() {
        guard let image = appIconImage() else {
            return
        }

        NSApp.applicationIconImage = image
    }

    private static func appIconImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = false
            return image
        }

        if let image = NSImage(named: "AppIcon") {
            image.isTemplate = false
            return image
        }

        return nil
    }
}

private struct WindowChromeController: NSViewRepresentable {
    var autosaveName: String?
    var appearanceModeRawValue: String
    var systemColorScheme: ColorScheme

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let autosaveName {
                nsView.window?.setFrameAutosaveName(NSWindow.FrameAutosaveName(autosaveName))
            }

            let mode = AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .system
            let appearance = AppAppearanceResolver.nsAppearance(for: mode, systemColorScheme: systemColorScheme)

            nsView.window?.appearance = appearance
            nsView.window?.contentView?.appearance = appearance
            nsView.window?.contentView?.needsDisplay = true
        }
    }
}

/// Version 1 of the stored schema (store file `Cron.store`). The earlier prototype store
/// `CronTasksWorkflow.store` is left untouched and no longer read.
/// When a model change needs more than a lightweight migration, add `CronSchemaV2` and a
/// migration stage to `CronMigrationPlan` instead of editing this one.
enum CronSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [ScheduledJob.self, TaskRun.self] }
}

enum CronMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CronSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

private enum ModelContainerFactory {
    /// Returns the container and, when the stored database could not be opened, a notice for the user.
    static func make() -> (ModelContainer, String?) {
        let schema = Schema(versionedSchema: CronSchemaV1.self)
        let storeURL = applicationSupportStoreURL()
        let modelConfiguration = ModelConfiguration("Cron", schema: schema, url: storeURL)

        do {
            return (try ModelContainer(for: schema, migrationPlan: CronMigrationPlan.self, configurations: [modelConfiguration]), nil)
        } catch {
            NSLog("Cron: persistent store failed to load, backing it up and recreating it. Error: \(error)")
            let backupNames = backupStoreFiles(at: storeURL)
            let notice = "\(L("The task database could not be opened. A backup was saved and an empty database was created.")) \(backupNames.joined(separator: ", "))"

            do {
                return (try ModelContainer(for: schema, migrationPlan: CronMigrationPlan.self, configurations: [modelConfiguration]), notice)
            } catch {
                NSLog("Cron: recreated persistent store failed to load, using in-memory store. Error: \(error)")

                do {
                    let memoryConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
                    return (try ModelContainer(for: schema, configurations: [memoryConfiguration]), notice)
                } catch {
                    preconditionFailure("Cron could not create any ModelContainer: \(error)")
                }
            }
        }
    }

    static func makeInMemory() -> ModelContainer {
        let schema = Schema(versionedSchema: CronSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            preconditionFailure("Cron could not create an in-memory ModelContainer: \(error)")
        }
    }

    private static func applicationSupportStoreURL() -> URL {
        let fileManager = FileManager.default
        let directory = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Cron", isDirectory: true)

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("Cron: could not create Application Support directory: \(error)")
        }

        return directory.appendingPathComponent("Cron.store")
    }

    /// Moves the store files aside and returns the backup file names.
    private static func backupStoreFiles(at storeURL: URL) -> [String] {
        let fileManager = FileManager.default
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var backupNames: [String] = []

        for url in storeSidecarURLs(for: storeURL) where fileManager.fileExists(atPath: url.path) {
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).backup-\(timestamp)")

            do {
                try fileManager.moveItem(at: url, to: backupURL)
                backupNames.append(backupURL.lastPathComponent)
            } catch {
                NSLog("Cron: could not back up store file \(url.path), removing it. Error: \(error)")
                try? fileManager.removeItem(at: url)
            }
        }

        return backupNames
    }

    private static func storeSidecarURLs(for storeURL: URL) -> [URL] {
        [
            storeURL,
            URL(fileURLWithPath: "\(storeURL.path)-shm"),
            URL(fileURLWithPath: "\(storeURL.path)-wal")
        ]
    }
}

/// "Run task" submenu, grouped like the task list.
private struct RunTaskMenu: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledJob.name) private var jobs: [ScheduledJob]
    @ObservedObject var runtime: TaskRuntime

    private var groups: [(name: String, jobs: [ScheduledJob])] {
        let grouped = Dictionary(grouping: jobs) { $0.groupName.trimmed }
        let names = grouped.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var result = names.map { (name: $0, jobs: grouped[$0] ?? []) }
        if let ungrouped = grouped[""], !ungrouped.isEmpty {
            result.append((name: "", jobs: ungrouped))
        }
        return result
    }

    var body: some View {
        Menu(L("Run task")) {
            if jobs.isEmpty {
                Text(L("No tasks"))
            }

            ForEach(groups, id: \.name) { group in
                Section(group.name.isEmpty ? L("No group") : group.name) {
                    ForEach(group.jobs) { job in
                        Button(job.name.isEmpty ? L("Untitled task") : job.name) {
                            runtime.runNow(job, modelContext: modelContext)
                        }
                        .disabled(runtime.isRunning(job))
                    }
                }
            }
        }
    }
}
