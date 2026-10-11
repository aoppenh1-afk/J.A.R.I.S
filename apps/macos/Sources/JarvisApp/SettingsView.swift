import AVFoundation
import JarvisCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: AppUpdater
    @StateObject private var settings: SettingsModel
    @State private var selectedPane: SettingsPane = .voice
    @State private var usesCustomDeepgramVoice: Bool
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginStatus = ""

    private let customDeepgramVoiceID = "__custom__"
    private static let availableVoices = AVSpeechSynthesisVoice.speechVoices()
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    private var voices: [AVSpeechSynthesisVoice] { Self.availableVoices }

    init(updater: AppUpdater, onApply: @escaping @MainActor (AppPreferences) async throws -> Void) {
        self.updater = updater
        _settings = StateObject(wrappedValue: SettingsModel(onApply: onApply))
        _usesCustomDeepgramVoice = State(
            initialValue: DeepgramVoice.voice(for: AppPreferencesStore.load().deepgramTTSModel) == nil
        )
    }

    private var deepgramVoiceSelection: Binding<String> {
        Binding(
            get: {
                usesCustomDeepgramVoice
                    ? customDeepgramVoiceID
                    : settings.preferences.deepgramTTSModel
            },
            set: { selection in
                if selection == customDeepgramVoiceID {
                    usesCustomDeepgramVoice = true
                } else {
                    usesCustomDeepgramVoice = false
                    settings.preferences.deepgramTTSModel = selection
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("J.A.R.V.I.S.")
                    .font(.headline)
                    .padding(.bottom, 18)
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        Label(pane.title, systemImage: pane.symbol)
                            .font(.system(size: 13, weight: selectedPane == pane ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(selectedPane == pane ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
                }
                Spacer()
                Label("On your Mac", systemImage: "desktopcomputer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(width: 164)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))

            Divider()

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedPane.title)
                        .font(.title2.weight(.semibold))
                    Text(selectedPane.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)

                Form {
                    if selectedPane == .voice {
                        Section("Speech routing") {
                            Picker("Mode", selection: $settings.preferences.speechMode) {
                                Text("Local").tag(AppConfig.SpeechMode.local)
                                Text("Cloud").tag(AppConfig.SpeechMode.cloud)
                                Text("Auto").tag(AppConfig.SpeechMode.auto)
                            }
                            Toggle("Allow cloud fallback", isOn: $settings.preferences.allowCloudFallback)
                            .disabled(settings.preferences.speechMode != .auto)
                            Toggle("Speak responses to typed messages", isOn: $settings.preferences.speakTypedResponses)
                            Text(settings.preferences.speakTypedResponses
                            ? "Typed and spoken requests both receive an audible response."
                            : "Typed requests stay quiet; push-to-talk responses are still spoken.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if settings.preferences.speechMode != .local {
                                SecureField("Deepgram API key", text: $settings.deepgramAPIKey)
                                Text("Audio is sent to Deepgram only in Cloud mode or after an explicitly enabled Auto fallback.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if selectedPane == .appearance {
                        Section("Appearance") {
                            Picker("Animation", selection: $settings.preferences.animationQuality) {
                                ForEach(AnimationQuality.allCases) { quality in
                                    Text(quality.displayName).tag(quality)
                                }
                            }
                            Text("Automatic uses 30 fps during a run and reduces motion in Low Power Mode. Save energy uses 15 fps. Hidden orbs stop rendering.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Picker("Interface", selection: $settings.preferences.appearance) {
                                ForEach(AppAppearance.allCases, id: \.self) { appearance in
                                    Text(appearance.displayName).tag(appearance)
                                }
                            }
                            Text("Dark mode uses native macOS liquid-glass panel chrome.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Picker("Floating orb", selection: $settings.preferences.orbVisibility) {
                                Text("Only during a run").tag(OrbVisibility.duringRun)
                                Text("Always visible").tag(OrbVisibility.always)
                            }
                            Text(settings.preferences.orbVisibility == .always
                            ? "The orb floats above other windows and can be dragged anywhere."
                            : "The orb appears while J.A.R.V.I.S. is listening, thinking, using tools, or speaking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if selectedPane == .appearance {
                        Section("Voice orb") {
                            LabeledContent("Design", value: "Liquid Glass")
                            Text("Liquid Glass includes the Glass Voice Orb Study renderer for personal, non-commercial use. Its bundled LICENSE and NOTICE attribution are preserved in the application resources.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if selectedPane == .models {
                        modelSettings
                    }
                    if selectedPane == .voice {
                        Section("Voice interaction") {
                            Toggle(
                            "Send automatically after silence",
                            isOn: $settings.preferences.automaticallySubmitOrbAfterSilence
                            )
                            Stepper(
                            value: $settings.preferences.orbSilenceDuration,
                            in: 0.5...5,
                            step: 0.25
                            ) {
                                LabeledContent(
                                "Silence duration",
                                value: "\(settings.preferences.orbSilenceDuration.formatted(.number.precision(.fractionLength(1...2)))) seconds"
                                )
                            }
                            .disabled(!settings.preferences.automaticallySubmitOrbAfterSilence)
                            Text("After speech is detected, an orb-started recording is sent when this much silence follows. Push-to-talk still sends when the hotkey is released.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if selectedPane == .general {
                        Section("Software updates") {
                            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                            Toggle("Download updates automatically", isOn: $updater.automaticallyDownloadsUpdates)
                                .disabled(!updater.automaticallyChecksForUpdates)
                            Button("Check for Updates…") { updater.checkForUpdates() }
                                .disabled(!updater.canCheckForUpdates)
                            Text(updater.status).font(.caption).foregroundStyle(.secondary)
                        }
                        .disabled(!updater.isConfigured)
                        Section("Controls") {
                            Picker("Push-to-talk hotkey", selection: $settings.preferences.hotkey) {
                                ForEach(HotkeyConfiguration.allCases, id: \.self) { hotkey in
                                    Text(hotkey.displayName).tag(hotkey)
                                }
                            }
                            Toggle("Launch at login", isOn: $launchAtLoginEnabled)
                            .disabled(!LaunchAtLoginController.isSupported)
                            .onChange(of: launchAtLoginEnabled) { _, enabled in
                                updateLaunchAtLogin(enabled)
                            }
                            if !LaunchAtLoginController.isSupported {
                                Text("Launch at login becomes available in the packaged macOS application.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else if !launchAtLoginStatus.isEmpty {
                                Text(launchAtLoginStatus)
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                        }
                    }
                    if selectedPane == .voice {
                        Section("Local speech") {
                            Picker("Capture profile", selection: $settings.preferences.captureProfile) {
                                Text("Quiet room").tag(AppConfig.CaptureProfile.quiet)
                                Text("Normal").tag(AppConfig.CaptureProfile.normal)
                                Text("Noisy room").tag(AppConfig.CaptureProfile.noisy)
                            }
                            TextField("Parakeet model path", text: $settings.preferences.parakeetModelPath)
                            Picker("Compute units", selection: $settings.preferences.parakeetComputeUnits) {
                                Text("Apple Neural Engine").tag("ane")
                                Text("GPU").tag("gpu")
                                Text("CPU").tag("cpu")
                                Text("Automatic").tag("all")
                            }
                            Picker("macOS voice", selection: $settings.preferences.macVoiceIdentifier) {
                                ForEach(voices, id: \.identifier) { voice in
                                    Text("\(voice.name) — \(voice.language)").tag(String?.some(voice.identifier))
                                }
                            }
                        }
                    }
                    if selectedPane == .voice {
                        Section("Deepgram") {
                            TextField("STT model", text: $settings.preferences.deepgramSTTModel)
                            Picker("Aura-2 voice", selection: deepgramVoiceSelection) {
                                ForEach(DeepgramVoice.englishAura2) { voice in
                                    Text("\(voice.name) — \(voice.detail)").tag(voice.modelID)
                                }
                                Divider()
                                Text("Custom model…").tag(customDeepgramVoiceID)
                            }
                            if usesCustomDeepgramVoice {
                                TextField("Custom TTS model", text: $settings.preferences.deepgramTTSModel)
                            } else if let voice = DeepgramVoice.voice(for: settings.preferences.deepgramTTSModel) {
                                Text("\(voice.modelID) · Changes apply to the next spoken reply.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if selectedPane == .advanced {
                        Section("Hermes") {
                            HStack {
                                TextField("Loopback endpoint", text: $settings.preferences.hermesBaseURL)
                                if settings.preferences.hermesBaseURL != HermesRuntimeConfiguration.managedBaseURL.absoluteString {
                                    Button("Reset to Default") {
                                        settings.preferences.hermesBaseURL = HermesRuntimeConfiguration.managedBaseURL.absoluteString
                                    }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                                }
                            }
                            Text(settings.preferences.hermesBaseURL == HermesRuntimeConfiguration.managedBaseURL.absoluteString
                            ? "Managed J.A.R.V.I.S. profile on the dedicated local endpoint (port 8643)."
                            : "Custom endpoint configured. Managed auto-start requires http://127.0.0.1:8643. Use \"Reset to Default\" if you are experiencing connection issues on legacy ports (e.g. 8642).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if selectedPane == .general {
                        Section("Transcript history") {
                            Toggle("Keep the last 50 completed turns", isOn: $settings.preferences.persistTranscriptHistory)
                            Text(settings.preferences.persistTranscriptHistory
                            ? "Completed transcript text is stored locally in UserDefaults. It still clears automatically after five minutes without an exchange, matching conversation context."
                            : "Transcript history is kept only in memory and clears after five minutes without an exchange, or when J.A.R.V.I.S. quits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if selectedPane == .advanced {
                        Section("Diagnostics") {
                            LabeledContent("Parakeet model") {
                                Text(FileManager.default.fileExists(atPath: settings.preferences.parakeetModelPath) ? "Found" : "Missing")
                                .foregroundStyle(FileManager.default.fileExists(atPath: settings.preferences.parakeetModelPath) ? Color.green : Color.red)
                            }
                            LabeledContent("Deepgram credential") {
                                Text(settings.deepgramAPIKey.isEmpty ? "Not configured" : "Stored in Keychain")
                                .foregroundStyle(settings.deepgramAPIKey.isEmpty ? Color.secondary : Color.green)
                            }
                            LabeledContent("Speech mode", value: settings.preferences.speechMode.rawValue.capitalized)
                            LabeledContent("Hermes endpoint", value: settings.preferences.hermesBaseURL)
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()
                HStack(spacing: 10) {
                    if settings.saveState == .applying || settings.saveState == .pending {
                        ProgressView().controlSize(.small)
                    }
                    Text(settings.statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Settings status")
                        .accessibilityValue(settings.statusText)
                }
                .padding(16)
            }
        }
        .frame(width: 760, height: 640)
        .onChange(of: settings.preferences.speechMode) { _, mode in
            if mode != .auto { settings.preferences.allowCloudFallback = false }
        }
        .onDisappear { settings.flush() }
        .task(id: selectedPane) {
            if selectedPane == .models && settings.catalog == nil { await settings.loadModels() }
        }
    }

    private var statusColor: Color {
        if case .failed = settings.saveState { return .red }
        return .secondary
    }

    @ViewBuilder
    private var modelSettings: some View {
        Section("Assistant model") {
            Picker("Provider", selection: Binding(
                get: { settings.preferences.agentModel.provider },
                set: { provider in
                    settings.preferences.agentModel = HermesModelSelection(provider: provider)
                }
            )) {
                Text("Use Hermes default").tag("")
                ForEach(settings.selectableProviders) { provider in
                    Text(provider.name).tag(provider.slug)
                }
                if !settings.preferences.agentModel.provider.isEmpty,
                   !settings.selectableProviders.contains(where: { $0.slug == settings.preferences.agentModel.provider }) {
                    Text(settings.preferences.agentModel.provider).tag(settings.preferences.agentModel.provider)
                }
            }
            Picker("Model", selection: $settings.preferences.agentModel.model) {
                Text("Use provider default").tag("")
                ForEach(settings.selectedProvider?.availableModels ?? [], id: \.self) { model in
                    Text(model).tag(model)
                }
                if !settings.preferences.agentModel.model.isEmpty,
                   !(settings.selectedProvider?.availableModels.contains(settings.preferences.agentModel.model) ?? false) {
                    Text(settings.preferences.agentModel.model).tag(settings.preferences.agentModel.model)
                }
            }
            if let catalog = settings.catalog {
                LabeledContent("Hermes default", value: [catalog.provider, catalog.model].compactMap { $0 }.joined(separator: " / "))
            }
            Text("Changes apply to your next Jarvis request. Hermes’s own default and other apps keep their settings. Provider credentials come from your Hermes configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if settings.isLoadingModels { ProgressView().controlSize(.small) }
                Button("Refresh models") { Task { await settings.loadModels(refresh: true) } }
                    .disabled(settings.isLoadingModels)
            }
            if !settings.modelError.isEmpty {
                Text(settings.modelError).font(.caption).foregroundStyle(.orange)
            }
        }
        Section("Custom selection") {
            TextField("Provider ID", text: $settings.preferences.agentModel.provider)
            TextField("Model ID", text: $settings.preferences.agentModel.model)
            Text("Use the provider ID and exact model ID understood by Hermes. Leave either field empty to follow its default.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            launchAtLoginStatus = ""
        } catch {
            launchAtLoginStatus = AppErrorFormatter.displayMessage(for: error)
            launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        }
    }

}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, models, voice, appearance, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .voice: "Voice & speech"
        case .appearance: "Appearance"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .models: "cpu"
        case .voice: "waveform"
        case .appearance: "paintpalette"
        case .advanced: "wrench.and.screwdriver"
        }
    }
    var detail: String {
        switch self {
        case .general: "Shortcuts, startup, and transcript storage."
        case .models: "Choose the AI provider and model Jarvis uses."
        case .voice: "Choose where speech is processed and how replies sound."
        case .appearance: "Adjust the interface, voice orb, and animation energy use."
        case .advanced: "Local runtime connection and configuration checks."
        }
    }
}
