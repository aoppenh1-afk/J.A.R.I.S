import AppKit
import JarvisCore
import SwiftUI

struct AssistantPopover: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 36

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .opacity(0.35)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.runtimeHealth.microphone == .unavailable {
                        microphoneWarning
                    }

                    ForEach(visibleHistory) { turn in
                        conversationTurn(turn)
                    }

                    currentConversation

                    if let approval = model.snapshot.approval {
                        approvalView(approval)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            if !model.snapshot.followUpPrompts.isEmpty {
                followUpPrompts
            }

            Divider()
                .opacity(0.35)

            composer
            footer
        }
        .frame(width: 400, height: 540, alignment: .top)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor).opacity(0.72),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("J.A.R.V.I.S.")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(3)
                .foregroundStyle(.primary)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: indicatorColor.opacity(0.55), radius: 5)
                Text(headerStatus)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 118, alignment: .trailing)
            }

            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.primary.opacity(0.10), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Settings")

            Menu {
                Button("New conversation") { model.newConversation() }
                Button("Clear transcript history") { model.clearHistory() }
                    .disabled(model.history.isEmpty)
                Divider()
                Button("Quit J.A.R.V.I.S.") { model.quit() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 26, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var headerStatus: String {
        switch model.snapshot.state {
        case .idle:
            "Ready"
        case .thinking, .tool:
            "Investigating"
        default:
            model.snapshot.statusText
        }
    }

    @ViewBuilder
    private var currentConversation: some View {
        let hasCurrentContent = !model.snapshot.userText.isEmpty
            || !model.snapshot.assistantText.isEmpty
            || !model.snapshot.toolActivities.isEmpty
            || model.snapshot.state == .thinking
            || model.snapshot.state == .tool

        if hasCurrentContent {
            VStack(alignment: .leading, spacing: 14) {
                if !model.snapshot.userText.isEmpty {
                    userMessage(model.snapshot.userText)
                }

                if !model.snapshot.toolActivities.isEmpty
                    || model.snapshot.state == .thinking
                    || model.snapshot.state == .tool {
                    toolActivityView
                }

                if !model.snapshot.assistantText.isEmpty {
                    assistantResponse(
                        model.snapshot.assistantText,
                        sources: model.snapshot.sources,
                        heading: model.snapshot.toolActivities.isEmpty ? "Response" : "Diagnosis"
                    )
                }
            }
        } else if model.history.isEmpty {
            emptyState
        }
    }

    private func conversationTurn(_ turn: ConversationTurn) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            userMessage(turn.userText)
            assistantResponse(
                turn.assistantText,
                sources: turn.sources ?? [],
                heading: "Response"
            )
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.35)
        }
    }

    private func userMessage(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(text)
                .font(.system(size: 12))
                .lineSpacing(1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.055), lineWidth: 1)
        }
    }

    private var toolActivityView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.snapshot.state == .idle ? "Activity" : "Investigating")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(model.snapshot.toolActivities.suffix(8).enumerated()), id: \.element.id) { index, activity in
                    toolActivityRow(activity)
                        .padding(.vertical, 6)

                    if index < model.snapshot.toolActivities.suffix(8).count - 1 {
                        Divider()
                            .opacity(0.28)
                    }
                }

                if model.snapshot.toolActivities.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 18)
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text("Analyzing your request")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text("working")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func toolActivityRow(_ activity: ToolActivity) -> some View {
        HStack(alignment: .center, spacing: 8) {
            toolStateIndicator(activity.state)
                .frame(width: 18)

            Image(systemName: toolActionIcon(activity))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(toolTitle(activity))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if let preview = activity.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !preview.isEmpty,
                   preview != toolTitle(activity) {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            Text(toolStateLabel(activity.state))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(toolColor(activity.state))
        }
    }

    @ViewBuilder
    private func toolStateIndicator(_ state: ToolActivityState) -> some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 16, height: 16)
                .background(Color.green, in: Circle())
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Color.red, in: Circle())
        }
    }

    private func toolTitle(_ activity: ToolActivity) -> String {
        let normalized = activity.name.replacingOccurrences(of: "_", with: " ")
        guard let preview = activity.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty else {
            return normalized.capitalized
        }

        let lowered = normalized.lowercased()
        if lowered.contains("read") {
            return "Read \(URL(fileURLWithPath: preview).lastPathComponent)"
        }
        if lowered.contains("search") || lowered.contains("grep") {
            return "Search \(preview)"
        }
        if lowered.contains("edit") || lowered.contains("write") {
            return "Update \(URL(fileURLWithPath: preview).lastPathComponent)"
        }
        return normalized.capitalized
    }

    private func toolActionIcon(_ activity: ToolActivity) -> String {
        let name = activity.name.lowercased()
        if name.contains("read") { return "doc.text" }
        if name.contains("search") || name.contains("grep") || name.contains("find") { return "magnifyingglass" }
        if name.contains("git") || name.contains("diff") { return "arrow.triangle.branch" }
        if name.contains("edit") || name.contains("write") || name.contains("patch") { return "pencil.line" }
        if name.contains("terminal") || name.contains("bash") || name.contains("shell") { return "terminal" }
        if name.contains("browser") || name.contains("web") { return "safari" }
        if name.contains("test") { return "checkmark.seal" }
        return "wrench.adjustable"
    }

    private func toolStateLabel(_ state: ToolActivityState) -> String {
        switch state {
        case .running: "checking"
        case .completed: "done"
        case .failed: "failed"
        }
    }

    private func toolColor(_ state: ToolActivityState) -> Color {
        switch state {
        case .running: .secondary
        case .completed: .green
        case .failed: .red
        }
    }

    private func assistantResponse(
        _ text: String,
        sources: [ResponseSource],
        heading: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(heading)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(text)
                .font(.system(size: 12))
                .lineSpacing(1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !sources.isEmpty {
                sourceList(sources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceList(_ sources: [ResponseSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sources.count == 1 ? "Source" : "Sources")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)

            ForEach(sources) { source in
                Button {
                    openSource(source)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sourceDisplayName(source))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                            if let label = source.label, !label.isEmpty {
                                Text(label)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Open \(source.path)")
            }
        }
        .padding(.top, 2)
    }

    private func sourceDisplayName(_ source: ResponseSource) -> String {
        let fileName = URL(fileURLWithPath: source.path).lastPathComponent
        guard let line = source.line else { return fileName }
        return "\(fileName):\(line)"
    }

    private func openSource(_ source: ResponseSource) {
        let expandedPath = NSString(string: source.path).expandingTildeInPath
        let candidates: [String]
        if expandedPath.hasPrefix("/") {
            candidates = [expandedPath]
        } else {
            candidates = [
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(expandedPath).path,
                URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(expandedPath).path,
            ]
        }

        if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(source.path, forType: .string)
    }

    private var followUpPrompts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)

            HStack(spacing: 8) {
                ForEach(Array(model.snapshot.followUpPrompts.prefix(3).enumerated()), id: \.offset) { index, prompt in
                    Button {
                        sendFollowUp(prompt)
                    } label: {
                        Label(prompt, systemImage: followUpIcon(prompt))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(FollowUpButtonStyle(prominent: index == 0))
                    .disabled(!model.canSubmitText)
                    .help(prompt)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func followUpIcon(_ prompt: String) -> String {
        let normalized = prompt.lowercased()
        if normalized.contains("fix") || normalized.contains("change") || normalized.contains("update") {
            return "wrench.and.screwdriver"
        }
        if normalized.contains("open") || normalized.contains("source") || normalized.contains("file") {
            return "folder"
        }
        if normalized.contains("test") || normalized.contains("verify") {
            return "checkmark.seal"
        }
        if normalized.contains("explain") || normalized.contains("why") {
            return "doc.text"
        }
        return "arrow.turn.down.right"
    }

    private func sendFollowUp(_ prompt: String) {
        _ = model.submitText(prompt)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Ready when you are")
                .font(.system(size: 15, weight: .semibold))
            Text("Ask a question below or hold \(model.hotkeyLabel) to talk.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var microphoneWarning: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone access is off")
                    .font(.callout.weight(.semibold))
                Text("Typed messages still work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openMicrophoneSettings() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(14)
        .background(.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func approvalView(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Approval required", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(approval.prompt)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text("Review this action before Hermes continues. Approvals are never granted by voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(approval.choices, id: \.rawValue) { choice in
                    if choice == .deny {
                        Button("Deny") { model.approve(choice) }
                            .buttonStyle(.bordered)
                    } else {
                        Button(choice.rawValue.capitalized) { model.approve(choice) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(16)
        .background(.orange.opacity(0.11), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PromptTextView(
                text: $draft,
                height: $composerHeight,
                placeholder: "Ask J.A.R.V.I.S. anything...",
                onSubmit: sendMessage
            )
            .frame(maxWidth: .infinity)
            .frame(height: composerHeight)

            Text("↵")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(canSendMessage ? Color.white : Color.secondary)
                    .background(
                        canSendMessage ? Color.accentColor : Color.primary.opacity(0.065),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .help("Send message")
            .disabled(!canSendMessage)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.primary.opacity(0.09), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic")
                .font(.system(size: 9))
            Text("Hold \(model.hotkeyLabel) to talk")
                .font(.system(size: 9))
            Spacer()
            serviceDot("Network", model.runtimeHealth.network)
            serviceDot("Hermes", model.runtimeHealth.hermes)
            serviceDot("Audio", model.runtimeHealth.audio)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func serviceDot(_ name: String, _ health: ServiceHealth) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(healthColor(health))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 9))
        }
    }

    private var canSendMessage: Bool {
        model.canSubmitText && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendMessage() {
        if model.submitText(draft) {
            draft = ""
        }
    }

    private func healthColor(_ health: ServiceHealth) -> Color {
        switch health {
        case .healthy: .green
        case .recovering: .orange
        case .degraded: .yellow
        case .unavailable: .red
        case .unknown: .gray
        }
    }

    private var visibleHistory: [ConversationTurn] {
        guard let last = model.history.last,
              last.userText == model.snapshot.userText,
              last.assistantText == model.snapshot.assistantText else {
            return model.history
        }
        return Array(model.history.dropLast())
    }

    private var indicatorColor: Color {
        switch model.snapshot.state {
        case .idle: .green
        case .listening: .cyan
        case .transcribing, .thinking, .tool: .blue
        case .approval: .orange
        case .speaking: .purple
        case .interrupting: .yellow
        case .error, .degraded: .red
        case .starting: .gray
        }
    }
}

private struct FollowUpButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                prominent
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1)
                    : Color.primary.opacity(configuration.isPressed ? 0.09 : 0.045),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        prominent ? Color.white.opacity(0.14) : Color.primary.opacity(0.08),
                        lineWidth: 1
                    )
            }
    }
}

private struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> PromptScrollView {
        let scrollView = PromptScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = PromptNativeTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.placeholderText = placeholder
        textView.string = text
        textView.font = .systemFont(ofSize: 12)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainer?.widthTracksTextView = true
        textView.minSize = NSSize(width: 0, height: 36)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: PromptScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PromptNativeTextView else { return }
        textView.onSubmit = onSubmit
        textView.placeholderText = placeholder
        if textView.string != text {
            textView.string = text
        }
        textView.needsDisplay = true
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptTextView
        weak var scrollView: PromptScrollView?

        init(parent: PromptTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PromptNativeTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            updateHeight()
        }

        func updateHeight() {
            guard let scrollView,
                  let textView = scrollView.documentView as? NSTextView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager else { return }

            let width = scrollView.contentSize.width
            guard width > 0 else { return }
            textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: textContainer)

            let measuredHeight = ceil(
                layoutManager.usedRect(for: textContainer).height + (textView.textContainerInset.height * 2)
            )
            let contentHeight = max(36, measuredHeight)
            let targetHeight = min(contentHeight, 80)
            textView.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
            scrollView.hasVerticalScroller = contentHeight > 80

            guard abs(parent.height - targetHeight) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.height = targetHeight
            }
        }
    }
}

private final class PromptScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private final class PromptNativeTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var placeholderText = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty, let font else { return }

        let origin = textContainerOrigin
        let linePadding = textContainer?.lineFragmentPadding ?? 0
        let lineHeight = layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
        let placeholderRect = NSRect(
            x: origin.x + linePadding,
            y: origin.y,
            width: max(0, bounds.width - origin.x - linePadding),
            height: lineHeight
        )
        (placeholderText as NSString).draw(
            in: placeholderRect,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift), !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }
}
