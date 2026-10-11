import AppKit
import AVFoundation
import Combine
import JarvisCore
import SwiftUI

@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var presentation: AnyCancellable?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        presentation = model.$isSetupPresented.removeDuplicates().sink { [weak self] presented in
            guard let self else { return }
            if presented { self.show() }
            else { self.window?.close() }
        }
    }

    private func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
            )
            window.title = "Set up J.A.R.V.I.S."
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupView(model: model))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.isPreparingSetup else { return false }
        // Setup is also accessible from the menu after the window is closed.
        model.isSetupPresented = false
        return true
    }
}

private struct SetupView: View {
    @ObservedObject var model: AppModel
    @State private var preferences = AppPreferencesStore.load()
    @State private var deepgramAPIKey = InstallationIdentity.deepgramAPIKey() ?? ""
    @State private var step = 0
    @State private var readiness: SetupReadiness?
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var isPreparing = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadProgress: Double = 0
    @State private var downloadStatus = ""
    @State private var errorMessage = ""

    private var isBusy: Bool { isPreparing || downloadTask != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Set up J.A.R.V.I.S.").font(.title.weight(.semibold))
            Text("Connect Hermes, prepare speech, and choose microphone access.")
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                ForEach(Array(["Hermes", "Speech", "Microphone"].enumerated()), id: \.offset) { index, title in
                    Label(title, systemImage: step > index ? "checkmark.circle.fill" : "\(index + 1).circle")
                        .foregroundStyle(step == index ? Color.accentColor : Color.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if step == 0 { hermesStep }
                    if step == 1 { speechStep }
                    if step == 2 { microphoneStep }
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(step)
            .disabled(isBusy)
            if downloadTask != nil {
                ProgressView(value: downloadProgress)
                HStack {
                    Text(downloadStatus).font(.caption).lineLimit(1)
                    Spacer()
                    Button("Cancel download") { downloadTask?.cancel() }
                }
            }
            Divider()
            HStack {
                Button("Later") { model.isSetupPresented = false }.disabled(isBusy)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1; errorMessage = "" }.disabled(isBusy)
                }
                if step < 2 {
                    Button("Continue") { step += 1; errorMessage = "" }
                        .disabled(isBusy || !currentStepIsReady)
                        .keyboardShortcut(.defaultAction)
                } else {
                    if isPreparing { ProgressView().controlSize(.small) }
                    Button(isPreparing ? "Preparing…" : "Start J.A.R.V.I.S.") { startRuntime() }
                        .disabled(isBusy || readiness?.canStart != true)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 660, height: 620)
        .onAppear { refreshChecks() }
        .onChange(of: preferences) { _, _ in refreshChecks() }
        .onChange(of: deepgramAPIKey) { _, _ in refreshChecks() }
        .onChange(of: model.isSetupPresented) { _, presented in
            if presented {
                if !model.needsSetup {
                    preferences = AppPreferencesStore.load()
                    deepgramAPIKey = InstallationIdentity.deepgramAPIKey() ?? ""
                    step = 0
                    errorMessage = ""
                }
                microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                refreshChecks()
            }
        }
        .onChange(of: preferences.speechMode) { _, mode in
            if mode != .auto { preferences.allowCloudFallback = false }
        }
        .onDisappear { downloadTask?.cancel() }
    }

    private var currentStepIsReady: Bool {
        readiness?.checks.filter { check in
            step == 0 ? [.endpoint, .hermesExecutable, .hermesProfile].contains(check.id)
                : [.localModel, .cloudCredential].contains(check.id)
        }.allSatisfy(\.isReady) == true
    }

    @ViewBuilder private var hermesStep: some View {
        Text("Hermes runs the assistant and its tools. Install its command-line app and configure a provider for the dedicated jarvis profile.")
        TextField("Local Hermes URL", text: $preferences.hermesBaseURL)
            .textFieldStyle(.roundedBorder)
        checks(for: [.endpoint, .hermesExecutable, .hermesProfile])
        Link("Hermes CLI installation instructions", destination: URL(string: "https://hermes-agent.nousresearch.com/docs/getting-started/installation/")!)
        Text("Run these in Terminal after installing Hermes. Skip the first command if the profile already exists.")
            .font(.callout).foregroundStyle(.secondary)
        Text("hermes profile create jarvis\nhermes -p jarvis setup")
            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .underPageBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        Text("J.A.R.V.I.S. starts this profile on port 8643. A custom loopback endpoint must already be running. API compatibility is checked when you start.")
            .font(.caption).foregroundStyle(.secondary)
        Button("Check again") { refreshChecks() }
    }

    @ViewBuilder private var speechStep: some View {
        Picker("Speech processing", selection: $preferences.speechMode) {
            Text("Local").tag(AppConfig.SpeechMode.local)
            Text("Cloud").tag(AppConfig.SpeechMode.cloud)
            Text("Auto").tag(AppConfig.SpeechMode.auto)
        }
        if preferences.speechMode != .cloud {
            Text("Local speech stays on this Mac. Download the Parakeet Core ML model, or choose a folder you already have.")
            TextField("Parakeet model folder", text: $preferences.parakeetModelPath).textFieldStyle(.roundedBorder)
            HStack {
                Button("Choose folder…") { chooseModelFolder() }
                Button("Download model") { downloadModel() }
                Link("Model details", destination: URL(string: "https://huggingface.co/\(ParakeetModelInstaller.repository)")!)
            }
            Text("Downloading uses the internet and stores large model files in your Library cache. It starts only when you click Download model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if preferences.speechMode == .auto {
            Toggle("Allow cloud fallback", isOn: $preferences.allowCloudFallback)
        }
        if preferences.speechMode == .cloud || preferences.allowCloudFallback {
            SecureField("Deepgram API key", text: $deepgramAPIKey).textFieldStyle(.roundedBorder)
            Text("Audio is sent to Deepgram in Cloud mode or when your enabled Auto fallback is used. The key is saved in Keychain when setup succeeds.")
                .font(.caption).foregroundStyle(.secondary)
        }
        checks(for: [.localModel, .cloudCredential])
        Button("Check again") { refreshChecks() }
    }

    @ViewBuilder private var microphoneStep: some View {
        Text("Allow microphone access for push-to-talk and the voice orb. You can also continue with typed messages.")
        Label(microphoneStatus == .authorized ? "Microphone allowed" : "Microphone not enabled",
              systemImage: microphoneStatus == .authorized ? "checkmark.circle.fill" : "mic.slash")
        if microphoneStatus == .notDetermined {
            Button("Allow microphone") {
                Task {
                    _ = await model.requestMicrophoneAccess()
                    microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        } else if microphoneStatus != .authorized {
            Button("Open microphone settings") { model.openMicrophoneSettings() }
        }
        Button("Check again") {
            microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            refreshChecks()
        }
        checks(for: SetupReadiness.Check.Kind.allCases)
        Text("Starting loads the speech model and checks the authenticated Hermes API. It sends no recording or assistant request. If a check fails, this window stays open with the error.")
            .font(.callout).foregroundStyle(.secondary)
    }

    private func checks(for kinds: [SetupReadiness.Check.Kind]) -> some View {
        ForEach(readiness?.checks.filter { kinds.contains($0.id) } ?? []) { check in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: check.isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(check.isReady ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(check.title).font(.callout.weight(.semibold))
                    Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func refreshChecks() {
        readiness = SetupReadiness.inspect(
            preferences: preferences,
            hasCloudCredential: !deepgramAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            executableURL: HermesRuntimeConfiguration.locateExecutable()
        )
    }

    private func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose model folder"
        if panel.runModal() == .OK, let url = panel.url { preferences.parakeetModelPath = url.path }
    }

    private func downloadModel() {
        errorMessage = ""
        downloadProgress = 0
        downloadStatus = "Connecting to Hugging Face…"
        downloadTask = Task {
            defer { downloadTask = nil }
            do {
                let root = try await ParakeetModelInstaller.download { received, total, file in
                    Task { @MainActor in
                        downloadProgress = total > 0 ? Double(received) / Double(total) : 0
                        downloadStatus = file
                    }
                }
                try Task.checkCancellation()
                preferences.parakeetModelPath = root.path
                refreshChecks()
            } catch is CancellationError {
                downloadStatus = "Download cancelled."
            } catch {
                if Task.isCancelled { downloadStatus = "Download cancelled." }
                else { errorMessage = AppErrorFormatter.displayMessage(for: error) }
            }
        }
    }

    private func startRuntime() {
        refreshChecks()
        guard readiness?.canStart == true else { return }
        isPreparing = true
        errorMessage = ""
        Task {
            defer { isPreparing = false }
            do { try await model.completeSetup(preferences: preferences, deepgramAPIKey: deepgramAPIKey) }
            catch { errorMessage = AppErrorFormatter.displayMessage(for: error) }
        }
    }
}
