import AppKit
import SwiftData
import SwiftUI

struct ActionsTabView: View {
    @Environment(\.modelContext) private var modelContext

    @Bindable var job: ScheduledJob
    @State private var searchText = ""
    @State private var selectedCategoryID = ActionCatalog.libraryID
    @State private var selectedActionID: ActionCatalogItem.ID? = "execute-shell-script"
    @State private var workflowSteps: [WorkflowStep] = []
    @State private var selectedStepID: WorkflowStep.ID?
    @State private var saveErrorMessage: String?

    var isRunning: Bool
    var onRunNow: () -> Void
    var onStop: () -> Void

    var body: some View {
        HSplitView {
            ActionLibraryView(
                selectedCategoryID: $selectedCategoryID,
                selectedActionID: $selectedActionID,
                searchText: $searchText,
                actions: filteredActions,
                selectedAction: selectedAction,
                onAdd: addAction
            )
            .frame(minWidth: 420, idealWidth: 500, maxWidth: 720, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Workflow"))
                                .font(.title3.bold())

                            Text(L("Actions run from top to bottom. Add actions from the library on the left."))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if job.workflowLoadError != nil {
                            Label(L("Workflow data could not be read."), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                                .lineLimit(2)
                                .help(job.workflowLoadError ?? "")
                        } else if let saveErrorMessage {
                            Label(saveErrorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(.red)
                                .lineLimit(1)
                        }

                        if isRunning {
                            Button(role: .destructive) {
                                onStop()
                            } label: {
                                Label(L("Stop"), systemImage: "stop.fill")
                            }
                            .keyboardShortcut(".", modifiers: [.command])
                        } else {
                            Button {
                                onRunNow()
                            } label: {
                                Label(L("Run now"), systemImage: "play.fill")
                            }
                            .keyboardShortcut("r", modifiers: [.command])
                        }
                    }

                    WorkflowStepsView(
                        steps: $workflowSteps,
                        selectedStepID: $selectedStepID,
                        onChange: {}
                    )

                    if let selectedStepBinding {
                        ActionStepConfigurationView(step: selectedStepBinding)
                    }

                    ExecutionOutputView(job: job)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: selectedCategoryID) { _, _ in
            selectFirstVisibleActionIfNeeded()
        }
        .onChange(of: searchText) { _, _ in
            selectFirstVisibleActionIfNeeded()
        }
        .onAppear {
            loadWorkflow()
        }
        // Saved on every change, like the other tabs: switching tabs or tasks never loses edits.
        .onChange(of: workflowSteps) { _, steps in
            if steps != job.workflowSteps {
                saveWorkflow()
            }
        }
        .onChange(of: job.workflowJSON) { _, _ in
            // Changed elsewhere (import, task actions); our own saves already match.
            if job.workflowSteps != workflowSteps {
                loadWorkflow()
            }
        }
    }

    private var filteredActions: [ActionCatalogItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryFiltered = selectedCategoryID == ActionCatalog.libraryID
            ? ActionCatalog.items
            : ActionCatalog.items.filter { $0.belongs(to: selectedCategoryID) }

        guard !query.isEmpty else {
            return sortedActions(categoryFiltered)
        }

        return sortedActions(categoryFiltered.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || $0.categoryIDs.contains { ActionCatalog.categoryTitle(for: $0).localizedCaseInsensitiveContains(query) }
        })
    }

    private func sortedActions(_ actions: [ActionCatalogItem]) -> [ActionCatalogItem] {
        actions.sorted { lhs, rhs in
            let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
            if titleComparison != .orderedSame {
                return titleComparison == .orderedAscending
            }

            let categoryComparison = lhs.categoryTitles.localizedStandardCompare(rhs.categoryTitles)
            if categoryComparison != .orderedSame {
                return categoryComparison == .orderedAscending
            }

            return lhs.id < rhs.id
        }
    }

    private var selectedAction: ActionCatalogItem? {
        if let selectedActionID, let selected = filteredActions.first(where: { $0.id == selectedActionID }) {
            return selected
        }

        return filteredActions.first
    }

    private func selectFirstVisibleActionIfNeeded() {
        guard let selectedActionID, filteredActions.contains(where: { $0.id == selectedActionID }) else {
            self.selectedActionID = filteredActions.first?.id
            return
        }
    }

    private var selectedStepBinding: Binding<WorkflowStep>? {
        guard let selectedStepID, let index = workflowSteps.firstIndex(where: { $0.id == selectedStepID }) else {
            return nil
        }

        return Binding(
            get: { workflowSteps[index] },
            set: { updatedStep in
                workflowSteps[index] = updatedStep
            }
        )
    }

    private func addAction(_ action: ActionCatalogItem) {
        var step = WorkflowStep.make(actionType: action.actionType)
        step.title = action.title

        workflowSteps.append(step)
        selectedStepID = step.id
        saveErrorMessage = nil
    }

    private func loadWorkflow() {
        let loadedSteps = job.workflowSteps
        workflowSteps = loadedSteps
        selectedStepID = loadedSteps.first?.id
    }

    private func saveWorkflow() {
        // Never overwrite stored JSON that could not be decoded; the editor shows an empty list then.
        guard job.workflowLoadError == nil else {
            saveErrorMessage = L("Workflow data could not be read.")
            return
        }

        job.workflowSteps = workflowSteps
        job.updatedAt = Date()

        do {
            try modelContext.save()
            saveErrorMessage = nil
        } catch {
            saveErrorMessage = L("Save failed")
        }

        if selectedStepID == nil || !workflowSteps.contains(where: { $0.id == selectedStepID }) {
            selectedStepID = workflowSteps.first?.id
        }
    }
}

struct ActionLibraryView: View {
    @Binding var selectedCategoryID: ActionCatalogCategory.ID
    @Binding var selectedActionID: ActionCatalogItem.ID?
    @Binding var searchText: String

    var actions: [ActionCatalogItem]
    var selectedAction: ActionCatalogItem?
    var onAdd: (ActionCatalogItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(selection: $selectedCategoryID) {
                    ForEach(ActionCatalog.categories) { category in
                        Label(category.title, systemImage: category.symbol)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .tag(category.id)
                    }
                }
                .listStyle(.sidebar)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 340)

                VStack(spacing: 8) {
                    TextField(L("Search"), text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .padding([.top, .horizontal], 10)

                    List(selection: $selectedActionID) {
                        ForEach(actions) { action in
                            ActionCatalogRow(action: action)
                                .tag(Optional(action.id))
                                .contentShape(Rectangle())
                                .highPriorityGesture(
                                    TapGesture(count: 2).onEnded {
                                        selectedActionID = action.id
                                        onAdd(action)
                                    }
                                )
                                .simultaneousGesture(TapGesture(count: 1).onEnded {
                                    selectedActionID = action.id
                                })
                        }
                    }
                    .listStyle(.plain)
                    .overlay {
                        if actions.isEmpty {
                            ContentUnavailableView(L("No actions"), systemImage: "magnifyingglass", description: Text(L("Change the category or search text.")))
                        }
                    }
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: .infinity)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label(L("Action library"), systemImage: "lightbulb.fill")
                    .font(.headline)

                Text(selectedAction?.description ?? L("Select an action from the list."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ActionCatalogRow: View {
    var action: ActionCatalogItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: action.symbol)
                .frame(width: 18)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                    .lineLimit(1)

                Text(action.categoryTitles)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SelectedActionView: View {
    var action: ActionCatalogItem
    var onUse: () -> Void

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text(action.title)
                        .font(.headline)

                    Text(action.description)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(action: onUse) {
                    Label(L("Use"), systemImage: "checkmark.circle")
                }
            }
            .padding(8)
        }
    }
}

struct WorkflowStepsView: View {
    @Binding var steps: [WorkflowStep]
    @Binding var selectedStepID: WorkflowStep.ID?

    var onChange: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("Workflow actions"), systemImage: "list.bullet.rectangle")
                        .font(.headline)

                    Spacer()
                }

                if steps.isEmpty {
                    ContentUnavailableView {
                        Label(L("No actions"), systemImage: "square.dashed")
                    } description: {
                        Text(L("Add an action from the library."))
                    }
                    .frame(minHeight: 120)
                } else {
                    VStack(spacing: 8) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            WorkflowStepRow(
                                index: index,
                                step: step,
                                isSelected: selectedStepID == step.id,
                                onSelect: { selectedStepID = step.id },
                                onToggle: {
                                    steps[index].isEnabled.toggle()
                                    onChange()
                                },
                                onMoveUp: {
                                    moveStep(from: index, to: index - 1)
                                },
                                onMoveDown: {
                                    moveStep(from: index, to: index + 1)
                                },
                                onDelete: {
                                    deleteStep(at: index)
                                }
                            )
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func moveStep(from sourceIndex: Int, to destinationIndex: Int) {
        guard steps.indices.contains(sourceIndex), steps.indices.contains(destinationIndex) else {
            return
        }

        let step = steps.remove(at: sourceIndex)
        steps.insert(step, at: destinationIndex)
        selectedStepID = step.id
        onChange()
    }

    private func deleteStep(at index: Int) {
        guard steps.indices.contains(index) else {
            return
        }

        let removed = steps.remove(at: index)

        if selectedStepID == removed.id {
            selectedStepID = steps[safe: min(index, steps.count - 1)]?.id
        }

        onChange()
    }
}

struct WorkflowStepRow: View {
    @Environment(\.controlActiveState) private var controlActiveState

    var index: Int
    var step: WorkflowStep
    var isSelected: Bool
    var onSelect: () -> Void
    var onToggle: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { step.isEnabled }, set: { _ in onToggle() }))
                .labelsHidden()

            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(secondaryStyle)
                .frame(width: 24)

            Image(systemName: step.actionType.symbol)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.accentColor))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
                    .lineLimit(1)

                Text(step.actionType.description)
                    .font(.caption)
                    .foregroundStyle(secondaryStyle)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onMoveUp) {
                Image(systemName: "arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)
            .help(L("Move up"))

            Button(action: onMoveDown) {
                Image(systemName: "arrow.down")
            }
            .buttonStyle(.borderless)
            .help(L("Move down"))

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L("Delete"))
        }
        .padding(10)
        .tint(isHighlighted ? .white : nil)
        // Like a list selection: the selected action is filled, the others only outlined.
        .background(selectionBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.3))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    /// Selected in the active window: strong selection color with white text.
    private var isHighlighted: Bool {
        isSelected && controlActiveState != .inactive
    }

    private var secondaryStyle: AnyShapeStyle {
        isHighlighted ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary)
    }

    private var selectionBackground: Color {
        guard isSelected else {
            return .clear
        }

        return Color(nsColor: isHighlighted ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }
}

struct ExecutionOutputView: View {
    @Bindable var job: ScheduledJob

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("Last execution"), systemImage: "list.bullet.rectangle")
                        .font(.headline)

                    Spacer()

                    Text(job.status.title)
                        .foregroundStyle(statusColor)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text(L("Run count"))
                            .foregroundStyle(.secondary)
                        Text("\(job.runCount)")
                    }

                    GridRow {
                        Text(L("Exit code"))
                            .foregroundStyle(.secondary)
                        Text("\(job.lastExitCode)")
                    }

                    GridRow {
                        Text(L("Reason"))
                            .foregroundStyle(.secondary)
                        Text(job.lastRunReason.isEmpty ? "-" : job.lastRunReason)
                    }

                    GridRow {
                        Text(L("Last run"))
                            .foregroundStyle(.secondary)
                        Text(job.lastRunAt?.formatted(date: .abbreviated, time: .standard) ?? "-")
                    }
                }

                ScrollView {
                    Text(job.lastOutput.isEmpty ? L("No output yet.") : job.lastOutput)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .frame(minHeight: 120)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2))
                }
            }
            .padding(8)
        }
    }

    private var statusColor: Color {
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
