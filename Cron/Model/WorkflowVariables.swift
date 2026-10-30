import Foundation

/// Values for the `{…}` placeholders in action fields and the `CRON_*` variables of scripts.
nonisolated struct WorkflowVariables: Sendable {
    /// Each `CRON_*` value keeps at most its last 64 KB; all of them together at most 256 KB.
    /// macOS allows about 1 MB for a process's arguments and environment (`ARG_MAX`); beyond that
    /// the script would not start at all (E2BIG).
    static let environmentValueLimit = 64 * 1024
    static let environmentTotalLimit = 256 * 1024

    /// `CRON_*` variables of the workflow step being run; `ShellScriptRunner` adds them to every
    /// process the step starts (shell script, AppleScript, Shortcuts, …).
    @TaskLocal static var processEnvironment: [String: String] = [:]

    var taskName = ""
    /// Start of the run: `{date}` and `{time}` stay the same in every step.
    var date = Date()
    var previousOutput = ""
    /// Output of step N (its 1-based position in the workflow list, as shown in the Actions tab).
    var stepOutputs: [Int: String] = [:]
    var file = ""
    var app = ""

    /// e.g. `2026-10-30`.
    var dateText: String {
        Self.format(date, "yyyy-MM-dd")
    }

    /// e.g. `14-05-30`: no colons, so it can be used in file names.
    var timeText: String {
        Self.format(date, "HH-mm-ss")
    }

    /// The value of a placeholder name (without braces), or `nil` for an unknown name.
    func value(for name: String) -> String? {
        switch name {
        case "previous":
            return previousOutput
        case "task":
            return taskName
        case "date":
            return dateText
        case "time":
            return timeText
        case "file":
            return file
        case "app":
            return app
        default:
            if name.hasPrefix("step:"), let number = Int(name.dropFirst("step:".count)) {
                // A step that did not run (yet) gives an empty value.
                return stepOutputs[number] ?? ""
            }

            return nil
        }
    }

    /// Replaces known placeholders; unknown ones (e.g. `{name}` or plain braces) stay as they are.
    func substitute(in text: String, percentEncoded: Bool = false) -> String {
        guard text.contains("{") else {
            return text
        }

        var result = ""
        var rest = text[...]

        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)

            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                rest = rest[open...]
                break
            }

            if let value = value(for: String(rest[afterOpen..<close])) {
                result += percentEncoded ? Self.percentEncoded(value) : value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[afterOpen...]
            }
        }

        return result + rest
    }

    /// The step with placeholders replaced in its configuration. Script bodies and raw argument
    /// strings are left unchanged: inserting text there could inject shell commands, so scripts get
    /// the values only as `CRON_*` environment variables.
    func applied(to step: WorkflowStep) -> WorkflowStep {
        let excluded = Self.excludedFields(step.actionType)

        guard
            let data = try? JSONEncoder().encode(step),
            case .object(var fields)? = try? JSONDecoder().decode(JSONValue.self, from: data),
            case .object(var config)? = fields["config"]
        else {
            return step
        }

        for (key, value) in config where !excluded.contains(key) {
            config[key] = substitute(value, percentEncoded: key == "url")
        }

        fields["config"] = .object(config)

        guard
            let updated = try? JSONEncoder().encode(JSONValue.object(fields)),
            let result = try? JSONDecoder().decode(WorkflowStep.self, from: updated)
        else {
            return step
        }

        return result
    }

    /// `CRON_*` variables for processes started by the current step.
    var environment: [String: String] {
        var values: [String: String] = [:]
        var budget = Self.environmentTotalLimit

        func add(_ key: String, _ value: String) {
            let capped = Self.capped(value)
            let size = key.utf8.count + capped.utf8.count + 2

            guard size <= budget else {
                return
            }

            values[key] = capped
            budget -= size
        }

        add("CRON_TASK_NAME", taskName)
        add("CRON_DATE", dateText)
        add("CRON_TIME", timeText)
        add("CRON_FILE", file)
        add("CRON_APP", app)
        add("CRON_PREVIOUS_OUTPUT", previousOutput)

        // Newest steps first: when the budget runs out, the oldest outputs are left out.
        for number in stepOutputs.keys.sorted(by: >) {
            add("CRON_STEP_\(number)_OUTPUT", stepOutputs[number] ?? "")
        }

        return values
    }

    private func substitute(_ value: JSONValue, percentEncoded: Bool) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(substitute(in: text, percentEncoded: percentEncoded))
        case .array(let items):
            return .array(items.map { substitute($0, percentEncoded: percentEncoded) })
        default:
            return value
        }
    }

    private static func excludedFields(_ actionType: TaskActionType) -> Set<String> {
        switch actionType {
        case .shellScript:
            // `arguments` is appended to the command line as written.
            return ["script", "arguments"]
        case .executeAppleScript:
            return ["script"]
        case .runShortcut:
            return ["arguments"]
        default:
            return []
        }
    }

    /// Keeps the end of the text (the last lines are usually the result) and drops NUL characters,
    /// which cannot be passed in an environment variable.
    static func capped(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\0", with: "")

        guard clean.utf8.count > environmentValueLimit else {
            return clean
        }

        return String(decoding: clean.utf8.suffix(environmentValueLimit), as: UTF8.self)
    }

    private static func percentEncoded(_ value: String) -> String {
        // RFC 3986 unreserved characters (ASCII only) stay; everything else is encoded.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
