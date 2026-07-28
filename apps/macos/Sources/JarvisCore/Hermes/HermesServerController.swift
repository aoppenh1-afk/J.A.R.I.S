import Foundation

public actor HermesServerController {
    public typealias ExitHandler = @Sendable (Int32) -> Void

    private let baseURL: URL
    private let apiKey: String
    private let executableOverride: String?
    private let session: URLSession
    private let onUnexpectedExit: ExitHandler?
    private var process: Process?
    private var restartLimiter = RestartRateLimiter(maximumStarts: 3, window: 60)
    private var intentionalStops: Set<ObjectIdentifier> = []
    private var totalStartCount = 0
    private var unexpectedExitCount = 0
    private var lastExitStatus: Int32?

    public init(
        baseURL: URL,
        apiKey: String,
        executableOverride: String? = ProcessInfo.processInfo.environment["JARVIS_HERMES_EXECUTABLE"],
        session: URLSession = .shared,
        onUnexpectedExit: ExitHandler? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.executableOverride = executableOverride
        self.session = session
        self.onUnexpectedExit = onUnexpectedExit
    }

    public func ensureAvailable() async throws {
        if await isHealthy() { return }
        if let process, !process.isRunning {
            self.process = nil
        }
        guard process == nil else {
            try await waitUntilHealthy()
            return
        }
        guard baseURL.scheme == "http",
              let host = baseURL.host,
              host == "127.0.0.1" || host == "localhost" || host == "::1" else {
            throw HermesServerError.autoStartRequiresLoopbackHTTP
        }
        guard let port = baseURL.port else {
            throw HermesServerError.missingPort
        }
        guard let executableURL = locateExecutable() else {
            throw HermesServerError.executableNotFound
        }
        guard restartLimiter.recordStartIfAllowed() else {
            throw HermesServerError.restartRateLimited
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["gateway", "run"]
        var environment = ProcessInfo.processInfo.environment
        environment["API_SERVER_ENABLED"] = "1"
        environment["API_SERVER_HOST"] = host
        environment["API_SERVER_PORT"] = String(port)
        environment["API_SERVER_KEY"] = apiKey
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { await self?.processDidExit(process) }
        }

        do {
            try process.run()
        } catch {
            throw HermesServerError.launchFailed(String(describing: error))
        }
        self.process = process
        totalStartCount += 1

        do {
            try await waitUntilHealthy()
        } catch {
            stopOwnedProcess()
            throw error
        }
    }

    public func shutdown() {
        stopOwnedProcess()
    }

    public func processStatus() -> HermesProcessStatus {
        HermesProcessStatus(
            ownedProcessRunning: process?.isRunning == true,
            totalStartCount: totalStartCount,
            unexpectedExitCount: unexpectedExitCount,
            lastExitStatus: lastExitStatus
        )
    }

    private func processDidExit(_ exitedProcess: Process) {
        let identifier = ObjectIdentifier(exitedProcess)
        let wasIntentional = intentionalStops.remove(identifier) != nil
        if process === exitedProcess {
            process = nil
        }
        lastExitStatus = exitedProcess.terminationStatus
        guard !wasIntentional else { return }
        unexpectedExitCount += 1
        onUnexpectedExit?(exitedProcess.terminationStatus)
    }

    private func waitUntilHealthy() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            if await isHealthy() { return }
            if let process, !process.isRunning {
                self.process = nil
                throw HermesServerError.exitedBeforeReady(process.terminationStatus)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HermesServerError.readinessTimedOut
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 1
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func locateExecutable() -> URL? {
        let candidates = [
            executableOverride,
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/hermes").path,
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ].compactMap { $0 }

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private func stopOwnedProcess() {
        guard let process else { return }
        if process.isRunning {
            intentionalStops.insert(ObjectIdentifier(process))
            process.terminate()
        }
        self.process = nil
    }
}

public struct HermesProcessStatus: Sendable, Equatable {
    public let ownedProcessRunning: Bool
    public let totalStartCount: Int
    public let unexpectedExitCount: Int
    public let lastExitStatus: Int32?
}

public struct RestartRateLimiter: Sendable, Equatable {
    public let maximumStarts: Int
    public let window: TimeInterval
    private var starts: [Date] = []

    public init(maximumStarts: Int, window: TimeInterval) {
        self.maximumStarts = max(1, maximumStarts)
        self.window = max(1, window)
    }

    public mutating func recordStartIfAllowed(now: Date = Date()) -> Bool {
        starts.removeAll { now.timeIntervalSince($0) >= window }
        guard starts.count < maximumStarts else { return false }
        starts.append(now)
        return true
    }
}

public enum HermesServerError: Error, Equatable, CustomStringConvertible {
    case autoStartRequiresLoopbackHTTP
    case executableNotFound
    case exitedBeforeReady(Int32)
    case launchFailed(String)
    case missingPort
    case readinessTimedOut
    case restartRateLimited

    public var description: String {
        switch self {
        case .autoStartRequiresLoopbackHTTP:
            return "Hermes auto-start requires a loopback HTTP endpoint."
        case .executableNotFound:
            return "Hermes is not installed in a supported location."
        case .exitedBeforeReady(let status):
            return "Hermes exited before its API became ready (status \(status))."
        case .launchFailed(let message):
            return "Unable to launch Hermes: \(message)"
        case .missingPort:
            return "The Hermes endpoint must include an explicit port."
        case .readinessTimedOut:
            return "Hermes did not become ready within 20 seconds."
        case .restartRateLimited:
            return "Hermes restarted too frequently. Automatic restart is temporarily paused."
        }
    }
}
