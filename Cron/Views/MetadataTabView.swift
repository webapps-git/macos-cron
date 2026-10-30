import AppKit
import SwiftData
import SwiftUI

struct MetadataTabView: View {
    @Bindable var job: ScheduledJob
    var onScheduleChange: () -> Void

    @Query private var allJobs: [ScheduledJob]

    private var existingGroups: [String] {
        Set(allJobs.map(\.groupName.trimmed)).filter { !$0.isEmpty }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Taskname"))
                        .font(.headline)

                    TextField(L("Untitled task"), text: $job.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 620)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Group"))
                        .font(.headline)

                    HStack {
                        TextField(L("No group"), text: $job.groupName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)

                        Menu {
                            ForEach(existingGroups, id: \.self) { group in
                                Button(group) {
                                    job.groupName = group
                                }
                            }

                            if !existingGroups.isEmpty {
                                Divider()
                            }

                            Button(L("No group")) {
                                job.groupName = ""
                            }
                        } label: {
                            Image(systemName: "folder")
                        }
                        .fixedSize()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Description"))
                        .font(.headline)

                    TextEditor(text: $job.jobDescription)
                        .font(.body)
                        .frame(maxWidth: 620, minHeight: 120)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.28))
                        }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Toggle(L("Task enabled"), isOn: $job.isEnabled)
                        .fontWeight(.semibold)
                        .onChange(of: job.isEnabled) { _, _ in
                            onScheduleChange()
                        }

                    HStack(spacing: 12) {
                        Toggle(L("Maximum executions"), isOn: maximumExecutionsEnabled)

                        Stepper(value: maximumExecutionsValue, in: 1...999) {
                            Text("\(job.maximumExecutions ?? 1)")
                                .frame(width: 44, alignment: .leading)
                        }
                        .disabled(job.maximumExecutions == nil)
                    }

                    Picker("", selection: $job.maximumExecutionsBehaviorRawValue) {
                        ForEach(MaximumExecutionsBehavior.allCases) { behavior in
                            Text(L(behavior.titleKey)).tag(behavior.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .disabled(job.maximumExecutions == nil)
                    .padding(.leading, 28)

                    HStack(spacing: 12) {
                        Toggle(L("Available through a link"), isOn: $job.allowsURLTrigger)

                        if job.allowsURLTrigger {
                            Text(URLCommand.runLink(taskName: job.name))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(URLCommand.runLink(taskName: job.name), forType: .string)
                            } label: {
                                Label(L("Copy link"), systemImage: "doc.on.doc")
                            }
                        }
                    }

                    if job.allowsURLTrigger {
                        Text(L("Any app on this Mac can open the link. It only starts the task while the task is enabled and the scheduler is not paused."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 28)
                    }

                    HStack {
                        Text(L("Notifications"))
                        Picker(L("Notifications"), selection: $job.notificationModeRawValue) {
                            ForEach(NotificationMode.allCases) { mode in
                                Text(L(mode.titleKey)).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var maximumExecutionsEnabled: Binding<Bool> {
        Binding {
            job.maximumExecutions != nil
        } set: { isEnabled in
            job.maximumExecutions = isEnabled ? max(1, job.maximumExecutions ?? 1) : nil
            onScheduleChange()
        }
    }

    private var maximumExecutionsValue: Binding<Int> {
        Binding {
            job.maximumExecutions ?? 1
        } set: { value in
            job.maximumExecutions = value
            onScheduleChange()
        }
    }
}
