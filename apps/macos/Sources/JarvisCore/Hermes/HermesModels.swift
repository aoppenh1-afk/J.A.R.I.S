import Foundation

public enum HermesApprovalChoice: String, Codable, Sendable, CaseIterable {
    case once
    case session
    case always
    case deny
}

public struct HermesRun: Codable, Sendable, Equatable {
    public let runID: String
    public let status: String
    public let sessionID: String?
    public let output: String?
    public let error: String?
    public let lastEvent: String?

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case status
        case sessionID = "session_id"
        case output
        case error
        case lastEvent = "last_event"
    }
}

public struct HermesEvent: Codable, Sendable, Equatable {
    public let event: String
    public let runID: String
    public let timestamp: Double
    public let delta: String?
    public let output: String?
    public let error: String?
    public let tool: String?
    public let preview: String?
    public let command: String?
    public let choices: [HermesApprovalChoice]?
    public let choice: HermesApprovalChoice?
    public let resolved: Int?
    public let approvalID: String?

    public init(
        event: String,
        runID: String,
        timestamp: Double,
        delta: String? = nil,
        output: String? = nil,
        error: String? = nil,
        tool: String? = nil,
        preview: String? = nil,
        command: String? = nil,
        choices: [HermesApprovalChoice]? = nil,
        choice: HermesApprovalChoice? = nil,
        resolved: Int? = nil,
        approvalID: String? = nil
    ) {
        self.event = event
        self.runID = runID
        self.timestamp = timestamp
        self.delta = delta
        self.output = output
        self.error = error
        self.tool = tool
        self.preview = preview
        self.command = command
        self.choices = choices
        self.choice = choice
        self.resolved = resolved
        self.approvalID = approvalID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        runID = try container.decode(String.self, forKey: .runID)
        timestamp = try container.decode(Double.self, forKey: .timestamp)
        delta = try container.decodeIfPresent(String.self, forKey: .delta)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        if let description = try? container.decodeIfPresent(String.self, forKey: .error) {
            error = description
        } else if (try? container.decodeIfPresent(Bool.self, forKey: .error)) == true {
            error = "Tool failed"
        } else {
            error = nil
        }
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        choices = try container.decodeIfPresent([HermesApprovalChoice].self, forKey: .choices)
        choice = try container.decodeIfPresent(HermesApprovalChoice.self, forKey: .choice)
        resolved = try container.decodeIfPresent(Int.self, forKey: .resolved)
        approvalID = try container.decodeIfPresent(String.self, forKey: .approvalID)
    }

    public var isTerminal: Bool {
        event == "run.completed" || event == "run.failed" || event == "run.cancelled"
    }

    enum CodingKeys: String, CodingKey {
        case event
        case runID = "run_id"
        case timestamp
        case delta
        case output
        case error
        case tool
        case preview
        case command
        case choices
        case choice
        case resolved
        case approvalID = "approval_id"
    }
}

public enum HermesClientError: Error, Equatable {
    case invalidResponse
    case http(status: Int, message: String)
    case streamClosedWithoutTerminalEvent
}
