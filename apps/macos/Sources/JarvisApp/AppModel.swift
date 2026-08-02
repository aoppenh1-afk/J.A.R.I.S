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
    @Published private(set) var voiceOrbStyle: VoiceOrbStyle
    @Published private(set) var shuffleVoiceOrbs: Bool
    @Published private(set) var shuffledVoiceOrbStyles: Set<VoiceOrbStyle>
    @Published private(set) var isVoiceInteraction = false
    @Published private(set) var speakTypedResponses: Bool
    @Published private(set) var automaticallySubmitOrbAfterSilence: Bool
    @Published private(set) var orbSilenceDuration: Double
    private enum VoiceCaptureOrigin {
        case hotkey
        case orb
    }

    private struct Runtime {
        let hermesServer: HermesServerController
        let pipeline: VoicePipeline
    }

    private let capture: AudioCaptureService
    private let hotkey: GlobalHotkey
    private let snapshotRelay: SnapshotRelay
    private var hermesServer: HermesServerController
    private var pipeline: VoicePipeline
    private var currentConfig: AppConfig
    private var started = false
    private var hotkeyDown = false
    private var isApplyingSettings = false
    private var persistsHistory: Bool
    private var lastArchivedGeneration: Int?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var audioObserver: NSObjectProtocol?
    private var applicationObserver: NSObjectProtocol?
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
        self.currentConfig = config
        self.persistsHistory = persistsHistory
        self.orbVisibility = preferences.orbVisibility
        self.voiceOrbStyle = preferences.voiceOrbStyle
        self.shuffleVoiceOrbs = preferences.shuffleVoiceOrbs
        self.shuffledVoiceOrbStyles = preferences.shuffledVoiceOrbStyles
        self.speakTypedResponses = preferences.speakTypedResponses
        self.automaticallySubmitOrbAfterSilence = preferences.automaticallySubmitOrbAfterSilence
        self.orbSilenceDuration = preferences.orbSilenceDuration
        if contextExpired {
            ConversationHistoryStore.clear()
            self.history = []
        } else {
            self.history = persistsHistory ? ConversationHistoryStore.load() : []
        }
        self.hotkeyLabel = config.hotkey.displayName
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
        guard !started else { return }
        started = true
        recordDiagnostic(.appStarted)

        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        if microphoneAllowed {
            runtimeHealth.microphone = .healthy
            recordDiagnostic(.microphoneAvailable)
        } else {
            runtimeHealth.microphone = .unavailable
            recordDiagnostic(.microphoneUnavailable)
        }

        do {
            snapshot.state = .starting
            snapshot.statusText = "Starting Hermes"
            try await hermesServer.ensureAvailable()
            runtimeHealth.hermes = .healthy
            try registerHotkey(currentConfig.hotkey)
            try await pipeline.prepareOrThrow()
            runtimeHealth.audio = .healthy
        } catch {
            if runtimeHealth.hermes != .healthy {
                runtimeHealth.hermes = .unavailable
            }
            snapshot.state = .error
            snapshot.statusText = error.localizedDescription
        }
    }

    func apply(preferences: AppPreferences) async throws {
        orbVisibility = preferences.orbVisibility
        voiceOrbStyle = preferences.voiceOrbStyle
        shuffleVoiceOrbs = preferences.shuffleVoiceOrbs
        shuffledVoiceOrbStyles = preferences.shuffledVoiceOrbStyles
        speakTypedResponses = preferences.speakTypedResponses
        automaticallySubmitOrbAfterSilence = preferences.automaticallySubmitOrbAfterSilence
        orbSilenceDuration = preferences.orbSilenceDuration
        try await apply(config: preferences.makeConfig())
    }

    func apply(config: AppConfig) async throws {
        try config.validate()
        guard !isApplyingSettings else { throw AppModelError.settingsApplicationInProgress }
        isApplyingSettings = true
        defer { isApplyingSettings = false }

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
            hermesServer: reusesHermesServer ? previousServer : nil
        )

        await previousPipeline.shutdown()

        do {
            try await candidate.hermesServer.ensureAvailable()
            try await candidate.pipeline.prepareOrThrow()
            try registerHotkey(config.hotkey)

            pipeline = candidate.pipeline
            hermesServer = candidate.hermesServer
            currentConfig = config
            hotkeyLabel = config.hotkey.displayName
            persistsHistory = AppPreferencesStore.load().persistTranscriptHistory
            if !persistsHistory {
                ConversationHistoryStore.clear()
            } else {
                _ = ConversationHistoryStore.save(history)
            }
            lastArchivedGeneration = nil

            if !reusesHermesServer {
                await previousServer.shutdown()
            }
            recordDiagnostic(.settingsApplied)
            snapshot.state = .idle
            snapshot.statusText = "Settings applied"
        } catch {
            try? registerHotkey(currentConfig.hotkey)
            await candidate.pipeline.shutdown()
            if !reusesHermesServer {
                await candidate.hermesServer.shutdown()
            }
            snapshot.state = .error
            snapshot.statusText = "Settings saved but could not be applied: \(error.localizedDescription)"
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
            return
        }
        history.append(ConversationTurn(
            userText: nextSnapshot.userText,
            assistantText: nextSnapshot.assistantText,
            provider: nextSnapshot.speechProvider
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
            && !isApplyingSettings
            && !isSleeping
            && runtimeHealth.hermes == .healthy
            && snapshot.state != .starting
            && snapshot.state != .approval
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
        historyExpiryTask?.cancel()
        historyExpiryTask = nil
        lastArchivedGeneration = nil
        let pipeline = pipeline
        Task { await pipeline.newConversation() }
    }

    func clearHistory() {
        clearTranscriptHistory(resetPipeline: true)
    }

    private func clearTranscriptHistory(resetPipeline: Bool) {
        historyExpiryTask?.cancel()
        historyExpiryTask = nil
        history.removeAll()
        ConversationHistoryStore.clear()
        lastArchivedGeneration = nil
        guard resetPipeline else { return }
        ConversationContextStore.clear()
        let pipeline = pipeline
        Task { await pipeline.newConversation() }
    }

    private func scheduleHistoryExpiry(after delay: TimeInterval) {
        historyExpiryTask?.cancel()
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
        historyExpiryTask?.cancel()
        historyExpiryTask = nil
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
        historyExpiryTask?.cancel()
        historyExpiryTask = nil
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
                    if self.snapshot.state != .listening {
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
    }

    private func refreshMicrophoneAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let isAuthorized = status == .authorized
        if isAuthorized {
            if runtimeHealth.microphone != .healthy {
                recordDiagnostic(.microphoneAvailable)
                runtimeHealth.microphone = .healthy
                recoverRuntime(reason: "microphone permission restoration", debounce: false)
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
        guard started, !isSleeping, !isApplyingSettings else { return }
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
            snapshot.statusText = "Recovery failed: \(lastError?.localizedDescription ?? "Unknown error")"
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
              !isApplyingSettings,
              !isSleeping,
              runtimeHealth.audio != .recovering,
              runtimeHealth.microphone == .healthy else { return }
        hotkeyDown = true
        isVoiceInteraction = true
        activeCaptureOrigin = origin
        orbSpeechDetected = false
        silenceSubmissionTask?.cancel()
        silenceSubmissionTask = nil
        let pipeline = pipeline
        Task {
            await pipeline.beginListening()
            guard hotkeyDown else { return }
            do {
                try capture.start(onAudioSignal: { [weak self] signal in
                    Task { @MainActor in
                        self?.receiveAudioSignal(signal)
                    }
                })
            } catch {
                runtimeHealth.audio = .unavailable
                recordDiagnostic(.turnFailed)
                snapshot.state = .error
                snapshot.statusText = error.localizedDescription
            }
        }
    }

    private func receiveAudioSignal(_ signal: AudioCaptureSignal) {
        guard hotkeyDown else { return }
        // Audio bypasses @Published/SwiftUI entirely. The dedicated bridge coalesces
        // numeric-only updates while WebGL interpolates them at display refresh rate.
        GlassVoiceOrbAudioHub.shared.publish(signal.bands)

        guard activeCaptureOrigin == .orb,
              automaticallySubmitOrbAfterSilence else { return }
        let speechThreshold = Float(currentConfig.captureProfile.silenceRMSThreshold * 1.5)
        guard signal.rms >= speechThreshold else { return }

        orbSpeechDetected = true
        silenceSubmissionTask?.cancel()
        let delay = min(max(orbSilenceDuration, 0.5), 5)
        silenceSubmissionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self,
                  !Task.isCancelled,
                  self.hotkeyDown,
                  self.activeCaptureOrigin == .orb,
                  self.orbSpeechDetected else { return }
            self.hotkeyReleased()
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
        hermesServer suppliedServer: HermesServerController? = nil
    ) -> Runtime {
        let apiKey = config.hermesAPIKey ?? InstallationIdentity.hermesAPIKey()
        let hermesServer = suppliedServer ?? HermesServerController(
            baseURL: config.hermesBaseURL,
            apiKey: apiKey,
            onUnexpectedExit: { _ in
                Task { @MainActor in snapshotRelay.hermesExited() }
            }
        )
        let localRecognizer = ParakeetRecognizer(
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
            sessionKey: config.hermesSessionKey
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
        return Runtime(hermesServer: hermesServer, pipeline: pipeline)
    }
}
