import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var runtime: TaskRuntime
    @Query(sort: \ScheduledJob.createdAt, order: .reverse) private var jobs: [ScheduledJob]

    @State private var selection: Set<UUID> = []
    @State private var selectedTab: JobEditorTab = .metadata
    /// Run to select in the History tab (menu bar "Last error", notification "Show result").
    @State private var requestedRunID: UUID?
    @State private var searchText = ""
    @State private var collapsedGroups: Set<String> = []
    @State private var pendingDeletion: [UUID] = []
    @State private var alertMessage: String?
    @AppStorage("taskListOrder") private var orderRawValue = TaskListOrder.name.rawValue

    private var order: TaskListOrder {
        TaskListOrder(rawValue: orderRawValue) ?? .name
    }

    private var visibleJobs: [ScheduledJob] {
        order.sorted(jobs.filter { TaskSearch.matches($0, query: searchText) })
    }

    /// Named groups alphabetically, tasks without a group last.
    private var groups: [(name: String, jobs: [ScheduledJob])] {
        let grouped = Dictionary(grouping: visibleJobs) { $0.groupName.trimmed }
        let names = grouped.keys.filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var result = names.map { (name: $0, jobs: grouped[$0] ?? []) }
        if let ungrouped = grouped[""], !ungrouped.isEmpty {
            result.append((name: "", jobs: ungrouped))
        }
        return result
    }

    private var selectedJobs: [ScheduledJob] {
        jobs.filter { selection.contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(groups, id: \.name) { group in
                    Section(isExpanded: expansionBinding(group.name)) {
                        ForEach(group.jobs) { job in
                            JobSidebarRow(
                                job: job,
                                isRunning: runtime.isRunning(job),
                                onToggleEnabled: { setEnabled(!job.isEnabled, for: [job]) }
                            )
                            .tag(job.id)
                        }
                    } header: {
                        Text(group.name.isEmpty ? L("No group") : group.name)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: L("Search tasks"))
            .navigationTitle(L("Tasks"))
            .contextMenu(forSelectionType: UUID.self) { ids in
                contextMenu(for: ids)
            }
            .onDeleteCommand {
                requestDeletion(of: selection)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: addJob) {
                    Label(L("New Task"), systemImage: "plus")
                }

                Button(role: .destructive) {
                    requestDeletion(of: selection)
                } label: {
                    Label(L("Delete Task"), systemImage: "trash")
                }
                .disabled(selection.isEmpty)

                Menu {
                    Picker(L("Sort by"), selection: $orderRawValue) {
                        ForEach(TaskListOrder.allCases) { order in
                            Text(L(order.titleKey)).tag(order.rawValue)
                        }
                    }
                    .pickerStyle(.inline)

                    Divider()

                    Button(L("Import Tasks…"), action: importTasks)
                    Button(L("Export Selected Tasks…")) {
                        export(selectedJobs)
                    }
                    .disabled(selection.isEmpty)
                    Button(L("Export All Tasks…")) {
                        export(jobs)
                    }
                    .disabled(jobs.isEmpty)
                } label: {
                    Label(L("More"), systemImage: "ellipsis.circle")
                }

                Button(action: showSettings) {
                    Label(L("Settings"), systemImage: "gearshape")
                }
            }
        }
        .frame(minWidth: 1_240, minHeight: 760)
        .onAppear {
            AppPresence.showWindows()
            selectFirstJobIfNeeded()
            openRequestedHistory()
        }
        .onChange(of: runtime.navigationRequest) { _, _ in
            openRequestedHistory()
        }
        .onChange(of: jobs.map(\.id)) { _, ids in
            selection.formIntersection(ids)
            selectFirstJobIfNeeded()
        }
        .confirmationDialog(deletionTitle, isPresented: deletionBinding) {
            Button(L("Delete"), role: .destructive) {
                delete(pendingDeletion)
            }
        } message: {
            Text(L("Their run history is deleted as well."))
        }
        .alert("Cron", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? runtime.storeRecoveryNotice ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        let selected = selectedJobs

        if selected.count == 1, let job = selected.first {
            JobEditorView(
                job: job,
                selectedTab: $selectedTab,
                requestedRunID: requestedRunID,
                isRunning: runtime.isRunning(job),
                runtimeMessage: runtime.lastRuntimeMessage,
                onRunNow: { runtime.runNow(job, modelContext: modelContext) },
                onStop: { runtime.stop(job) },
                onScheduleChange: { runtime.rescheduleIfNeeded(job) }
            )
        } else if selected.count > 1 {
            MultipleSelectionView(
                count: selected.count,
                onExport: { export(selected) },
                onEnable: { setEnabled(true, for: selected) },
                onDisable: { setEnabled(false, for: selected) },
                onDelete: { requestDeletion(of: selection) }
            )
        } else {
            EmptyTaskView(onCreate: addJob)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<UUID>) -> some View {
        let targets = jobs.filter { ids.contains($0.id) }

        if targets.count == 1, let job = targets.first {
            Button(runtime.isRunning(job) ? L("Stop") : L("Run now")) {
                if runtime.isRunning(job) {
                    runtime.stop(job)
                } else {
                    runtime.runNow(job, modelContext: modelContext)
                }
            }

            Button(job.isEnabled ? L("Disable") : L("Enable")) {
                setEnabled(!job.isEnabled, for: [job])
            }

            Button(L("Duplicate")) {
                duplicate(job)
            }
        } else if !targets.isEmpty {
            Button(L("Enable")) {
                setEnabled(true, for: targets)
            }

            Button(L("Disable")) {
                setEnabled(false, for: targets)
            }
        }

        if !targets.isEmpty {
            Button(L("Export…")) {
                export(targets)
            }

            Divider()

            Button(L("Delete…"), role: .destructive) {
                requestDeletion(of: ids)
            }
        }
    }

    // MARK: Bindings

    private func expansionBinding(_ group: String) -> Binding<Bool> {
        Binding {
            !collapsedGroups.contains(group)
        } set: { isExpanded in
            if isExpanded {
                collapsedGroups.remove(group)
            } else {
                collapsedGroups.insert(group)
            }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding {
            !pendingDeletion.isEmpty
        } set: { isPresented in
            if !isPresented {
                pendingDeletion = []
            }
        }
    }

    private var deletionTitle: String {
        if pendingDeletion.count == 1, let job = jobs.first(where: { $0.id == pendingDeletion[0] }) {
            return "\(L("Delete task")) „\(job.name)”?"
        }

        return "\(L("Delete tasks")): \(pendingDeletion.count)?"
    }

    private var alertBinding: Binding<Bool> {
        Binding {
            alertMessage != nil || runtime.storeRecoveryNotice != nil
        } set: { isPresented in
            if !isPresented {
                alertMessage = nil
                runtime.storeRecoveryNotice = nil
            }
        }
    }

    // MARK: Actions

    private func addJob() {
        let job = ScheduledJob(name: nextUntitledName())
        modelContext.insert(job)
        save()
        selection = [job.id]
        selectedTab = .metadata
    }

    private func requestDeletion(of ids: Set<UUID>) {
        pendingDeletion = jobs.filter { ids.contains($0.id) }.map(\.id)
    }

    private func delete(_ ids: [UUID]) {
        for job in jobs where ids.contains(job.id) {
            runtime.stop(job)
            modelContext.delete(job)
        }

        save()
        selection.subtract(ids)
        pendingDeletion = []
    }

    private func setEnabled(_ isEnabled: Bool, for targets: [ScheduledJob]) {
        for job in targets {
            job.isEnabled = isEnabled
            job.updatedAt = Date()
            runtime.rescheduleIfNeeded(job)
        }
        save()
    }

    private func duplicate(_ job: ScheduledJob) {
        do {
            let copy = try TaskTransfer.duplicate(job, existingNames: Set(jobs.map(\.name)), copySuffix: L("copy"))
            modelContext.insert(copy)
            save()
            selection = [copy.id]
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func export(_ targets: [ScheduledJob]) {
        guard !targets.isEmpty else {
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = targets.count == 1 ? "\(targets[0].name).json" : "Cron Tasks.json"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try TaskTransfer.exportData(targets).write(to: url, options: .atomic)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func importTasks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let imported = try TaskTransfer.importTasks(from: Data(contentsOf: url), into: modelContext, existingNames: Set(jobs.map(\.name)))
            save()
            selection = Set(imported.map(\.id))
            alertMessage = "\(L("Imported tasks")): \(imported.count). \(L("Imported tasks are disabled until you enable them."))"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openRequestedHistory() {
        guard let request = runtime.navigationRequest else {
            return
        }

        runtime.navigationRequest = nil

        guard jobs.contains(where: { $0.id == request.jobID }) else {
            return
        }

        searchText = ""
        selection = [request.jobID]
        selectedTab = .history
        requestedRunID = request.runID
    }

    private func selectFirstJobIfNeeded() {
        guard selection.isEmpty, let first = visibleJobs.first ?? jobs.first else {
            return
        }

        selection = [first.id]
    }

    private func nextUntitledName() -> String {
        TaskTransfer.uniqueName("\(L("Untitled")) \(jobs.count + 1)", existing: Set(jobs.map(\.name)))
    }

    private func save() {
        do {
            try modelContext.save()
        } catch {
            alertMessage = "\(L("Save failed")): \(error.localizedDescription)"
        }
    }
}

struct JobSidebarRow: View {
    var job: ScheduledJob
    var isRunning: Bool
    var onToggleEnabled: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { job.isEnabled }, set: { _ in onToggleEnabled() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(job.isEnabled ? L("Disable") : L("Enable"))

            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.name.isEmpty ? L("Untitled task") : job.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        if isRunning {
            return L("Running")
        }

        if !job.isEnabled {
            return L("Disabled")
        }

        if let next = job.nextRunAt {
            return "\(L("Next")): \(next.formatted(date: .abbreviated, time: .shortened))"
        }

        return job.scheduleRules.isEmpty ? L("No schedule") : L("No upcoming runs")
    }

    private var statusIcon: String {
        if isRunning {
            return "hourglass"
        }

        switch job.status {
        case .idle:
            return "clock"
        case .running:
            return "hourglass"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        if !job.isEnabled {
            return .secondary
        }

        switch job.status {
        case .idle:
            return .secondary
        case .running:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }
}

struct MultipleSelectionView: View {
    var count: Int
    var onExport: () -> Void
    var onEnable: () -> Void
    var onDisable: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("\(L("Selected tasks")): \(count)", systemImage: "checklist")
        } actions: {
            HStack {
                Button(L("Enable"), action: onEnable)
                Button(L("Disable"), action: onDisable)
                Button(L("Export…"), action: onExport)
                Button(L("Delete…"), role: .destructive, action: onDelete)
            }
        }
    }
}

struct EmptyTaskView: View {
    var onCreate: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L("No task selected"), systemImage: "calendar.badge.clock")
        } description: {
            Text(L("Create a task to configure shell actions, schedules, and macOS events."))
        } actions: {
            Button(L("Create Task"), action: onCreate)
        }
    }
}
