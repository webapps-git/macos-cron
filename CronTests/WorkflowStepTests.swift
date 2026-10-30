import Foundation
import Testing
@testable import Cron

@Suite("Workflow steps")
struct WorkflowStepTests {
    @Test(arguments: TaskActionType.allCases)
    func everyActionRoundTripsThroughJSON(actionType: TaskActionType) throws {
        let step = WorkflowStep(actionType: actionType, title: actionType.rawValue)
        let data = try JSONEncoder().encode(step)
        let decoded = try JSONDecoder().decode(WorkflowStep.self, from: data)

        #expect(decoded == step)
    }

    @Test func missingConfigurationFieldsGetDefaults() throws {
        let json = #"{"type":"sendHTTPRequest","title":"Ping","config":{"url":"https://example.org"}}"#
        let step = try JSONDecoder().decode(WorkflowStep.self, from: Data(json.utf8))
        let config = step.configuration(HTTPRequestConfiguration.self)

        #expect(config.url == "https://example.org")
        #expect(config.method == "GET")
        #expect(config.timeoutSeconds == 30)
        #expect(step.isEnabled)
    }

    @Test func unknownActionTypeFailsInsteadOfGuessing() {
        let json = #"{"type":"teleport","title":"?"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WorkflowStep.self, from: Data(json.utf8))
        }
    }

    @Test func taskNamesNeedAtLeastOneName() {
        var step = WorkflowStep(actionType: .enableTasks, title: "Enable")
        step.setConfiguration(TaskNamesConfiguration(names: ["", "  "]))
        #expect(!step.isConfigured)

        step.setConfiguration(TaskNamesConfiguration(names: ["Backup"]))
        #expect(step.isConfigured)
    }

    @Test func checkTasksRunningWorksWithoutNames() {
        #expect(WorkflowStep(actionType: .checkTasksRunning, title: "Check").isConfigured)
    }
}
