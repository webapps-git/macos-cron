import AppKit
import SwiftData
import SwiftUI

enum JobEditorTab: String, CaseIterable, Identifiable {
    case metadata = "Metadata"
    case actions = "Actions"
    case schedule = "Schedule"
    case events = "Events"
    case history = "History"

    var id: String { rawValue }

    var title: String {
        L(rawValue)
    }

    var symbol: String {
        switch self {
        case .metadata:
            return "tag.fill"
        case .actions:
            return "puzzlepiece.extension.fill"
        case .schedule:
            return "calendar.badge.clock"
        case .events:
            return "bolt.fill"
        case .history:
            return "clock.arrow.circlepath"
        }
    }
}

struct JobEditorView: View {
    @Bindable var job: ScheduledJob
    @Binding var selectedTab: JobEditorTab
    var requestedRunID: UUID? = nil

    var isRunning: Bool
    var runtimeMessage: String
    var onRunNow: () -> Void
    var onStop: () -> Void
    var onScheduleChange: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            JobEditorTabBar(selectedTab: $selectedTab)

            Divider()

            ZStack(alignment: .topLeading) {
                MetadataTabView(job: job, onScheduleChange: onScheduleChange)
                    .visibleTab(selectedTab == .metadata)

                ActionsTabView(job: job, isRunning: isRunning, onRunNow: onRunNow, onStop: onStop)
                    .id(job.id)
                    .visibleTab(selectedTab == .actions)

                ScheduleTabView(job: job, onScheduleChange: onScheduleChange)
                    .id(job.id)
                    .visibleTab(selectedTab == .schedule)

                EventsTabView(job: job, onChange: onScheduleChange)
                    .visibleTab(selectedTab == .events)

                HistoryTabView(job: job, requestedRunID: requestedRunID)
                    .id(job.id)
                    .visibleTab(selectedTab == .history)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            JobStatusBar(job: job, isRunning: isRunning, runtimeMessage: runtimeMessage)
        }
        .navigationTitle(job.name.isEmpty ? L("Untitled task") : job.name)
    }
}

extension View {
    func visibleTab(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .disabled(!isVisible)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .zIndex(isVisible ? 1 : 0)
    }
}

struct JobEditorTabBar: View {
    @Binding var selectedTab: JobEditorTab

    var body: some View {
        HStack(spacing: 10) {
            ForEach(JobEditorTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTab == tab ? Color.accentColor.opacity(0.16) : Color.clear)

                        VStack(spacing: 5) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 22))

                            Text(tab.title)
                                .font(.caption)
                        }
                    }
                    .frame(width: 86, height: 64)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct JobStatusBar: View {
    @Bindable var job: ScheduledJob
    var isRunning: Bool
    var runtimeMessage: String

    var body: some View {
        HStack(spacing: 14) {
            Label(isRunning ? L("Running") : job.status.title, systemImage: isRunning ? "hourglass" : statusIcon)
                .foregroundStyle(statusColor)

            Text(runtimeMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text("\(L("Runs")): \(job.runCount)")
                .foregroundStyle(.secondary)

            if let nextRun = job.nextRunAt ?? job.nextRunDate(after: Date()) {
                Text("\(L("Next")): \(nextRun.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(L("Next")): -")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusIcon: String {
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
        if isRunning {
            return .orange
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

#Preview {
    ContentView()
        .modelContainer(for: ScheduledJob.self, inMemory: true)
}
