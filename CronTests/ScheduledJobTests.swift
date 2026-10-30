import Foundation
import SwiftData
import Testing
@testable import Cron

@MainActor
func makeContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: CronSchemaV1.self)
    return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
}

@MainActor
@Suite("Task model and scheduler")
struct ScheduledJobTests {
    private func dailyJob(at hour: Int, in context: ModelContext) -> ScheduledJob {
        let job = ScheduledJob(name: "Test")
        var rule = ScheduleRule(kind: .dailyTimes)
        rule.times = [TimeOfDay(hour: hour, minute: 0)]
        job.scheduleRules = [rule]
        job.notificationMode = .never
        context.insert(job)
        return job
    }

    @Test func nextRunUsesEarliestRule() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 18, in: container.mainContext)
        var morning = ScheduleRule(kind: .dailyTimes)
        morning.times = [TimeOfDay(hour: 7, minute: 30)]
        job.scheduleRules.append(morning)

        #expect(job.nextRunDate(after: date(2026, 10, 30, 10), calendar: warsaw) == date(2026, 10, 30, 18))
        #expect(job.nextRunDate(after: date(2026, 10, 30, 19), calendar: warsaw) == date(2026, 10, 31, 7, 30))
    }

    @Test func validityPeriodLimitsRuns() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        job.validFrom = date(2026, 11, 5)
        job.validUntil = date(2026, 11, 6, 12)

        #expect(job.nextRunDate(after: date(2026, 10, 30), calendar: warsaw) == date(2026, 11, 5, 9))
        #expect(job.nextRunDate(after: date(2026, 11, 6, 10), calendar: warsaw) == nil)
    }

    @Test func maximumExecutionsStopsScheduling() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        job.maximumExecutions = 2
        job.runCount = 2

        #expect(job.nextRunDate(after: date(2026, 10, 30), calendar: warsaw) == nil)
        #expect(!job.canRun(at: date(2026, 10, 30)))
    }

    @Test func eventTriggersAreStoredAsList() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        job.eventTriggers = [EventTrigger(kind: .screenConnected)]

        #expect(job.triggers(.screenConnected))
        #expect(!job.triggers(.screenDisconnected))
    }

    @Test func unreadableWorkflowIsReportedNotErased() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        job.workflowJSON = "[{broken"

        #expect(job.workflowLoadError != nil)
        #expect(job.workflowSteps.isEmpty)
        #expect(job.workflowJSON == "[{broken")
    }

    // MARK: Missed runs

    private func runtime(_ container: ModelContainer) -> TaskRuntime {
        TaskRuntime(modelContainer: container, defaults: UserDefaults(suiteName: "CronTests.\(UUID().uuidString)")!)
    }

    @Test(arguments: [MissedRunPolicy.runOnce, .skip])
    func lateRunFollowsPolicy(policy: MissedRunPolicy) throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        job.missedRunPolicy = policy
        let now = Date()
        job.nextRunAt = now.addingTimeInterval(-3_600) // Mac was asleep for an hour

        // The job has no actions, so an attempted run is recorded as a failure.
        runtime(container).evaluateSchedule(jobs: [job], modelContext: container.mainContext, now: now)

        #expect(job.status == (policy == .runOnce ? .failed : .idle))
        #expect((job.nextRunAt ?? .distantPast) > now)
    }

    @Test func onTimeRunIgnoresSkipPolicy() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        job.missedRunPolicy = .skip
        let now = Date()
        job.nextRunAt = now.addingTimeInterval(-30)

        runtime(container).evaluateSchedule(jobs: [job], modelContext: container.mainContext, now: now)

        #expect(job.status == .failed)
    }

    @Test func newJobGetsNextRunWithoutRunning() throws {
        let container = try makeContainer()
        let job = dailyJob(at: 9, in: container.mainContext)
        let now = Date()

        runtime(container).evaluateSchedule(jobs: [job], modelContext: container.mainContext, now: now)

        #expect(job.status == .idle)
        #expect((job.nextRunAt ?? .distantPast) > now)
    }
}
