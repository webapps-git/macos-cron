import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct EventsTabView: View {
    @Bindable var job: ScheduledJob
    /// Called after a change, so the runtime updates watched folders and idle checks.
    var onChange: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Select events which should trigger a task execution. Events and schedules can be defined independently of each other."))
                    .foregroundStyle(.secondary)

                cooldown

                EventGroupBox(title: "System-related events", symbol: "desktopcomputer") {
                    Toggle(L("When Cron starts"), isOn: binding(.appLaunch))
                    Toggle(L("When the system awakes from sleep mode"), isOn: binding(.systemWake))
                    Toggle(L("Before the Mac goes to sleep"), isOn: binding(.beforeSleep))
                    EventNote(text: "macOS lets the Mac sleep after about 30 seconds at the latest; longer tasks are interrupted.")
                }

                EventGroupBox(title: "Screen-related events", symbol: "display") {
                    Toggle(L("When the screen wakes up"), isOn: binding(.screenWake))
                    Toggle(L("When the screen goes to sleep"), isOn: binding(.screenSleep))
                    Toggle(L("When the screen is locked"), isOn: binding(.screenLocked))
                    Toggle(L("When the screen is unlocked"), isOn: binding(.screenUnlocked))
                    Toggle(L("When a screen is connected"), isOn: binding(.screenConnected))
                    Toggle(L("When the screen resolution changes"), isOn: binding(.screenResolutionChanged))
                    Toggle(L("When a screen is disconnected"), isOn: binding(.screenDisconnected))
                }

                EventGroupBox(title: "Events regarding volumes and drives", symbol: "externaldrive") {
                    Toggle(L("When volumes are inserted or drives are connected"), isOn: binding(.volumeMounted))
                    Toggle(L("When volumes are ejected or drives are disconnected"), isOn: binding(.volumeUnmounted))
                }

                EventGroupBox(title: "Folders", symbol: "folder") {
                    ForEach(triggerIDs(.folder), id: \.self) { id in
                        FolderTriggerEditor(trigger: trigger(id), onRemove: { remove(id) })
                    }

                    addButton("Add folder", kind: .folder)
                    EventNote(text: "Each file starts the task once; files that arrive while it runs wait their turn. A task that writes into the folder it watches starts itself again: limit how often events may start it. macOS may ask for access to folders such as Desktop, Documents or Downloads.")
                }

                EventGroupBox(title: "Applications", symbol: "app.badge") {
                    ForEach(triggerIDs(.application), id: \.self) { id in
                        ApplicationTriggerEditor(trigger: trigger(id), onRemove: { remove(id) })
                    }

                    addButton("Add application", kind: .application)
                }

                EventGroupBox(title: "Network", symbol: "network") {
                    Toggle(L("When the network connection is established"), isOn: binding(.networkConnected))
                    Toggle(L("When the network connection is lost"), isOn: binding(.networkDisconnected))
                    Toggle(L("When the network changes"), isOn: binding(.networkChanged))
                    EventNote(text: "A connection means a network is available; it does not guarantee internet access (for example on a hotspot login page). Changes are reported after 5 seconds without further changes.")
                }

                EventGroupBox(title: "Power", symbol: "powerplug") {
                    Toggle(L("When the power adapter is connected"), isOn: binding(.powerAdapter))
                    Toggle(L("When the Mac switches to battery power"), isOn: binding(.batteryPower))

                    ForEach(triggerIDs(.batteryLow), id: \.self) { id in
                        BatteryTriggerEditor(trigger: trigger(id), onRemove: { remove(id) })
                    }

                    addButton("Add battery level", kind: .batteryLow)
                    EventNote(text: "Battery events only occur on a Mac with a battery.")
                }

                EventGroupBox(title: "Activity", symbol: "moon.zzz") {
                    ForEach(triggerIDs(.idle), id: \.self) { id in
                        IdleTriggerEditor(trigger: trigger(id), onRemove: { remove(id) })
                    }

                    addButton("Add idle time", kind: .idle)
                }

                EventGroupBox(title: "Events triggered by tasks", symbol: "arrow.triangle.2.circlepath") {
                    Toggle(L("When another task triggers this task"), isOn: binding(.triggeredByTask))
                    otherTaskToggle(.otherTaskStarted)
                    otherTaskToggle(.otherTaskCancelled)
                    otherTaskToggle(.otherTaskFinished)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cooldown: some View {
        HStack(spacing: 12) {
            Toggle(L("Events start this task at most every"), isOn: Binding {
                job.eventCooldownMinutes > 0
            } set: { isOn in
                job.eventCooldownMinutes = isOn ? max(job.eventCooldownMinutes, 5) : 0
            })

            Stepper(value: $job.eventCooldownMinutes, in: 1...1_440) {
                Text("\(max(job.eventCooldownMinutes, 1)) \(L("minutes"))")
                    .frame(width: 100, alignment: .leading)
            }
            .disabled(job.eventCooldownMinutes == 0)
        }
    }

    @ViewBuilder
    private func otherTaskToggle(_ kind: EventKind) -> some View {
        Toggle(L(kind.titleKey), isOn: binding(kind))

        if let id = job.eventTriggers.first(where: { $0.kind == kind })?.id {
            TaskFilterEditor(trigger: trigger(id))
                .padding(.leading, 20)
        }
    }

    private func addButton(_ title: String, kind: EventKind) -> some View {
        Button {
            job.eventTriggers.append(EventTrigger(kind: kind))
            onChange()
        } label: {
            Label(L(title), systemImage: "plus")
        }
    }

    private func triggerIDs(_ kind: EventKind) -> [UUID] {
        job.eventTriggers.filter { $0.kind == kind }.map(\.id)
    }

    private func trigger(_ id: UUID) -> Binding<EventTrigger> {
        Binding {
            job.eventTriggers.first { $0.id == id } ?? EventTrigger()
        } set: { newValue in
            var triggers = job.eventTriggers

            guard let index = triggers.firstIndex(where: { $0.id == id }) else {
                return
            }

            triggers[index] = newValue
            job.eventTriggers = triggers
            onChange()
        }
    }

    private func remove(_ id: UUID) {
        job.eventTriggers.removeAll { $0.id == id }
        onChange()
    }

    /// On/off for kinds without parameters (one trigger at most).
    private func binding(_ kind: EventKind) -> Binding<Bool> {
        Binding {
            job.triggers(kind)
        } set: { isOn in
            var triggers = job.eventTriggers.filter { $0.kind != kind }
            if isOn {
                triggers.append(EventTrigger(kind: kind))
            }
            job.eventTriggers = triggers
            onChange()
        }
    }
}

struct EventGroupBox<Content: View>: View {
    var title: String
    var symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Label(L(title), systemImage: symbol)
                .font(.headline)
        }
        .frame(maxWidth: 760)
    }
}

private struct EventNote: View {
    var text: String

    var body: some View {
        Text(L(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Frame and remove button around one parameterized trigger.
private struct TriggerCard<Content: View>: View {
    var onRemove: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                content
            }

            Spacer()

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete"))
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct FolderTriggerEditor: View {
    @Binding var trigger: EventTrigger
    var onRemove: () -> Void

    var body: some View {
        TriggerCard(onRemove: onRemove) {
            LabeledPathField(title: "Folder", placeholder: "\(NSHomeDirectory())/Downloads", text: $trigger.folderPath, canChooseFiles: false, canChooseDirectories: true)
            LabeledTextField(title: "File names", placeholder: "*.pdf, *.jpg (empty = all files)", text: $trigger.namePattern)

            HStack(spacing: 16) {
                Toggle(L("New files"), isOn: $trigger.onCreated)
                Toggle(L("Changed files"), isOn: $trigger.onModified)
                Toggle(L("Deleted files"), isOn: $trigger.onRemoved)
            }

            Toggle(L("Include subfolders"), isOn: $trigger.includeSubfolders)
            Toggle(L("Wait until the file stops changing"), isOn: $trigger.waitUntilStable)
        }
    }
}

private struct ApplicationTriggerEditor: View {
    @Binding var trigger: EventTrigger
    var onRemove: () -> Void

    var body: some View {
        TriggerCard(onRemove: onRemove) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L("Application"))
                    .foregroundStyle(.secondary)
                    .frame(width: 140, alignment: .leading)

                TextField(L("Application name"), text: Binding {
                    trigger.appName
                } set: { name in
                    // A typed name replaces a chosen application.
                    trigger.appName = name
                    trigger.appBundleID = ""
                })
                .textFieldStyle(.roundedBorder)

                Button {
                    chooseApplication()
                } label: {
                    Image(systemName: "app.badge")
                }
                .help(L("Choose application"))
            }

            if !trigger.appBundleID.isEmpty {
                Text(trigger.appBundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 152)
            }

            HStack(spacing: 16) {
                Toggle(L("When launched"), isOn: $trigger.onLaunch)
                Toggle(L("When quit"), isOn: $trigger.onQuit)
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = L("Choose application")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        let bundle = Bundle(url: url)
        trigger.appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        trigger.appBundleID = bundle?.bundleIdentifier ?? ""
    }
}

private struct BatteryTriggerEditor: View {
    @Binding var trigger: EventTrigger
    var onRemove: () -> Void

    var body: some View {
        TriggerCard(onRemove: onRemove) {
            Stepper(value: $trigger.batteryPercent, in: 5...95, step: 5) {
                Text("\(L("When the battery level drops below")) \(trigger.batteryPercent)%")
            }
        }
    }
}

private struct IdleTriggerEditor: View {
    @Binding var trigger: EventTrigger
    var onRemove: () -> Void

    var body: some View {
        TriggerCard(onRemove: onRemove) {
            Stepper(value: $trigger.idleMinutes, in: 1...240) {
                Text("\(L("No keyboard or mouse activity for")) \(trigger.idleMinutes) \(L("minutes"))")
            }

            HStack(spacing: 16) {
                Toggle(L("When the idle time is reached"), isOn: $trigger.onIdleStart)
                Toggle(L("When activity resumes"), isOn: $trigger.onIdleEnd)
            }
        }
    }
}

private struct TaskFilterEditor: View {
    @Binding var trigger: EventTrigger

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledTextField(title: "Tasks", placeholder: "Any task (names separated by commas)", text: Binding {
                trigger.taskNames.joined(separator: ", ")
            } set: { text in
                trigger.taskNames = text.split(separator: ",").map { String($0).trimmed }
            })

            if trigger.kind == .otherTaskFinished {
                HStack {
                    Text(L("Result"))
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)

                    Picker(L("Result"), selection: $trigger.taskOutcome) {
                        ForEach(TaskOutcomeFilter.allCases) { filter in
                            Text(L(filter.titleKey)).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
        }
    }
}
