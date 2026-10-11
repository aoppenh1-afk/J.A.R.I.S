import AppKit
import JarvisCore
import SwiftUI
import WebKit

protocol GlassVoiceOrbAudioSink: AnyObject {
    func receiveGlassVoiceOrbAudio(_ bands: AudioFrequencyBands)
}

final class GlassVoiceOrbAudioHub {
    static let shared = GlassVoiceOrbAudioHub()

    private let sinks = NSHashTable<AnyObject>.weakObjects()
    private var latestBands: AudioFrequencyBands = .zero

    private init() {}

    func register(_ sink: GlassVoiceOrbAudioSink) {
        sinks.add(sink)
        sink.receiveGlassVoiceOrbAudio(latestBands)
    }

    func unregister(_ sink: GlassVoiceOrbAudioSink) {
        sinks.remove(sink)
    }

    func publish(_ bands: AudioFrequencyBands) {
        latestBands = bands
        for case let sink as GlassVoiceOrbAudioSink in sinks.allObjects {
            sink.receiveGlassVoiceOrbAudio(bands)
        }
    }
}

struct ExactGlassVoiceOrb: View {
    let state: VoiceState
    let assistantText: String
    let statusText: String
    var framesPerSecond: Int = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassVoiceOrbWebView(
            state: state,
            assistantText: assistantText,
            statusText: statusText,
            reduceMotion: reduceMotion,
            framesPerSecond: framesPerSecond
        )
    }
}

private struct GlassVoiceOrbWebView: NSViewRepresentable {
    let state: VoiceState
    let assistantText: String
    let statusText: String
    let reduceMotion: Bool
    let framesPerSecond: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: "glassOrbStatus")
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "jarvisorb")

        let webView = PassThroughWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.wantsLayer = true
        webView.layer?.isOpaque = false
        webView.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.webView = webView
        context.coordinator.pendingState = state
        context.coordinator.pendingAssistantText = assistantText
        context.coordinator.pendingStatusText = statusText
        context.coordinator.pendingReduceMotion = reduceMotion
        context.coordinator.pendingFramesPerSecond = framesPerSecond
        GlassVoiceOrbAudioHub.shared.register(context.coordinator)

        if let url = URL(string: "jarvisorb://bundle/embed.html") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(
            state: state,
            assistantText: assistantText,
            statusText: statusText,
            reduceMotion: reduceMotion,
            framesPerSecond: framesPerSecond
        )
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        GlassVoiceOrbAudioHub.shared.unregister(coordinator)
        coordinator.stopAudioUpdates()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "glassOrbStatus")
        webView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, GlassVoiceOrbAudioSink {
        let schemeHandler = GlassVoiceOrbSchemeHandler()
        weak var webView: WKWebView?
        var pendingState: VoiceState = .idle
        var pendingAssistantText = ""
        var pendingStatusText = ""
        var pendingReduceMotion = false
        var pendingFramesPerSecond = 30

        private var pageLoaded = false
        private var pendingRevision: UInt64 = 1
        private var lastSentRevision: UInt64 = 0
        private var evaluationInFlight = false

        private var pendingAudioBands: AudioFrequencyBands = .zero
        private var lastSentAudioBands: AudioFrequencyBands = .zero
        private var audioEvaluationInFlight = false
        private var audioSendWorkItem: DispatchWorkItem?
        private var lastAudioSentAt: TimeInterval = 0
        private let minimumAudioSendInterval: TimeInterval = 1.0 / 30.0

        func update(
            state: VoiceState,
            assistantText: String,
            statusText: String,
            reduceMotion: Bool,
            framesPerSecond: Int
        ) {
            guard state != pendingState
                    || assistantText != pendingAssistantText
                    || statusText != pendingStatusText
                    || reduceMotion != pendingReduceMotion
                    || framesPerSecond != pendingFramesPerSecond else { return }

            pendingState = state
            pendingAssistantText = assistantText
            pendingStatusText = statusText
            pendingReduceMotion = reduceMotion
            pendingFramesPerSecond = framesPerSecond
            pendingRevision &+= 1
            sendPendingState()
        }

        func receiveGlassVoiceOrbAudio(_ bands: AudioFrequencyBands) {
            guard pendingFramesPerSecond > 0, !pendingReduceMotion else { return }
            guard bands != pendingAudioBands else { return }
            pendingAudioBands = bands
            schedulePendingAudio()
        }

        func stopAudioUpdates() {
            audioSendWorkItem?.cancel()
            audioSendWorkItem = nil
            webView = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            sendPendingState()
            schedulePendingAudio()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak webView] in
                guard let self, let webView else { return }
                webView.evaluateJavaScript("JSON.stringify({ready: document.documentElement.dataset.ready || 'unset', hasBridge: !!window.jarvisOrb, status: window.jarvisOrb?.status?.() || null})") { result, error in
                    if let error {
                        NSLog("[GlassVoiceOrb] status probe failed: %@", error.localizedDescription)
                    } else {
                        NSLog("[GlassVoiceOrb] status probe: %@", String(describing: result))
                    }
                    self.sendPendingState()
                    self.schedulePendingAudio()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[GlassVoiceOrb] navigation failed: %@", error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("[GlassVoiceOrb] provisional navigation failed: %@", error.localizedDescription)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "glassOrbStatus" else { return }
            if let payload = message.body as? [String: Any],
               let status = payload["status"] as? String {
                let detail = payload["detail"] as? String ?? ""
                NSLog("[GlassVoiceOrb] %@ %@", status, detail)
            } else {
                NSLog("[GlassVoiceOrb] %@", String(describing: message.body))
            }
        }

        private func sendPendingState() {
            guard pageLoaded,
                  let webView,
                  !evaluationInFlight,
                  pendingRevision != lastSentRevision else { return }

            let revision = pendingRevision
            let payload: [String: Any] = [
                "mode": pendingState.glassOrbMode,
                "energy": pendingState.glassOrbEnergy,
                "assistantText": pendingAssistantText,
                "statusText": pendingStatusText,
                "reducedMotion": pendingReduceMotion,
                "framesPerSecond": pendingFramesPerSecond,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }

            evaluationInFlight = true
            let script = "window.jarvisOrb ? (window.jarvisOrb.update(\(json)), true) : false;"
            webView.evaluateJavaScript(script) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.evaluationInFlight = false

                    if let error {
                        NSLog("[GlassVoiceOrb] state update failed: %@", error.localizedDescription)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            self?.sendPendingState()
                        }
                        return
                    }

                    guard result as? Bool == true else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            self?.sendPendingState()
                        }
                        return
                    }

                    self.lastSentRevision = max(self.lastSentRevision, revision)
                    self.sendPendingState()
                }
            }
        }

        private func schedulePendingAudio() {
            guard pageLoaded,
                  webView != nil,
                  !audioEvaluationInFlight,
                  pendingAudioBands != lastSentAudioBands,
                  audioSendWorkItem == nil else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - lastAudioSentAt
            let delay = max(0, minimumAudioSendInterval - elapsed)
            if delay == 0 {
                sendPendingAudio()
                return
            }

            let workItem = DispatchWorkItem { [weak self] in
                self?.audioSendWorkItem = nil
                self?.sendPendingAudio()
            }
            audioSendWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func sendPendingAudio() {
            guard pageLoaded,
                  let webView,
                  !audioEvaluationInFlight,
                  pendingAudioBands != lastSentAudioBands else { return }

            let bands = pendingAudioBands
            let script = "window.jarvisOrb ? (window.jarvisOrb.setAudio(\(bands.low),\(bands.mid),\(bands.high)), true) : false;"
            audioEvaluationInFlight = true
            webView.evaluateJavaScript(script) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.audioEvaluationInFlight = false

                    guard error == nil, result as? Bool == true else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                            self?.schedulePendingAudio()
                        }
                        return
                    }

                    self.lastSentAudioBands = bands
                    self.lastAudioSentAt = ProcessInfo.processInfo.systemUptime
                    self.schedulePendingAudio()
                }
            }
        }
    }
}


private final class PassThroughWebView: WKWebView {
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class GlassVoiceOrbSchemeHandler: NSObject, WKURLSchemeHandler {
    private let resourceRoot = GlassVoiceOrbResources.rootURL

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let resourceRoot else {
            urlSchemeTask.didFailWithError(GlassVoiceOrbResourceError.missingBundleResources)
            return
        }

        let relativePath = requestURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else {
            urlSchemeTask.didFailWithError(GlassVoiceOrbResourceError.invalidPath)
            return
        }

        let root = resourceRoot.standardizedFileURL
        let fileURL = root.appending(path: relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/") else {
            urlSchemeTask.didFailWithError(GlassVoiceOrbResourceError.invalidPath)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let response = URLResponse(
                url: requestURL,
                mimeType: Self.mimeType(for: fileURL.pathExtension),
                expectedContentLength: data.count,
                textEncodingName: Self.isTextFile(fileURL.pathExtension) ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": "text/html"
        case "js": "application/javascript"
        case "glsl": "text/plain"
        case "png": "image/png"
        case "webp": "image/webp"
        case "md": "text/markdown"
        default: "application/octet-stream"
        }
    }

    private static func isTextFile(_ pathExtension: String) -> Bool {
        ["html", "js", "glsl", "md", "txt"].contains(pathExtension.lowercased())
    }
}

private enum GlassVoiceOrbResources {
    static var rootURL: URL? {
#if SWIFT_PACKAGE
        locate(in: .module)
#else
        locate(in: .main)
#endif
    }

    private static func locate(in bundle: Bundle) -> URL? {
        if let directory = bundle.url(forResource: "GlassVoiceOrbStudy", withExtension: nil) {
            return directory
        }
        guard let candidate = bundle.resourceURL?.appending(path: "GlassVoiceOrbStudy", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }
}

private enum GlassVoiceOrbResourceError: LocalizedError {
    case missingBundleResources
    case invalidPath

    var errorDescription: String? {
        switch self {
        case .missingBundleResources:
            "The bundled Glass Voice Orb Study resources are missing."
        case .invalidPath:
            "The requested Glass Voice Orb resource path is invalid."
        }
    }
}

private extension VoiceState {
    var glassOrbMode: String {
        switch self {
        case .listening:
            "listening"
        case .transcribing, .thinking, .tool:
            "thinking"
        case .speaking, .approval, .error, .degraded:
            "dialog"
        case .interrupting:
            "listening"
        case .starting, .idle:
            "idle"
        }
    }

    var glassOrbEnergy: Double {
        switch self {
        case .listening:
            0.72
        case .transcribing:
            0.55
        case .thinking, .tool:
            0.48
        case .approval:
            0.62
        case .speaking:
            1.0
        case .interrupting:
            0.86
        case .error, .degraded:
            0.34
        case .starting:
            0.24
        case .idle:
            0.18
        }
    }
}
