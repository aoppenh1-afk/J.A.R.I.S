import Foundation
import Network

public enum ServiceHealth: String, Sendable, Equatable {
    case unknown
    case healthy
    case recovering
    case degraded
    case unavailable
}

public struct RuntimeHealth: Sendable, Equatable {
    public var network: ServiceHealth
    public var hermes: ServiceHealth
    public var audio: ServiceHealth
    public var microphone: ServiceHealth
    public var recoveryAttempt: Int

    public init(
        network: ServiceHealth = .unknown,
        hermes: ServiceHealth = .unknown,
        audio: ServiceHealth = .unknown,
        microphone: ServiceHealth = .unknown,
        recoveryAttempt: Int = 0
    ) {
        self.network = network
        self.hermes = hermes
        self.audio = audio
        self.microphone = microphone
        self.recoveryAttempt = recoveryAttempt
    }
}

public struct RecoveryPolicy: Sendable, Equatable {
    public let delays: [Duration]

    public init(delays: [Duration] = [.zero, .milliseconds(500), .seconds(2)]) {
        self.delays = delays
    }

    public var maximumAttempts: Int { delays.count }

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt >= 1, attempt <= delays.count else { return nil }
        return delays[attempt - 1]
    }
}

public final class ConnectivityMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (Bool) -> Void

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.jarvis.connectivity-monitor")
    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.monitor = NWPathMonitor()
        self.handler = handler
    }

    public func start() {
        monitor.pathUpdateHandler = { [handler] path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }
}
