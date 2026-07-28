import Foundation

public enum DiagnosticEventKind: String, Sendable, Codable, Equatable {
    case appStarted
    case settingsApplied
    case sleepStarted
    case wakeStarted
    case audioDeviceChanged
    case networkAvailable
    case networkUnavailable
    case recoveryStarted
    case recoverySucceeded
    case recoveryFailed
    case hermesExited
    case microphoneAvailable
    case microphoneUnavailable
    case turnFailed
}

public struct DiagnosticEvent: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let kind: DiagnosticEventKind
    public let attempt: Int?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: DiagnosticEventKind,
        attempt: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.attempt = attempt
    }
}

public struct DiagnosticEventBuffer: Sendable, Equatable {
    public let capacity: Int
    public private(set) var events: [DiagnosticEvent]

    public init(capacity: Int = 200, events: [DiagnosticEvent] = []) {
        self.capacity = max(1, capacity)
        self.events = Array(events.suffix(max(1, capacity)))
    }

    public mutating func append(_ event: DiagnosticEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public mutating func clear() {
        events.removeAll(keepingCapacity: true)
    }
}
