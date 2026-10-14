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
    private let redirectPolicy = HermesRedirectPolicy()
    private let onUnexpectedExit: ExitHandler?
    private let managedProcessInspector: HermesManagedProcessInspector
    private var process: Process?
    private var attachedProcess: HermesManagedProcessIdentity?
    private var attachedProcessMonitor: Task<Void, Never>?
    private var availabilityTask: (id: UUID, task: Task<Void, Error>)?
    private var shutdownTask: Task<Void, Never>?
    private var restartLimiter = RestartRateLimiter(maximumStarts: 3, window: 60)
    private let readinessTimeout: Duration
    private let shutdownTimeout: Duration
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
        self.init(
            baseURL: baseURL, apiKey: apiKey, executableOverride: executableOverride,
            session: session, readinessTimeout: readinessTimeout, onUnexpectedExit: onUnexpectedExit,
            managedProcessInspector: HermesManagedProcessInspector()
        )
    }

    init(
        baseURL: URL,
        apiKey: String,
        executableOverride: String? = nil,
        session: URLSession = .shared,
        readinessTimeout: Duration = .seconds(60),
        shutdownTimeout: Duration = .seconds(5),
        onUnexpectedExit: ExitHandler? = nil,
        managedProcessInspector: HermesManagedProcessInspector
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.executableOverride = executableOverride
        self.session = session
        self.readinessTimeout = readinessTimeout
        self.onUnexpectedExit = onUnexpectedExit
        self.managedProcessInspector = managedProcessInspector
        self.shutdownTimeout = shutdownTimeout
    }

    public func ensureAvailable() async throws {
        if let shutdownTask { await shutdownTask.value }
        try Task.checkCancellation()
        if let availabilityTask {
            try await availabilityTask.task.value
            return try Task.checkCancellation()
        }
        let id = UUID()
        let task = Task { try await self.ensureAvailableOnce() }
        availabilityTask = (id, task)
        defer {
            if availabilityTask?.id == id { availabilityTask = nil }
        }
        try await task.value
        try Task.checkCancellation()
    }

    private func ensureAvailableOnce() async throws {
        try Task.checkCancellation()
        try HermesRuntimeConfiguration.validateEndpoint(baseURL)
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
        if let existing = managedProcessInspector.verifiedListener(at: baseURL) {
            if await isAuthenticatedReady(),
               managedProcessInspector.isSameListener(existing, at: baseURL) {
                try Task.checkCancellation()
                attach(to: existing)
                return
            }
            // A previous app may have exited with an older Keychain key. Reclaim only
            // its verified orphan, after rechecking identity immediately before signaling.
            guard managedProcessInspector.isSameListener(existing, at: baseURL),
                  managedProcessInspector.signalOrphan(existing, signal: SIGTERM) else {
                throw HermesServerError.managedEndpointOccupied
            }
            try await waitForOrphanExit(existing)
        } else if await endpointResponds() {
            throw HermesServerError.managedEndpointOccupied
        }
        try Task.checkCancellation()
        guard baseURL.scheme == "http",
              let endpointHost = baseURL.host else {
            throw HermesServerError.autoStartRequiresLoopbackHTTP
        }
        let host = endpointHost == "[::1]" ? "::1" : endpointHost.lowercased()
        guard let port = baseURL.port else {
            throw HermesServerError.missingPort
        }
        guard let executableURL = locateExecutable() else {
            throw HermesServerError.executableNotFound
        }
        guard restartLimiter.recordStartIfAllowed() else {
            throw HermesServerError.restartRateLimited
        }
        detachAttachedProcess()

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
            // Readiness can precede a crash. Keep every start in the rolling window.
        } catch {
            await stopOwnedProcess()
            throw error
        }
    }

    public func shutdown() async {
        if let shutdownTask { return await shutdownTask.value }
        let task = Task { await self.finishShutdown() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func finishShutdown() async {
        availabilityTask?.task.cancel()
        _ = try? await availabilityTask?.task.value
        availabilityTask = nil
        detachAttachedProcess()
        await stopOwnedProcess()
    }

    private func detachAttachedProcess() {
        attachedProcessMonitor?.cancel()
        attachedProcessMonitor = nil
        attachedProcess = nil
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
            try Task.checkCancellation()
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
            let (_, response) = try await session.data(for: request, delegate: redirectPolicy)
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
            let (data, response) = try await session.data(for: request, delegate: redirectPolicy)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            return Self.isCompatibleCapabilitiesResponse(data)
        } catch {
            return false
        }
    }

    private func locateExecutable() -> URL? {
        HermesRuntimeConfiguration.locateExecutable(override: executableOverride)
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

    private func attach(to identity: HermesManagedProcessIdentity) {
        guard attachedProcess != identity else { return }
        attachedProcessMonitor?.cancel()
        attachedProcess = identity
        attachedProcessMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, await self.checkAttachedProcess(identity) else { return }
            }
        }
    }

    private func checkAttachedProcess(_ identity: HermesManagedProcessIdentity) -> Bool {
        guard attachedProcess == identity else { return false }
        guard managedProcessInspector.isSameProcess(identity) else {
            attachedProcess = nil
            attachedProcessMonitor = nil
            unexpectedExitCount += 1
            onUnexpectedExit?(-1)
            return false
        }
        return true
    }

    private func waitForOrphanExit(_ identity: HermesManagedProcessIdentity) async throws {
        let deadline = ContinuousClock.now.advanced(by: shutdownTimeout)
        while managedProcessInspector.isSameProcess(identity), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        if managedProcessInspector.isSameProcess(identity) {
            guard managedProcessInspector.signalOrphan(identity, signal: SIGKILL) else {
                throw HermesServerError.managedEndpointOccupied
            }
            let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while managedProcessInspector.isSameProcess(identity), ContinuousClock.now < killDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        guard !managedProcessInspector.isSameProcess(identity) else {
            throw HermesServerError.managedEndpointOccupied
        }
        detachAttachedProcess()
    }

    private func stopOwnedProcess() async {
        guard let process else { return }
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        currentStderrCollector = nil
        if process.isRunning {
            intentionalStops.insert(ObjectIdentifier(process))
            let identity = HermesManagedProcessInspector.readProcessIdentity(process.processIdentifier)
            process.terminate()
            let deadline = ContinuousClock.now.advanced(by: shutdownTimeout)
            while process.isRunning, ContinuousClock.now < deadline {
                // Cleanup must finish even when the startup task was cancelled.
                await Self.cleanupPause()
            }
            if process.isRunning, let identity,
               HermesManagedProcessInspector.readProcessIdentity(identity.pid) == identity {
                _ = Darwin.kill(identity.pid, SIGKILL)
            }
            let killDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while process.isRunning, ContinuousClock.now < killDeadline {
                await Self.cleanupPause()
            }
        }
        if self.process === process { self.process = nil }
    }

    private static func cleanupPause() async {
        if Task.isCancelled {
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        } else {
            try? await Task.sleep(for: .milliseconds(50))
        }
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
