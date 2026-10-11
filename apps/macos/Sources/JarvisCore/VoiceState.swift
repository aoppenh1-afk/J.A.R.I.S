import Foundation

public struct AudioFrequencyBands: Sendable, Equatable {
    public var low: Float
    public var mid: Float
    public var high: Float

    public init(low: Float = 0, mid: Float = 0, high: Float = 0) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public static let zero = AudioFrequencyBands()
}

public enum VoiceState: String, Sendable, Equatable {
    case starting
    case idle
    case listening
    case transcribing
    case thinking
    case tool
    case approval
    case speaking
    case interrupting
    case degraded
    case error
}

public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    public let id: String
    public let prompt: String
    public let choices: [HermesApprovalChoice]

    public init(id: String, prompt: String, choices: [HermesApprovalChoice]) {
        self.id = id
        self.prompt = prompt
        self.choices = choices
    }
}

public struct ConversationTurn: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let userText: String
    public let assistantText: String
    public let provider: SpeechProvider?
    public let sources: [ResponseSource]?

    public init(
        id: UUID = UUID(),
        userText: String,
        assistantText: String,
        provider: SpeechProvider?,
        sources: [ResponseSource]? = nil
    ) {
        self.id = id
        self.userText = userText
        self.assistantText = assistantText
        self.provider = provider
        self.sources = sources?.isEmpty == false ? sources : nil
    }
}

public enum ToolActivityState: String, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

public struct ToolActivity: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let preview: String?
    public var state: ToolActivityState

    public init(
        id: UUID = UUID(),
        name: String,
        preview: String? = nil,
        state: ToolActivityState = .running
    ) {
        self.id = id
        self.name = name
        self.preview = preview
        self.state = state
    }
}

public struct TurnMetrics: Sendable, Equatable {
    public var captureMilliseconds: Int?
    public var sttMilliseconds: Int?
    public var hermesFirstDeltaMilliseconds: Int?
    public var hermesCompletionMilliseconds: Int?
    public var ttsQueuedMilliseconds: Int?
    public var interruptionMilliseconds: Int?

    public init(
        captureMilliseconds: Int? = nil,
        sttMilliseconds: Int? = nil,
        hermesFirstDeltaMilliseconds: Int? = nil,
        hermesCompletionMilliseconds: Int? = nil,
        ttsQueuedMilliseconds: Int? = nil,
        interruptionMilliseconds: Int? = nil
    ) {
        self.captureMilliseconds = captureMilliseconds
        self.sttMilliseconds = sttMilliseconds
        self.hermesFirstDeltaMilliseconds = hermesFirstDeltaMilliseconds
        self.hermesCompletionMilliseconds = hermesCompletionMilliseconds
        self.ttsQueuedMilliseconds = ttsQueuedMilliseconds
        self.interruptionMilliseconds = interruptionMilliseconds
    }
}

public struct VoiceSnapshot: Sendable, Equatable {
    public var state: VoiceState
    public var generation: Int
    public var userText: String
    public var assistantText: String
    public var statusText: String
    public var activeRunID: String?
    public var approval: ApprovalRequest?
    public var speechProvider: SpeechProvider?
    public var routingStatus: SpeechRoutingStatus
    public var metrics: TurnMetrics
    public var toolActivities: [ToolActivity]
    public var sources: [ResponseSource]
    public var followUpPrompts: [String]
    public var audioBands: AudioFrequencyBands
    public init(
        state: VoiceState = .starting,
        generation: Int = 0,
        userText: String = "",
        assistantText: String = "",
        statusText: String = "Starting…",
        activeRunID: String? = nil,
        approval: ApprovalRequest? = nil,
        speechProvider: SpeechProvider? = nil,
        routingStatus: SpeechRoutingStatus = SpeechRoutingStatus(),
        metrics: TurnMetrics = TurnMetrics(),
        toolActivities: [ToolActivity] = [],
        sources: [ResponseSource] = [],
        followUpPrompts: [String] = [],
        audioBands: AudioFrequencyBands = .zero
    ) {
        self.state = state
        self.generation = generation
        self.userText = userText
        self.assistantText = assistantText
        self.statusText = statusText
        self.activeRunID = activeRunID
        self.approval = approval
        self.speechProvider = speechProvider
        self.routingStatus = routingStatus
        self.metrics = metrics
        self.toolActivities = toolActivities
        self.sources = sources
        self.followUpPrompts = followUpPrompts
        self.audioBands = audioBands
    }
}
