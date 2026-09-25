import Foundation
import Darwin

private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count < 8192 {
            buffer.append(chunk)
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}

public actor HermesServerController {
    private var currentStderrCollector: StderrCollector?
    public typealias ExitHandler = @Sendable (Int32) -> Void

    private let baseURL: URL
    private let apiKey: String
    private let executableOverride: String?
    private let session: URLSession
    private let onUnexpectedExit: ExitHandler?
    private var process: Process?
    private var restartLimiter = RestartRateLimiter(maximumStarts: 3, window: 60)
    private let readinessTimeout: Duration
    private var intentionalStops: Set<ObjectIdentifier> = []
    private var totalStartCount = 0
    private var unexpectedExitCount = 0
    private var lastExitStatus: Int32?

    public init(
        baseURL: URL,
        apiKey: String,
        executableOverride: String? = ProcessInfo.processInfo.environment["JARVIS_HERMES_EXECUTABLE"],
        session: URLSession = .shared,
        readinessTimeout: Duration = .seconds(60),
        onUnexpectedExit: ExitHandler? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.executableOverride = executableOverride
        self.session = session
        self.readinessTimeout = readinessTimeout
        self.onUnexpectedExit = onUnexpectedExit
    }

    public func ensureAvailable() async throws {
        if let process, !process.isRunning {
            self.process = nil
        }
        if let process {
            if await isAuthenticatedReady() { return }
            try await waitUntilReady(for: process)
            return
        }

        guard HermesRuntimeConfiguration.isManagedEndpoint(baseURL) else {
            guard await isAuthenticatedReady() else {
                throw HermesServerError.customEndpointUnavailable
            }
            return
        }
        guard !(await endpointResponds()) else {
            throw HermesServerError.managedEndpointOccupied
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
        process.arguments = Self.launchArguments()
        process.environment = Self.managedLaunchEnvironment(
            from: ProcessInfo.processInfo.environment,
            host: host,
            port: port,
            apiKey: apiKey
        )
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let collector = StderrCollector()
        currentStderrCollector = collector
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            collector.append(chunk)
        }
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
            try await waitUntilReady(for: process, collector: collector)
            restartLimiter.reset()
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
        if let pipe = exitedProcess.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        let identifier = ObjectIdentifier(exitedProcess)
        let wasIntentional = intentionalStops.remove(identifier) != nil
        if process === exitedProcess {
            process = nil
            currentStderrCollector = nil
        }
        lastExitStatus = exitedProcess.terminationStatus
        guard !wasIntentional else { return }
        unexpectedExitCount += 1
        onUnexpectedExit?(exitedProcess.terminationStatus)
    }

    private func waitUntilReady(for launchedProcess: Process, collector: StderrCollector? = nil) async throws {
        let activeCollector = collector ?? currentStderrCollector
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: readinessTimeout)
        while clock.now < deadline {
            if await isAuthenticatedReady() { return }
            if !launchedProcess.isRunning {
                if self.process === launchedProcess { self.process = nil }
                if let pipe = launchedProcess.standardOutput as? Pipe {
                    let handle = pipe.fileHandleForReading
                    handle.readabilityHandler = nil
                    let descriptor = handle.fileDescriptor
                    let flags = fcntl(descriptor, F_GETFL)
                    if flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 {
                        var bytes = [UInt8](repeating: 0, count: 1024)
                        while true {
                            let count = Darwin.read(descriptor, &bytes, bytes.count)
                            guard count > 0 else { break }
                            activeCollector?.append(Data(bytes.prefix(count)))
                        }
                        _ = fcntl(descriptor, F_SETFL, flags)
                    }
                }
                let stderrString = activeCollector?.string() ?? ""
                let trimmed = stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                let safeMessage = apiKey.isEmpty
                    ? trimmed
                    : trimmed.replacingOccurrences(of: apiKey, with: "<REDACTED>")
                if !safeMessage.isEmpty {
                    throw HermesServerError.exitedBeforeReadyWithMessage(launchedProcess.terminationStatus, message: safeMessage)
                } else {
                    throw HermesServerError.exitedBeforeReady(launchedProcess.terminationStatus)
                }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw HermesServerError.readinessTimedOut
    }

    private func endpointResponds() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 1
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func isAuthenticatedReady() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "v1/capabilities"))
        request.timeoutInterval = 1
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return Self.isCompatibleCapabilitiesResponse(data)
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

    static func launchArguments() -> [String] {
        ["-p", HermesRuntimeConfiguration.profileName, "gateway", "run", "--force", "--external-supervisor"]
    }

    static func managedLaunchEnvironment(
        from inherited: [String: String],
        host: String,
        port: Int,
        apiKey: String
    ) -> [String: String] {
        var environment = launchEnvironment(from: inherited)
        environment["API_SERVER_ENABLED"] = "1"
        environment["API_SERVER_HOST"] = host
        environment["API_SERVER_PORT"] = String(port)
        environment["API_SERVER_KEY"] = apiKey
        environment["GATEWAY_MULTIPLEX_PROFILES"] = "0"
        return environment
    }

    static func isCompatibleCapabilitiesResponse(_ data: Data) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["object"] as? String == "hermes.api_server.capabilities",
              let endpoints = payload["endpoints"] as? [String: Any],
              let features = payload["features"] as? [String: Any] else {
            return false
        }
        let requiredEndpoints = ["runs", "run_events", "run_status", "run_stop", "run_approval"]
        let requiredFeatures = [
            "run_submission",
            "run_events_sse",
            "run_status",
            "run_stop",
            "run_approval_response",
        ]
        return requiredEndpoints.allSatisfy { endpoints[$0] != nil }
            && requiredFeatures.allSatisfy { features[$0] as? Bool == true }
    }

    static func launchEnvironment(from inherited: [String: String]) -> [String: String] {
        var environment = inherited
        let preferredPaths = [
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
        ]
        let inheritedPaths = inherited["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        environment["PATH"] = (preferredPaths + inheritedPaths)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    private func stopOwnedProcess() {
        guard let process else { return }
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        currentStderrCollector = nil
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

    public mutating func reset() {
        starts.removeAll()
    }
}

public enum HermesServerError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case autoStartRequiresLoopbackHTTP
    case customEndpointUnavailable
    case executableNotFound
    case exitedBeforeReady(Int32)
    case exitedBeforeReadyWithMessage(Int32, message: String)
    case launchFailed(String)
    case managedEndpointOccupied
    case missingPort
    case readinessTimedOut
    case restartRateLimited

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .autoStartRequiresLoopbackHTTP:
            return "Hermes auto-start requires a loopback HTTP endpoint."
        case .customEndpointUnavailable:
            return "The operator-managed Hermes endpoint did not provide a compatible authenticated API."
        case .executableNotFound:
            return "Hermes is not installed in a supported location."
        case .exitedBeforeReady(let status):
            return "Hermes exited before its API became ready (status \(status))."
        case .exitedBeforeReadyWithMessage(let status, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Hermes exited before its API became ready (status \(status))."
            }
            return "Hermes exited before its API became ready (status \(status)): \(trimmed)"
        case .launchFailed(let message):
            return "Unable to launch Hermes: \(message)"
        case .managedEndpointOccupied:
            return "The managed J.A.R.V.I.S. Hermes endpoint is already occupied by an unverified process."
        case .missingPort:
            return "The Hermes endpoint must include an explicit port."
        case .readinessTimedOut:
            return "Hermes did not become ready before the startup deadline."
        case .restartRateLimited:
            return "Hermes restarted too frequently. Automatic restart is temporarily paused."
        }
    }
}
