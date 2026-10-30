import Foundation

/// A `webapps-cron://` link. Any app on the Mac can open such a link without asking, so the only
/// command is starting a task, and only tasks with "Available through a link" accept it.
nonisolated enum URLCommand: Equatable, Sendable {
    static let scheme = "webapps-cron"

    enum TaskReference: Equatable, Sendable {
        case name(String)
        case id(UUID)
    }

    /// `webapps-cron://run?task=Name` or `webapps-cron://run?id=UUID`.
    case run(TaskReference)

    enum ParseError: Error, Equatable {
        case wrongScheme
        case unknownCommand(String)
        case missingTask
    }

    static func parse(_ url: URL) -> Result<URLCommand, ParseError> {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.wrongScheme)
        }

        let command = (components.host ?? "").lowercased()

        guard command == "run" else {
            return .failure(.unknownCommand(command))
        }

        let items = components.queryItems ?? []

        if let value = items.first(where: { $0.name == "id" })?.value, let id = UUID(uuidString: value) {
            return .success(.run(.id(id)))
        }

        if let name = items.first(where: { $0.name == "task" })?.value?.trimmed, !name.isEmpty {
            return .success(.run(.name(name)))
        }

        return .failure(.missingTask)
    }

    /// The link shown in the Metadata tab.
    static func runLink(taskName: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "run"
        components.queryItems = [URLQueryItem(name: "task", value: taskName)]
        return components.string ?? "\(scheme)://run"
    }
}
