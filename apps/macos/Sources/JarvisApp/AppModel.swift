import AppKit
import AVFoundation
import Foundation
import JarvisCore

@MainActor
private final class SnapshotRelay {
    weak var owner: AppModel?

    func deliver(_ snapshot: VoiceSnapshot) {
        owner?.receive(snapshot)
    }

    func hermesExited() {
        owner?.handleHermesUnexpectedExit()
    }

    func conversationSessionReset() {
        owner?.handleConversationSessionReset()
    }
}

private enum AppModelError: LocalizedError {
    case settingsApplicationInProgress

    var errorDescription: String? {
        switch self {
        case .settingsApplicationInProgress:
            return "Another settings update is already in progress."
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = VoiceSnapshot()
    @Published private(set) var history: [ConversationTurn] = []
    @Published private(set) var hotkeyLabel = HotkeyConfiguration.commandShiftSpace.displayName
    @Published private(set) var runtimeHealth = RuntimeHealth()
    @Published private(set) var diagnosticEvents: [DiagnosticEvent] = []
    @Published private(set) var orbVisibility: OrbVisibility
    @Published private(set) var isVoiceInteraction = false
    @Published private(set) var speakTypedResponses: Bool
    @Published private(set) var automaticallySubmitOrbAfterSilence: Bool
    @Published private(set) var orbSilenceDuration: Double
    @Published private(set) var animationQuality: AnimationQuality
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published var isFloatingOrbVisible = false
    @Published private(set) var needsSetup: Bool
    @Published var isSetupPresented: Bool
    private enum VoiceCaptureOrigin {
        case hotkey
        case orb
    }

    private struct Runtime {
        let hermesServer: HermesServerController
        let pipeline: VoicePipeline
        let localRecognizer: ParakeetRecognizer
    }

    private let capture: AudioCaptureService
    private let hotkey: GlobalHotkey
    private let snapshotRelay: SnapshotRelay
    private var hermesServer: HermesServerController
    private var pipeline: VoicePipeline
    private var localRecognizer: ParakeetRecognizer
    private var currentConfig: AppConfig
    private var started = false
    private var hotkeyDown = false
    private var isApplyingSettings = false
    private var persistsHistory: Bool
    private var lastArchivedGeneration: Int?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var audioObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var connectivityMonitor: ConnectivityMonitor?
    private let recoveryPolicy = RecoveryPolicy()
    private var diagnosticBuffer = DiagnosticEventBuffer()
    private var isSleeping = false
    private var networkWasUnavailable = false
    private var activeCaptureOrigin: VoiceCaptureOrigin?
    private var orbSpeechDetected = false
    private var silenceSubmissionTask: Task<Void, Never>?
    private var historyExpiryTask: Task<Void, Never>?
    private var lastSpeechUptime: TimeInterval = 0

    init(config: AppConfig = AppConfig()) {
        let capture = AudioCaptureService()
        let hotkey = GlobalHotkey()
        let snapshotRelay = SnapshotRelay()
        let preferences = AppPreferencesStore.load()
        let persistsHistory = preferences.persistTranscriptHistory
        let conversationContextUpdatedAt = ConversationContextStore.lastUpdatedAt()
        let contextExpired = conversationContextUpdatedAt.map {
            Date.now.timeIntervalSince($0) > ConversationContextStore.expiration
        } ?? false
        let conversationContext = ConversationContextStore.load()
        let runtime = Self.makeRuntime(
            config: config,
            snapshotRelay: snapshotRelay,
            conversationContext: conversationContext,
            conversationContextUpdatedAt: contextExpired ? nil : conversationContextUpdatedAt
        )

        self.capture = capture
        self.hotkey = hotkey
        self.snapshotRelay = snapshotRelay
        self.hermesServer = runtime.hermesServer
        self.pipeline = runtime.pipeline
        self.localRecognizer = runtime.localRecognizer
        self.currentConfig = config
        self.needsSetup = !FirstRunSetupStore.isComplete()
        self.isSetupPresented = !FirstRunSetupStore.isComplete()
        self.persistsHistory = persistsHistory
        self.orbVisibility = preferences.orbVisibility
        self.speakTypedResponses = preferences.speakTypedResponses
        self.automaticallySubmitOrbAfterSilence = preferences.automaticallySubmitOrbAfterSilence
        self.orbSilenceDuration = preferences.orbSilenceDuration
        self.animationQuality = preferences.animationQuality
        if contextExpired {
            ConversationHistoryStore.clear()
            self.history = []
        } else {
            self.history = persistsHistory ? ConversationHistoryStore.load() : []
        }
        self.hotkeyLabel = config.hotkey.displayName
        if needsSetup {
            self.snapshot.statusText = "Complete setup to start J.A.R.V.I.S."
        }
        snapshotRelay.owner = self
        observeLifecycle()
        observeConnectivity()
        if !contextExpired,
           let conversationContextUpdatedAt,
           !conversationContext.isEmpty || !history.isEmpty {
            let remaining = ConversationContextStore.expiration
                - Date.now.timeIntervalSince(conversationContextUpdatedAt)
            scheduleHistoryExpiry(after: remaining)
        }

        Task { @MainActor in
            await self.start()
        }
    }

    func start() async {
        guard !started, !needsSetup else { return }
        started = true
        recordDiagnostic(.appStarted)
        refreshMicrophoneAuthorization(recoverAfterChange: false)

        do {
            snapshot.state = .starting
            snapshot.statusText = "Starting Hermes"
            try currentConfig.validate()
            try await hermesServer.ensureAvailable()
            runtimeHealth.hermes = .healthy
            try await pipeline.prepareOrThrow()
            try registerHotkey(currentConfig.hotkey)
            runtimeHealth.audio = .healthy
        } catch {
            if runtimeHealth.hermes != .healthy {
                runtimeHealth.hermes = .unavailable
            }
            snapshot.state = .error
            snapshot.statusText = AppErrorFormatter.displayMessage(for: error)
            started = false
            hotkey.unregister()
            await hermesServer.shutdown()
            needsSetup = true
            isSetupPresented = true
        }
    }

    func requestMicrophoneAccess() async -> Bool {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        refreshMicrophoneAuthorization()
        return allowed
    }

    func completeSetup(preferences: AppPreferences, deepgramAPIKey: String) async throws {
        guard !isApplyingSettings else { throw AppModelError.settingsApplicationInProgress }
        var normalized = preferences
        normalized.hermesBaseURL = preferences.hermesBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.parakeetModelPath = (preferences.parakeetModelPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard let endpoint = URL(string: normalized.hermesBaseURL) else { throw AppConfigError.hermesMustUseLoopback }
        try HermesRuntimeConfiguration.validateEndpoint(endpoint)
        var config = normalized.makeConfig()
        let trimmedKey = deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        config.deepgramAPIKey = trimmedKey.isEmpty ? nil : trimmedKey
        try config.validate()
        let previousKey = InstallationIdentity.deepgramAPIKey()
        let credentialChanged = previousKey != config.deepgramAPIKey
        if credentialChanged && !AppPreferencesStore.saveDeepgramAPIKey(config.deepgramAPIKey) {
            throw NSError(domain: "JarvisSetup", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not save the Deepgram API key in Keychain.",
            ])
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        needsSetup = true
        do {
            try await apply(preferences: normalized)
            guard AppPreferencesStore.save(normalized) else {
                throw NSError(domain: "JarvisSetup", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Setup could not be saved. Try again.",
                ])
            }
        } catch {
            if credentialChanged { _ = AppPreferencesStore.saveDeepgramAPIKey(previousKey) }
            throw error
        }
        FirstRunSetupStore.markComplete()
        needsSetup = false
        isSetupPresented = false
        refreshMicrophoneAuthorization(recoverAfterChange: false)
        snapshot.statusText = runtimeHealth.microphone == .healthy ? "Ready" : "Ready for typing; microphone unavailable"
    }

    func apply(preferences: AppPreferences) async throws {
        try await apply(config: preferences.makeConfig())
        orbVisibility = preferences.orbVisibility
        speakTypedResponses = preferences.speakTypedResponses
        automaticallySubmitOrbAfterSilence = preferences.automaticallySubmitOrbAfterSilence
        orbSilenceDuration = preferences.orbSilenceDuration
        animationQuality = preferences.animationQuality
        persistsHistory = preferences.persistTranscriptHistory
        if persistsHistory {
            _ = ConversationHistoryStore.save(history)
        } else {
            ConversationHistoryStore.clear()
        }
    }

    func apply(config: AppConfig) async throws {
        try config.validate()
        guard !isApplyingSettings else { throw AppModelError.settingsApplicationInProgress }
        isApplyingSettings = true
        defer { isApplyingSettings = false }

        if started, !needsSetup, !config.requiresRuntimeRebuild(comparedTo: currentConfig) {
            if config.hotkey != currentConfig.hotkey {
                if hotkeyDown { stopCurrentTurn() }
                try registerHotkey(config.hotkey)
            }
            await pipeline.setModelSelection(config.agentModel)
            currentConfig = config
            hotkeyLabel = config.hotkey.displayName
            recordDiagnostic(.settingsApplied)
            return
        }

        capture.cancel()
        hotkeyDown = false

        let previousPipeline = pipeline
        let previousServer = hermesServer
        let reusesHermesServer = usesSameHermesServer(currentConfig, config)
        let conversationContext = ConversationContextStore.load()
        let candidate = Self.makeRuntime(
            config: config,
            snapshotRelay: snapshotRelay,
            conversationContext: conversationContext,
            conversationContextUpdatedAt: ConversationContextStore.lastUpdatedAt(),
            hermesServer: reusesHermesServer ? previousServer : nil,
            localRecognizer: config.parakeetModelPath == currentConfig.parakeetModelPath
                && config.parakeetComputeUnits == currentConfig.parakeetComputeUnits
                && config.captureProfile == currentConfig.captureProfile ? localRecognizer : nil
        )

        await previousPipeline.shutdown()

        do {
            try await candidate.hermesServer.ensureAvailable()
            try await candidate.pipeline.prepareOrThrow()
            try registerHotkey(config.hotkey)

            pipeline = candidate.pipeline
            localRecognizer = candidate.localRecognizer
            hermesServer = candidate.hermesServer
            currentConfig = config
            hotkeyLabel = config.hotkey.displayName
            lastArchivedGeneration = nil
            started = true
            runtimeHealth.hermes = .healthy
            runtimeHealth.audio = .healthy

            if !reusesHermesServer {
                await previousServer.shutdown()
            }
            recordDiagnostic(.settingsApplied)
            snapshot.state = .idle
            snapshot.statusText = "Settings applied"
        } catch {
            if started { try? registerHotkey(currentConfig.hotkey) }
            else { hotkey.unregister() }
            await candidate.pipeline.shutdown()
            if !started || !reusesHermesServer {
                await candidate.hermesServer.shutdown()
            }
            snapshot.state = .error
            snapshot.statusText = "Could not apply settings: \(AppErrorFormatter.displayMessage(for: error))"
            throw error
        }
    }

    func handleHermesUnexpectedExit() {
        recordDiagnostic(.hermesExited)
        runtimeHealth.hermes = .unavailable
        snapshot.state = .degraded
        snapshot.statusText = "Hermes exited; recovering"
        recoverRuntime(reason: "Hermes exit", debounce: false)
    }

    func receive(_ nextSnapshot: VoiceSnapshot) {
        let previousState = snapshot.state
        snapshot = nextSnapshot
        if isConversationActive(nextSnapshot.state) {
            cancelHistoryExpiry()
        }
        if nextSnapshot.state == .idle || nextSnapshot.state == .error || nextSnapshot.state == .degraded {
            isVoiceInteraction = false
        }
        if nextSnapshot.state == .error, previousState != .error {
            recordDiagnostic(.turnFailed)
        }
        guard nextSnapshot.state == .idle,
              !nextSnapshot.userText.isEmpty,
              !nextSnapshot.assistantText.isEmpty,
              lastArchivedGeneration != nextSnapshot.generation else {
            if isConversationTerminal(nextSnapshot.state),
               isConversationActive(previousState),
               !history.isEmpty {
                scheduleHistoryExpiry(after: ConversationContextStore.expiration)
            }
            return
        }
        history.append(ConversationTurn(
            userText: nextSnapshot.userText,
            assistantText: nextSnapshot.assistantText,
            provider: nextSnapshot.speechProvider,
            sources: nextSnapshot.sources
        ))
        if history.count > ConversationHistoryStore.retentionLimit {
            history.removeFirst(history.count - ConversationHistoryStore.retentionLimit)
        }
        if persistsHistory {
            _ = ConversationHistoryStore.save(history)
        }
        lastArchivedGeneration = nextSnapshot.generation
        scheduleHistoryExpiry(after: ConversationContextStore.expiration)
    }

    func handleConversationSessionReset() {
        clearTranscriptHistory(resetPipeline: false)
    }

    var canSubmitText: Bool {
        started
            && !needsSetup
            && !isApplyingSettings
            && !isSleeping
            && snapshot.state != .starting
            && snapshot.state != .approval
    }

    var canStopCurrentTurn: Bool { isConversationActive(snapshot.state) }

    func stopCurrentTurn() {
        capture.cancel()
        hotkeyDown = false
        activeCaptureOrigin = nil
        silenceSubmissionTask?.cancel()
        silenceSubmissionTask = nil
        GlassVoiceOrbAudioHub.shared.publish(.zero)
        // A stopped response remains visible but is not a completed history turn.
        lastArchivedGeneration = snapshot.generation
        let pipeline = pipeline
        Task { await pipeline.cancelCurrentTurn() }
    }

    @discardableResult
    func submitText(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmitText, !text.isEmpty else { return false }

        capture.cancel()
        hotkeyDown = false
        isVoiceInteraction = false
        let pipeline = pipeline
        let speakResponse = speakTypedResponses
        Task { await pipeline.submit(text: text, speakResponse: speakResponse) }
        return true
    }

    func newConversation() {
        cancelHistoryExpiry()
        lastArchivedGeneration = nil
        let pipeline = pipeline
        Task { await pipeline.newConversation() }
    }

    func clearHistory() {
        clearTranscriptHistory(resetPipeline: true)
    }

    private func clearTranscriptHistory(resetPipeline: Bool) {
        cancelHistoryExpiry()
        history.removeAll()
        ConversationHistoryStore.clear()
        lastArchivedGeneration = nil
        guard resetPipeline else { return }
        ConversationContextStore.clear()
        let pipeline = pipeline
        Task { await pipeline.newConversation() }
    }

    private func isConversationActive(_ state: VoiceState) -> Bool {
        switch state {
        case .listening, .transcribing, .thinking, .tool, .approval, .speaking, .interrupting:
            true
        case .starting, .idle, .degraded, .error:
            false
        }
    }

    private func isConversationTerminal(_ state: VoiceState) -> Bool {
        switch state {
        case .idle, .degraded, .error:
            true
        case .starting, .listening, .transcribing, .thinking, .tool, .approval, .speaking, .interrupting:
            false
        }
    }

    private func cancelHistoryExpiry() {
        historyExpiryTask?.cancel()
        historyExpiryTask = nil
    }

    private func scheduleHistoryExpiry(after delay: TimeInterval) {
        cancelHistoryExpiry()
        if delay <= 0 {
            expireIdleTranscriptHistory()
            return
        }
        historyExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.expireIdleTranscriptHistory()
        }
    }

    private func expireIdleTranscriptHistory() {
        clearTranscriptHistory(resetPipeline: true)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    var microphoneNeedsPermissionRequest: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    var isPreparingSetup: Bool { needsSetup && isApplyingSettings }

    func clearDiagnostics() {
        diagnosticBuffer.clear()
        diagnosticEvents = []
    }

    func approve(_ choice: HermesApprovalChoice) {
        let pipeline = pipeline
        Task { await pipeline.respondToApproval(choice) }
    }

    func stop() {
        recoveryTask?.cancel()
        cancelHistoryExpiry()
        connectivityMonitor?.cancel()
        capture.cancel()
        hotkey.unregister()
        let pipeline = pipeline
        let hermesServer = hermesServer
        Task {
            await pipeline.shutdown()
            await hermesServer.shutdown()
        }
    }

    func quit() {
        recoveryTask?.cancel()
        cancelHistoryExpiry()
        connectivityMonitor?.cancel()
        capture.cancel()
        hotkey.unregister()
        let pipeline = pipeline
        let hermesServer = hermesServer
        Task {
            await pipeline.shutdown()
            await hermesServer.shutdown()
            NSApplication.shared.terminate(nil)
        }
    }

    private func recordDiagnostic(_ kind: DiagnosticEventKind, attempt: Int? = nil) {
        diagnosticBuffer.append(DiagnosticEvent(kind: kind, attempt: attempt))
        diagnosticEvents = diagnosticBuffer.events
    }

    private func observeConnectivity() {
        let monitor = ConnectivityMonitor { [weak self] isAvailable in
            Task { @MainActor in
                guard let self else { return }
                if isAvailable {
                    if self.runtimeHealth.network != .healthy {
                        self.recordDiagnostic(.networkAvailable)
                    }
                    self.runtimeHealth.network = .healthy
                    if self.networkWasUnavailable {
                        self.networkWasUnavailable = false
                        self.recoverRuntime(reason: "network restoration", debounce: true)
                    }
                } else {
                    if !self.networkWasUnavailable {
                        self.recordDiagnostic(.networkUnavailable)
                    }
                    self.networkWasUnavailable = true
                    self.runtimeHealth.network = .unavailable
                    if self.started, !self.needsSetup, self.snapshot.state != .listening {
                        self.snapshot.state = .degraded
                        self.snapshot.statusText = "Network unavailable"
                    }
                }
            }
        }
        connectivityMonitor = monitor
        monitor.start()
    }

    private func observeLifecycle() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendForSleep() }
        })
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        })
        audioObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleAudioDeviceChange() }
        }
        applicationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshMicrophoneAuthorization() }
        }
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    private func refreshMicrophoneAuthorization(recoverAfterChange: Bool = true) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let isAuthorized = status == .authorized
        if isAuthorized {
            if runtimeHealth.microphone != .healthy {
                recordDiagnostic(.microphoneAvailable)
                runtimeHealth.microphone = .healthy
                if recoverAfterChange { recoverRuntime(reason: "microphone permission restoration", debounce: false) }
            }
        } else {
            if runtimeHealth.microphone != .unavailable {
                recordDiagnostic(.microphoneUnavailable)
            }
            runtimeHealth.microphone = .unavailable
            let wasListening = hotkeyDown || snapshot.state == .listening
            capture.cancel()
            hotkeyDown = false
            if wasListening {
                let pipeline = pipeline
                Task { await pipeline.shutdown() }
            } else if snapshot.state == .idle {
                snapshot.statusText = "Ready — microphone unavailable"
            }
        }
    }

    private func handleAudioDeviceChange() {
        recordDiagnostic(.audioDeviceChanged)
        recoverRuntime(reason: "audio device change", debounce: true)
    }

    private func suspendForSleep() {
        guard started else { return }
        recordDiagnostic(.sleepStarted)
        isSleeping = true
        recoveryTask?.cancel()
        recoveryTask = nil
        capture.cancel()
        hotkeyDown = false
        let pipeline = pipeline
        Task {
            await pipeline.shutdown()
            guard isSleeping else { return }
            snapshot.state = .starting
            snapshot.statusText = "Sleeping"
        }
    }

    private func resumeAfterWake() {
        guard started else { return }
        recordDiagnostic(.wakeStarted)
        isSleeping = false
        recoverRuntime(reason: "wake", debounce: false)
    }

    private func recoverRuntime(reason: String, debounce: Bool) {
        guard started, !needsSetup, !isSleeping, !isApplyingSettings else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounce {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }

            capture.cancel()
            hotkeyDown = false
            snapshot.state = .degraded
            snapshot.statusText = "Recovering after \(reason)"
            runtimeHealth.hermes = .recovering
            runtimeHealth.audio = .recovering
            let pipeline = pipeline
            let hermesServer = hermesServer
            await pipeline.shutdown()
            guard !Task.isCancelled else { return }

            var lastError: Error?
            for attempt in 1...recoveryPolicy.maximumAttempts {
                recordDiagnostic(.recoveryStarted, attempt: attempt)
                guard !Task.isCancelled, !isSleeping else { return }
                runtimeHealth.recoveryAttempt = attempt
                if let delay = recoveryPolicy.delay(forAttempt: attempt), delay > .zero {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled else { return }
                }

                do {
                    try await hermesServer.ensureAvailable()
                    runtimeHealth.hermes = .healthy
                    try await pipeline.prepareOrThrow()
                    runtimeHealth.audio = .healthy
                    try registerHotkey(currentConfig.hotkey)
                    runtimeHealth.recoveryAttempt = 0
                    recordDiagnostic(.recoverySucceeded, attempt: attempt)
                    snapshot.state = .idle
                    snapshot.statusText = "Recovered after \(reason)"
                    return
                } catch {
                    lastError = error
                    runtimeHealth.hermes = .degraded
                    snapshot.statusText = "Recovery attempt \(attempt) of \(recoveryPolicy.maximumAttempts)"
                }
            }

            runtimeHealth.hermes = .unavailable
            runtimeHealth.audio = .degraded
            recordDiagnostic(.recoveryFailed, attempt: recoveryPolicy.maximumAttempts)
            snapshot.state = .error
            snapshot.statusText = "Recovery failed: \(lastError.map { AppErrorFormatter.displayMessage(for: $0) } ?? "Unknown error")"
        }
    }

    private func registerHotkey(_ configuration: HotkeyConfiguration) throws {
        try hotkey.register(
            keyCode: configuration.keyCode,
            modifiers: configuration.modifiers,
            onPressed: { [weak self] in self?.hotkeyPressed(origin: .hotkey) },
            onReleased: { [weak self] in self?.hotkeyReleased() }
        )
    }

    func toggleVoiceInteraction() {
        if hotkeyDown {
            hotkeyReleased()
        } else {
            hotkeyPressed(origin: .orb)
        }
    }

    private func hotkeyPressed(origin: VoiceCaptureOrigin) {
        guard !hotkeyDown,
              started, !needsSetup,
              !isApplyingSettings,
              !isSleeping,
              runtimeHealth.audio != .recovering,
              runtimeHealth.microphone == .healthy else { return }
        hotkeyDown = true
        isVoiceInteraction = true
        activeCaptureOrigin = origin
        lastSpeechUptime = ProcessInfo.processInfo.systemUptime
        orbSpeechDetected = false
        silenceSubmissionTask?.cancel()
        silenceSubmissionTask = nil
        let pipeline = pipeline
        Task { [weak self] in
            await pipeline.beginListening()
            guard let self, self.hotkeyDown else { return }
            do {
                try self.capture.start(onAudioSignal: { [weak self] signal in
                    Task { @MainActor in
                        self?.receiveAudioSignal(signal)
                    }
                })
            } catch {
                self.runtimeHealth.audio = .unavailable
                self.recordDiagnostic(.turnFailed)
                self.snapshot.state = .error
                self.snapshot.statusText = AppErrorFormatter.displayMessage(for: error)
            }
        }
    }

    private func receiveAudioSignal(_ signal: AudioCaptureSignal) {
        guard hotkeyDown else { return }
        // Audio bypasses @Published/SwiftUI entirely. The dedicated bridge coalesces
        // numeric-only updates while WebGL interpolates them at display refresh rate.
        GlassVoiceOrbAudioHub.shared.publish(signal.bands)

        if signal.reachedRecordingLimit {
            hotkeyReleased()
            return
        }

        guard activeCaptureOrigin == .orb,
              automaticallySubmitOrbAfterSilence else { return }
        let speechThreshold = Float(currentConfig.captureProfile.silenceRMSThreshold * 1.5)
        guard signal.rms >= speechThreshold else { return }

        orbSpeechDetected = true
        lastSpeechUptime = ProcessInfo.processInfo.systemUptime
        guard silenceSubmissionTask == nil else { return }
        scheduleSilenceSubmission(after: min(max(orbSilenceDuration, 0.5), 5))
    }

    private func scheduleSilenceSubmission(after delay: TimeInterval) {
        silenceSubmissionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.hotkeyDown, self.activeCaptureOrigin == .orb,
                  self.orbSpeechDetected, self.automaticallySubmitOrbAfterSilence else { return }
            self.silenceSubmissionTask = nil
            let target = min(max(self.orbSilenceDuration, 0.5), 5)
            let silence = ProcessInfo.processInfo.systemUptime - self.lastSpeechUptime
            if silence >= target {
                self.hotkeyReleased()
            } else {
                self.scheduleSilenceSubmission(after: target - silence)
            }
        }
    }

    private func hotkeyReleased() {
        guard hotkeyDown else { return }
        hotkeyDown = false
        activeCaptureOrigin = nil
        orbSpeechDetected = false
        GlassVoiceOrbAudioHub.shared.publish(.zero)
        silenceSubmissionTask?.cancel()
        silenceSubmissionTask = nil
        let samples = capture.stop()
        let pipeline = pipeline
        Task { await pipeline.submit(samples: samples) }
    }

    private func usesSameHermesServer(_ first: AppConfig, _ second: AppConfig) -> Bool {
        let firstKey = first.hermesAPIKey ?? InstallationIdentity.hermesAPIKey()
        let secondKey = second.hermesAPIKey ?? InstallationIdentity.hermesAPIKey()
        return first.hermesBaseURL == second.hermesBaseURL && firstKey == secondKey
    }

    private static func makeRuntime(
        config: AppConfig,
        snapshotRelay: SnapshotRelay,
        conversationContext: [ConversationTurn],
        conversationContextUpdatedAt: Date?,
        hermesServer suppliedServer: HermesServerController? = nil,
        localRecognizer suppliedRecognizer: ParakeetRecognizer? = nil
    ) -> Runtime {
        let apiKey = config.hermesAPIKey ?? InstallationIdentity.hermesAPIKey()
        let hermesServer = suppliedServer ?? HermesServerController(
            baseURL: config.hermesBaseURL,
            apiKey: apiKey,
            onUnexpectedExit: { _ in
                Task { @MainActor in snapshotRelay.hermesExited() }
            }
        )
        let localRecognizer = suppliedRecognizer ?? ParakeetRecognizer(
            modelURL: config.parakeetModelPath,
            computeUnits: config.parakeetComputeUnits,
            silenceRMSThreshold: config.captureProfile.silenceRMSThreshold
        )
        let cloudRecognizer: (any SpeechRecognizing)?
        if config.speechMode != .local, let deepgramAPIKey = config.deepgramAPIKey {
            cloudRecognizer = DeepgramRecognizer(
                apiKey: deepgramAPIKey,
                model: config.deepgramSTTModel,
                silenceRMSThreshold: config.captureProfile.silenceRMSThreshold
            )
        } else {
            cloudRecognizer = nil
        }
        let recognizer = RoutedSpeechRecognizer(
            mode: config.speechMode,
            allowCloudFallback: config.allowCloudFallback,
            local: localRecognizer,
            cloud: cloudRecognizer
        )
        let hermes = HermesClient(
            baseURL: config.hermesBaseURL,
            apiKey: apiKey,
            sessionKey: config.hermesSessionKey,
            modelSelection: config.agentModel
        )
        let localSynthesizer = MacSpeechSynthesizer(voiceIdentifier: config.macVoiceIdentifier)
        let cloudSynthesizer: (any SpeechSynthesizing)?
        if config.speechMode != .local, let deepgramAPIKey = config.deepgramAPIKey {
            cloudSynthesizer = DeepgramSynthesizer(
                apiKey: deepgramAPIKey,
                model: config.deepgramTTSModel
            )
        } else {
            cloudSynthesizer = nil
        }
        let synthesizer = RoutedSpeechSynthesizer(
            mode: config.speechMode,
            allowCloudFallback: config.allowCloudFallback,
            local: localSynthesizer,
            cloud: cloudSynthesizer
        )
        let pipeline = VoicePipeline(
            recognizer: recognizer,
            hermes: hermes,
            synthesizer: synthesizer,
            conversationContext: conversationContext,
            conversationContextUpdatedAt: conversationContextUpdatedAt,
            onConversationContextChanged: { turns in
                _ = ConversationContextStore.save(turns)
            },
            onConversationSessionReset: {
                await snapshotRelay.conversationSessionReset()
            }
        ) { snapshot in
            await snapshotRelay.deliver(snapshot)
        }
        return Runtime(hermesServer: hermesServer, pipeline: pipeline, localRecognizer: localRecognizer)
    }
}
