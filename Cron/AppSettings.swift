import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import ServiceManagement
import SwiftUI
import UserNotifications

nonisolated enum AppSettingsKeys {
    static let appearanceMode = "appearanceMode"
    static let languageIdentifier = "languageIdentifier"
    static let schedulerPaused = "schedulerPaused"
    static let historyRetentionDays = "historyRetentionDays"
    static let historyMaxRunsPerTask = "historyMaxRunsPerTask"
}

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L("System")
        case .light:
            return L("Light")
        case .dark:
            return L("Dark")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

struct AppLanguageOption: Identifiable, Hashable {
    static let automaticIdentifier = "auto"

    var id: String
    var name: String
    var nativeName: String

    var displayName: String {
        let localizedName = AppLocalization.currentLocale.localizedString(forIdentifier: id) ?? name
        let normalizedName = localizedName.capitalized(with: AppLocalization.currentLocale)

        if normalizedName.caseInsensitiveCompare(nativeName) == .orderedSame {
            return nativeName
        }

        return "\(normalizedName) - \(nativeName)"
    }

    static let automatic = AppLanguageOption(
        id: automaticIdentifier,
        name: "Automatic",
        nativeName: "system"
    )

    static let european: [AppLanguageOption] = [
        .init(id: "sq", name: "albański", nativeName: "shqip"),
        .init(id: "hy", name: "ormiański", nativeName: "հայերեն"),
        .init(id: "be", name: "białoruski", nativeName: "беларуская"),
        .init(id: "bs", name: "bośniacki", nativeName: "bosanski"),
        .init(id: "bg", name: "bułgarski", nativeName: "български"),
        .init(id: "ca", name: "kataloński", nativeName: "català"),
        .init(id: "hr", name: "chorwacki", nativeName: "hrvatski"),
        .init(id: "cs", name: "czeski", nativeName: "čeština"),
        .init(id: "da", name: "duński", nativeName: "dansk"),
        .init(id: "nl", name: "niderlandzki", nativeName: "Nederlands"),
        .init(id: "en", name: "angielski", nativeName: "English"),
        .init(id: "et", name: "estoński", nativeName: "eesti"),
        .init(id: "fi", name: "fiński", nativeName: "suomi"),
        .init(id: "fr", name: "francuski", nativeName: "français"),
        .init(id: "ka", name: "gruziński", nativeName: "ქართული"),
        .init(id: "de", name: "niemiecki", nativeName: "Deutsch"),
        .init(id: "el", name: "grecki", nativeName: "Ελληνικά"),
        .init(id: "hu", name: "węgierski", nativeName: "magyar"),
        .init(id: "is", name: "islandzki", nativeName: "íslenska"),
        .init(id: "ga", name: "irlandzki", nativeName: "Gaeilge"),
        .init(id: "it", name: "włoski", nativeName: "italiano"),
        .init(id: "lv", name: "łotewski", nativeName: "latviešu"),
        .init(id: "lt", name: "litewski", nativeName: "lietuvių"),
        .init(id: "lb", name: "luksemburski", nativeName: "Lëtzebuergesch"),
        .init(id: "mk", name: "macedoński", nativeName: "македонски"),
        .init(id: "mt", name: "maltański", nativeName: "Malti"),
        .init(id: "no", name: "norweski", nativeName: "norsk"),
        .init(id: "pl", name: "polski", nativeName: "polski"),
        .init(id: "pt", name: "portugalski", nativeName: "português"),
        .init(id: "ro", name: "rumuński", nativeName: "română"),
        .init(id: "ru", name: "rosyjski", nativeName: "русский"),
        .init(id: "sr", name: "serbski", nativeName: "српски"),
        .init(id: "sk", name: "słowacki", nativeName: "slovenčina"),
        .init(id: "sl", name: "słoweński", nativeName: "slovenščina"),
        .init(id: "es", name: "hiszpański", nativeName: "español"),
        .init(id: "sv", name: "szwedzki", nativeName: "svenska"),
        .init(id: "tr", name: "turecki", nativeName: "Türkçe"),
        .init(id: "uk", name: "ukraiński", nativeName: "українська")
    ]

    static let global: [AppLanguageOption] = [
        .init(id: "zh-Hans", name: "chiński uproszczony", nativeName: "简体中文"),
        .init(id: "hi", name: "hindi", nativeName: "हिन्दी"),
        .init(id: "ar", name: "arabski", nativeName: "العربية"),
        .init(id: "bn", name: "bengalski", nativeName: "বাংলা"),
        .init(id: "id", name: "indonezyjski", nativeName: "Bahasa Indonesia")
    ]

    static let allSupported: [AppLanguageOption] = [automatic] + european + global

    static func localeIdentifier(for selectedIdentifier: String) -> String {
        selectedIdentifier == automaticIdentifier ? Locale.autoupdatingCurrent.identifier : selectedIdentifier
    }

    static func validatedIdentifier(_ identifier: String) -> String {
        allSupported.contains(where: { $0.id == identifier }) ? identifier : automaticIdentifier
    }
}

struct AppSettingsView: View {
    @AppStorage(AppSettingsKeys.appearanceMode) private var appearanceModeRawValue = AppAppearanceMode.system.rawValue
    @AppStorage(AppSettingsKeys.languageIdentifier) private var languageIdentifier = AppLanguageOption.automaticIdentifier
    @AppStorage(AppSettingsKeys.historyRetentionDays) private var historyRetentionDays = RunHistory.defaultRetentionDays
    @AppStorage(AppSettingsKeys.historyMaxRunsPerTask) private var historyMaxRunsPerTask = RunHistory.defaultMaxRunsPerTask
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var launchAtLoginError: String?
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var screenCaptureAllowed = CGPreflightScreenCaptureAccess()
    @State private var notificationStatus = UNAuthorizationStatus.notDetermined

    var body: some View {
        Form {
            Section(L("Appearance")) {
                Picker(L("Color"), selection: $appearanceModeRawValue) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L("Language")) {
                Picker(L("Application language"), selection: $languageIdentifier) {
                    Text(L("Automatic - system")).tag(AppLanguageOption.automatic.id)

                    Divider()

                    ForEach(AppLanguageOption.european + AppLanguageOption.global) { language in
                        Text(language.displayName).tag(language.id)
                    }
                }

                Text(L("By default, the app uses the system language. English is listed once, without a separate American variant."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L("Background")) {
                Toggle(L("Open at login"), isOn: launchAtLoginBinding)

                Text(launchAtLoginStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L("Run history")) {
                Stepper(value: $historyRetentionDays, in: 1...365) {
                    Text("\(L("Keep runs for")) \(historyRetentionDays) \(L("days"))")
                }

                Stepper(value: $historyMaxRunsPerTask, in: 10...1_000, step: 10) {
                    Text("\(L("At most per task")): \(historyMaxRunsPerTask)")
                }
            }

            Section(L("macOS permissions")) {
                PermissionRow(
                    title: L("Background items"),
                    status: launchAtLoginPermissionStatus,
                    description: L("Required for Cron to start at login and keep the scheduler available from the menu bar."),
                    buttonTitle: launchAtLoginStatus == .requiresApproval ? L("Open System Settings") : L("Open"),
                    action: {
                        PermissionSettings.openLoginItems()
                    }
                )

                PermissionRow(
                    title: L("Full Disk Access"),
                    status: L("Recommended"),
                    description: L("Recommended for shell scripts that read or write protected folders such as Desktop, Documents, Downloads, Mail, Safari data, Time Machine backups, or other app data."),
                    buttonTitle: L("Open"),
                    action: {
                        PermissionSettings.openFullDiskAccess()
                    }
                )

                PermissionRow(
                    title: L("Files and Folders"),
                    status: L("Optional"),
                    description: L("Useful when you do not want to grant Full Disk Access, but every protected folder may require a separate approval."),
                    buttonTitle: L("Open"),
                    action: {
                        PermissionSettings.openFilesAndFolders()
                    }
                )

                PermissionRow(
                    title: L("Automation"),
                    status: L("Requested on first use"),
                    description: L("macOS does not allow adding Automation access manually. Use this button to show the system prompt, then approve Cron."),
                    buttonTitle: L("Ask"),
                    action: requestAutomation
                )

                PermissionRow(
                    title: L("Accessibility"),
                    status: accessibilityTrusted ? L("Allowed") : L("Not allowed"),
                    description: L("Needed for scripts that control the user interface, send keystrokes, click buttons, or drive System Events."),
                    buttonTitle: accessibilityTrusted ? L("Open") : L("Ask"),
                    action: requestAccessibility
                )

                PermissionRow(
                    title: L("Screen Recording"),
                    status: screenCaptureAllowed ? L("Allowed") : L("Not allowed"),
                    description: L("Needed for screenshot actions and scripts that capture the screen."),
                    buttonTitle: screenCaptureAllowed ? L("Open") : L("Ask"),
                    action: requestScreenCapture
                )

                PermissionRow(
                    title: L("Notifications"),
                    status: notificationPermissionStatus,
                    description: L("Needed when Cron should show completion or alert notifications."),
                    buttonTitle: notificationStatus == .notDetermined ? L("Ask") : L("Open"),
                    action: requestNotifications
                )
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: .infinity,
            minHeight: 460,
            idealHeight: 640,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear(perform: refreshSettingsState)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding {
            isLaunchAtLoginEnabled
        } set: { enabled in
            setLaunchAtLogin(enabled)
        }
    }

    private var isLaunchAtLoginEnabled: Bool {
        switch launchAtLoginStatus {
        case .enabled:
            return true
        case .notRegistered, .requiresApproval, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    private var launchAtLoginStatusText: String {
        switch launchAtLoginStatus {
        case .enabled:
            return L("Cron will start at login and keep the scheduler running in the menu bar.")
        case .notRegistered:
            return L("Cron will run in the menu bar only after you open it manually.")
        case .requiresApproval:
            return L("macOS requires approval in System Settings before Cron can run in the background.")
        case .notFound:
            return L("The login item is not available for this build.")
        @unknown default:
            return L("The login item status is unknown.")
        }
    }

    private var launchAtLoginPermissionStatus: String {
        switch launchAtLoginStatus {
        case .enabled:
            return L("Allowed")
        case .notRegistered:
            return L("Off")
        case .requiresApproval:
            return L("Requires approval")
        case .notFound:
            return L("Unavailable")
        @unknown default:
            return L("Unknown")
        }
    }

    private var notificationPermissionStatus: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            return L("Allowed")
        case .denied:
            return L("Not allowed")
        case .notDetermined:
            return L("Not requested")
        @unknown default:
            return L("Unknown")
        }
    }

    private func refreshSettingsState() {
        refreshLaunchAtLoginStatus()
        accessibilityTrusted = AXIsProcessTrusted()
        screenCaptureAllowed = CGPreflightScreenCaptureAccess()
        refreshNotificationStatus()
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }

        refreshLaunchAtLoginStatus()
    }

    private func requestAutomation() {
        PermissionSettings.openAutomation()

        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        if let descriptor = target.aeDesc {
            _ = AEDeterminePermissionToAutomateTarget(
                descriptor,
                AEEventClass(kCoreEventClass),
                AEEventID(kAEActivate),
                true
            )
        }

        let script = NSAppleScript(source: """
        tell application "Finder"
            get name of startup disk
        end tell
        """)
        var error: NSDictionary?
        _ = script?.executeAndReturnError(&error)
    }

    private func requestAccessibility() {
        PermissionSettings.openAccessibility()

        // String value of kAXTrustedCheckOptionPrompt; the imported global is not concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    private func requestScreenCapture() {
        PermissionSettings.openScreenRecording()
        screenCaptureAllowed = CGRequestScreenCaptureAccess()
    }

    private func requestNotifications() {
        if notificationStatus == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                await MainActor.run {
                    refreshNotificationStatus()
                }
            }
        } else {
            PermissionSettings.openNotifications()
        }
    }

    private func refreshNotificationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await MainActor.run {
                notificationStatus = settings.authorizationStatus
            }
        }
    }
}

private struct PermissionRow: View {
    var title: String
    var status: String
    var description: String
    var buttonTitle: String
    var action: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.headline)

                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(buttonTitle, action: action)
                    .controlSize(.small)
            }

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private enum PermissionSettings {
    static func openLoginItems() {
        open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    static func openFullDiskAccess() {
        openPrivacy("Privacy_AllFiles")
    }

    static func openFilesAndFolders() {
        openPrivacy("Privacy_FilesAndFolders")
    }

    static func openAutomation() {
        openPrivacy("Privacy_Automation")
    }

    static func openAccessibility() {
        openPrivacy("Privacy_Accessibility")
    }

    static func openScreenRecording() {
        openPrivacy("Privacy_ScreenCapture")
    }

    static func openNotifications() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    private static func openPrivacy(_ anchor: String) {
        open("x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }

        if !NSWorkspace.shared.open(url) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [urlString]

            do {
                try process.run()
            } catch {
                NSLog("Cron: could not open System Settings URL \(urlString): \(error.localizedDescription)")
            }
        }
    }
}
