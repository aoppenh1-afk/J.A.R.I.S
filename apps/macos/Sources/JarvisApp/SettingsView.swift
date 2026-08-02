import AVFoundation
import JarvisCore
import SwiftUI

struct SettingsView: View {
    @State private var preferences: AppPreferences
    @State private var usesCustomDeepgramVoice: Bool
    @State private var deepgramAPIKey = InstallationIdentity.deepgramAPIKey() ?? ""
    @State private var statusText = ""
    @State private var isSaving = false
    @State private var launchAtLoginEnabled = LaunchAtLoginController.isEnabled
    @State private var launchAtLoginStatus = ""

    private let onApply: @MainActor (AppPreferences) async throws -> Void
    private let customDeepgramVoiceID = "__custom__"
    private let voices = AVSpeechSynthesisVoice.speechVoices()
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    init(onApply: @escaping @MainActor (AppPreferences) async throws -> Void) {
        let preferences = AppPreferencesStore.load()
        _preferences = State(initialValue: preferences)
        _usesCustomDeepgramVoice = State(
            initialValue: DeepgramVoice.voice(for: preferences.deepgramTTSModel) == nil
        )
        self.onApply = onApply
    }

    private var deepgramVoiceSelection: Binding<String> {
        Binding(
            get: {
                usesCustomDeepgramVoice
                    ? customDeepgramVoiceID
                    : preferences.deepgramTTSModel
            },
            set: { selection in
                if selection == customDeepgramVoiceID {
                    usesCustomDeepgramVoice = true
                } else {
                    usesCustomDeepgramVoice = false
                    preferences.deepgramTTSModel = selection
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Speech routing") {
                Picker("Mode", selection: $preferences.speechMode) {
                    Text("Local").tag(AppConfig.SpeechMode.local)
                    Text("Cloud").tag(AppConfig.SpeechMode.cloud)
                    Text("Auto").tag(AppConfig.SpeechMode.auto)
                }
                Toggle("Allow cloud fallback", isOn: $preferences.allowCloudFallback)
                    .disabled(preferences.speechMode != .auto)
                Toggle("Speak responses to typed messages", isOn: $preferences.speakTypedResponses)
                Text(preferences.speakTypedResponses
                     ? "Typed and spoken requests both receive an audible response."
                     : "Typed requests stay quiet; push-to-talk responses are still spoken.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if preferences.speechMode != .local {
                    SecureField("Deepgram API key", text: $deepgramAPIKey)
                    Text("Audio is sent to Deepgram only in Cloud mode or after an explicitly enabled Auto fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Interface", selection: $preferences.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                Text("Dark mode uses native macOS liquid-glass panel chrome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Floating orb", selection: $preferences.orbVisibility) {
                    Text("Only during a run").tag(OrbVisibility.duringRun)
                    Text("Always visible").tag(OrbVisibility.always)
                }
                Text(preferences.orbVisibility == .always
                     ? "The orb floats above other windows and can be dragged anywhere."
                     : "The orb appears while J.A.R.V.I.S. is listening, thinking, using tools, or speaking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Voice orbs") {
                Toggle("Shuffle selected orbs", isOn: $preferences.shuffleVoiceOrbs)
                Text(preferences.shuffleVoiceOrbs
                     ? "J.A.R.V.I.S. rotates through the selected designs every 12 seconds."
                     : "Choose the design used by the floating voice orb.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(VoiceOrbStyle.allCases) { style in
                        voiceOrbCard(style)
                    }
                }

                Text("Liquid Glass includes the exact Glass Voice Orb Study renderer for personal, non-commercial use. Its bundled LICENSE and NOTICE attribution are preserved in the application resources.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Voice interaction") {
                Toggle(
                    "Send automatically after silence",
                    isOn: $preferences.automaticallySubmitOrbAfterSilence
                )
                Stepper(
                    value: $preferences.orbSilenceDuration,
                    in: 0.5...5,
                    step: 0.25
                ) {
                    LabeledContent(
                        "Silence duration",
                        value: "\(preferences.orbSilenceDuration.formatted(.number.precision(.fractionLength(1...2)))) seconds"
                    )
                }
                .disabled(!preferences.automaticallySubmitOrbAfterSilence)
                Text("After speech is detected, an orb-started recording is sent when this much silence follows. Push-to-talk still sends when the hotkey is released.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Controls") {
                Picker("Push-to-talk hotkey", selection: $preferences.hotkey) {
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

            Section("Local speech") {
                Picker("Capture profile", selection: $preferences.captureProfile) {
                    Text("Quiet room").tag(AppConfig.CaptureProfile.quiet)
                    Text("Normal").tag(AppConfig.CaptureProfile.normal)
                    Text("Noisy room").tag(AppConfig.CaptureProfile.noisy)
                }
                TextField("Parakeet model path", text: $preferences.parakeetModelPath)
                Picker("Compute units", selection: $preferences.parakeetComputeUnits) {
                    Text("Apple Neural Engine").tag("ane")
                    Text("GPU").tag("gpu")
                    Text("CPU").tag("cpu")
                    Text("Automatic").tag("all")
                }
                Picker("macOS voice", selection: $preferences.macVoiceIdentifier) {
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) — \(voice.language)").tag(String?.some(voice.identifier))
                    }
                }
            }

            Section("Deepgram") {
                TextField("STT model", text: $preferences.deepgramSTTModel)
                Picker("Aura-2 voice", selection: deepgramVoiceSelection) {
                    ForEach(DeepgramVoice.englishAura2) { voice in
                        Text("\(voice.name) — \(voice.detail)").tag(voice.modelID)
                    }
                    Divider()
                    Text("Custom model…").tag(customDeepgramVoiceID)
                }
                if usesCustomDeepgramVoice {
                    TextField("Custom TTS model", text: $preferences.deepgramTTSModel)
                } else if let voice = DeepgramVoice.voice(for: preferences.deepgramTTSModel) {
                    Text("\(voice.modelID) · Changes apply to the next spoken reply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Hermes") {
                TextField("Loopback endpoint", text: $preferences.hermesBaseURL)
            }

            Section("Transcript history") {
                Toggle("Keep the last 50 completed turns", isOn: $preferences.persistTranscriptHistory)
                Text(preferences.persistTranscriptHistory
                     ? "Completed transcript text is stored locally in UserDefaults. It still clears automatically after five minutes without an exchange, matching conversation context."
                     : "Transcript history is kept only in memory and clears after five minutes without an exchange, or when J.A.R.V.I.S. quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                LabeledContent("Parakeet model") {
                    Text(FileManager.default.fileExists(atPath: preferences.parakeetModelPath) ? "Found" : "Missing")
                        .foregroundStyle(FileManager.default.fileExists(atPath: preferences.parakeetModelPath) ? Color.green : Color.red)
                }
                LabeledContent("Deepgram credential") {
                    Text(deepgramAPIKey.isEmpty ? "Not configured" : "Stored in Keychain")
                        .foregroundStyle(deepgramAPIKey.isEmpty ? Color.secondary : Color.green)
                }
                LabeledContent("Speech mode", value: preferences.speechMode.rawValue.capitalized)
                LabeledContent("Hermes endpoint", value: preferences.hermesBaseURL)
            }

            HStack {
                Button(isSaving ? "Applying…" : "Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusText == "Saved and applied." ? Color.secondary : Color.red)
            }
        }
        .formStyle(.grouped)
        .padding(12)
        .frame(width: 540, height: 580)
        .onChange(of: preferences.speechMode) { _, mode in
            if mode != .auto { preferences.allowCloudFallback = false }
        }
    }

    private func voiceOrbCard(_ style: VoiceOrbStyle) -> some View {
        let selected = preferences.shuffleVoiceOrbs
            ? preferences.shuffledVoiceOrbStyles.contains(style)
            : preferences.voiceOrbStyle == style

        return Button {
            if preferences.shuffleVoiceOrbs {
                if selected && preferences.shuffledVoiceOrbStyles.count > 1 {
                    preferences.shuffledVoiceOrbStyles.remove(style)
                } else {
                    preferences.shuffledVoiceOrbStyles.insert(style)
                }
            } else {
                preferences.voiceOrbStyle = style
            }
        } label: {
            VStack(spacing: 7) {
                VoiceOrbAnimatedPreview(style: style)
                    .frame(width: 104, height: 104)
                HStack(spacing: 5) {
                    Image(systemName: selected
                          ? (preferences.shuffleVoiceOrbs ? "checkmark.circle.fill" : "circle.inset.filled")
                          : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(style.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.16), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.displayName) voice orb")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    @MainActor
    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginController.setEnabled(enabled)
            launchAtLoginStatus = ""
        } catch {
            launchAtLoginStatus = error.localizedDescription
            launchAtLoginEnabled = LaunchAtLoginController.isEnabled
        }
    }

    @MainActor
    private func save() async {
        let trimmedKey = deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if preferences.speechMode == .cloud && trimmedKey.isEmpty {
            statusText = "Cloud mode requires a Deepgram API key."
            return
        }
        if preferences.speechMode == .auto && preferences.allowCloudFallback && trimmedKey.isEmpty {
            statusText = "Cloud fallback requires a Deepgram API key."
            return
        }

        guard AppPreferencesStore.save(preferences),
              AppPreferencesStore.saveDeepgramAPIKey(trimmedKey.isEmpty ? nil : trimmedKey) else {
            statusText = "Unable to save settings."
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let config = preferences.makeConfig()
            try config.validate()
            try await onApply(preferences)
            statusText = "Saved and applied."
        } catch {
            statusText = "Saved, but not applied: \(error.localizedDescription)"
        }
    }
}
