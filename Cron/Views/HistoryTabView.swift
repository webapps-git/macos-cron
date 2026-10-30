import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct HistoryTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var job: ScheduledJob
    var requestedRunID: UUID?

    @State private var selectedRunID: TaskRun.ID?
    @State private var isConfirmingClear = false

    private var runs: [TaskRun] {
        job.runs.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("Run history"))
                        .font(.headline)

                    Spacer()

                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label(L("Clear history"), systemImage: "trash")
                    }
                    .disabled(runs.isEmpty)
                }
                .padding(12)

                Divider()

                if runs.isEmpty {
                    ContentUnavailableView {
                        Label(L("No runs yet"), systemImage: "clock")
                    } description: {
                        Text(L("Runs of this task appear here."))
                    }
                } else {
                    List(runs, selection: $selectedRunID) { run in
                        RunRow(run: run)
                            .tag(run.id)
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)

            Group {
                if let run = runs.first(where: { $0.id == selectedRunID }) ?? runs.first {
                    RunDetailView(run: run, jobName: job.name)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(L("Clear the run history of this task?"), isPresented: $isConfirmingClear) {
            Button(L("Clear history"), role: .destructive) {
                for run in job.runs {
                    modelContext.delete(run)
                }
                try? modelContext.save()
                selectedRunID = nil
            }
        }
        .onChange(of: requestedRunID, initial: true) { _, runID in
            if let runID {
                selectedRunID = runID
            }
        }
    }
}

private struct RunRow: View {
    var run: TaskRun

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: run.outcome.symbol)
                .foregroundStyle(OutcomeStyle.color(run.outcome))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                    .monospacedDigit()

                Text("\(L(run.outcome.titleKey)) · \(DurationFormat.text(run.finishedAt.timeIntervalSince(run.startedAt))) · \(run.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct RunDetailView: View {
    var run: TaskRun
    var jobName: String

    var body: some View {
        let steps = run.steps

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Label(L(run.outcome.titleKey), systemImage: run.outcome.symbol)
                        .font(.title3.bold())
                        .foregroundStyle(OutcomeStyle.color(run.outcome))

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fullOutput(steps), forType: .string)
                    } label: {
                        Label(L("Copy output"), systemImage: "doc.on.doc")
                    }

                    Button {
                        saveOutput(steps)
                    } label: {
                        Label(L("Save to file…"), systemImage: "square.and.arrow.down")
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text(L("Started")).foregroundStyle(.secondary)
                        Text(run.startedAt.formatted(date: .complete, time: .standard))
                    }
                    GridRow {
                        Text(L("Duration")).foregroundStyle(.secondary)
                        Text(DurationFormat.text(run.finishedAt.timeIntervalSince(run.startedAt)))
                    }
                    GridRow {
                        Text(L("Reason")).foregroundStyle(.secondary)
                        Text(run.reason)
                    }
                    GridRow {
                        Text(L("Exit code")).foregroundStyle(.secondary)
                        Text("\(run.exitCode)")
                    }
                }

                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: step.outcome.symbol)
                                    .foregroundStyle(OutcomeStyle.color(step.outcome))
                                Text("\(index + 1). \(step.title)")
                                    .font(.headline)
                                Spacer()
                                Text(step.attempts > 1
                                    ? "\(DurationFormat.text(step.duration)) · \(L("Exit code")) \(step.exitCode) · \(L("Attempts")) \(step.attempts)"
                                    : "\(DurationFormat.text(step.duration)) · \(L("Exit code")) \(step.exitCode)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if !step.output.isEmpty {
                                Text(step.output)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func fullOutput(_ steps: [StepRunResult]) -> String {
        steps.enumerated()
            .map { index, step in "[\(index + 1)] \(step.title) (\(step.outcome.rawValue), exit \(step.exitCode))\n\(step.output)" }
            .joined(separator: "\n\n")
    }

    private func saveOutput(_ steps: [StepRunResult]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = run.startedAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        panel.nameFieldStringValue = "\(jobName) \(stamp).txt"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try fullOutput(steps).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

enum OutcomeStyle {
    static func color(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        case .timedOut:
            return .orange
        case .conditionNotMet:
            return .blue
        }
    }
}

enum DurationFormat {
    static func text(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(format: "%.0f ms", seconds * 1_000)
        }

        if seconds < 60 {
            return String(format: "%.1f s", seconds)
        }

        let minutes = Int(seconds) / 60
        let rest = Int(seconds) % 60
        return minutes < 60 ? "\(minutes) min \(rest) s" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
