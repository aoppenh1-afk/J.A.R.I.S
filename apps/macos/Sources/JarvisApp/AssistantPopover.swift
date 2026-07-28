import AppKit
import JarvisCore
import SwiftUI

struct AssistantPopover: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 14) {
            header
            statusCard

            if model.runtimeHealth.microphone == .unavailable {
                Button("Open Microphone Privacy Settings") { model.openMicrophoneSettings() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            conversationCard

            if !model.snapshot.toolActivities.isEmpty {
                toolActivityView
            }

            if let approval = model.snapshot.approval {
                approvalView(approval)
            }

            composer
            footer
        }
        .padding(16)
        .frame(width: 420, height: 600, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("J.A.R.V.I.S.")
                    .font(.title2.weight(.bold))
                Text(model.snapshot.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let provider = model.snapshot.speechProvider {
                Text(provider == .local ? "LOCAL" : "DEEPGRAM")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(provider == .local ? Color.green : Color.blue)
                    .background(
                        (provider == .local ? Color.green : Color.blue).opacity(0.14),
                        in: Capsule()
                    )
            }
        }
        .padding(.horizontal, 2)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 11, height: 11)
                    .shadow(color: indicatorColor.opacity(0.55), radius: 5)
                Text(model.snapshot.state.rawValue.capitalized)
                    .font(.headline)
                Spacer()
                if model.runtimeHealth.recoveryAttempt > 0 {
                    Text("Recovery attempt \(model.runtimeHealth.recoveryAttempt)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            HStack(spacing: 8) {
                healthLabel("Network", model.runtimeHealth.network, icon: "network")
                healthLabel("Hermes", model.runtimeHealth.hermes, icon: "bolt.horizontal")
                healthLabel("Audio", model.runtimeHealth.audio, icon: "speaker.wave.2")
                healthLabel("Mic", model.runtimeHealth.microphone, icon: "mic")
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(14)
        .cardStyle()
    }

    private func healthLabel(_ name: String, _ health: ServiceHealth, icon: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(healthColor(health))
                .frame(width: 6, height: 6)
            Image(systemName: icon)
                .font(.caption2)
            Text(name)
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(width: 86)
        .background(.quaternary, in: Capsule())
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

    private var conversationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            transcript
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .cardStyle()
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(visibleHistory) { turn in
                    transcriptRow(label: "You", text: turn.userText, isUser: true)
                    transcriptRow(label: "J.A.R.V.I.S.", text: turn.assistantText, isUser: false)
                    Divider()
                }
                if !model.snapshot.userText.isEmpty {
                    transcriptRow(label: "You", text: model.snapshot.userText, isUser: true)
                }
                if !model.snapshot.assistantText.isEmpty {
                    transcriptRow(label: "J.A.R.V.I.S.", text: model.snapshot.assistantText, isUser: false)
                }
                if model.history.isEmpty && model.snapshot.userText.isEmpty && model.snapshot.assistantText.isEmpty {
                    ContentUnavailableView(
                        "Ready when you are",
                        systemImage: "waveform",
                        description: Text("Type a message or hold \(model.hotkeyLabel) to talk.")
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private func transcriptRow(label: String, text: String, isUser: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isUser ? Color.accentColor : Color.secondary)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message J.A.R.V.I.S.", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onSubmit(sendMessage)
            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(canSendMessage ? Color.accentColor : Color.secondary.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Send message")
            .disabled(!canSendMessage)
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

    private var toolActivityView: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Tool activity", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(model.snapshot.toolActivities.suffix(4)) { activity in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: toolIcon(activity.state))
                        .font(.callout)
                        .foregroundStyle(toolColor(activity.state))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.name)
                            .font(.callout.weight(.medium))
                        if let preview = activity.preview, !preview.isEmpty {
                            Text(preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(activity.state.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(toolColor(activity.state))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(toolColor(activity.state).opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private func toolIcon(_ state: ToolActivityState) -> String {
        switch state {
        case .running: "gearshape.2"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func toolColor(_ state: ToolActivityState) -> Color {
        switch state {
        case .running: .blue
        case .completed: .green
        case .failed: .red
        }
    }

    private func approvalView(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval required", systemImage: "lock.shield.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(approval.prompt)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text("Review the action before allowing Hermes to continue. Approvals are never granted by voice.")
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
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Hold \(model.hotkeyLabel) to talk")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
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
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 2)
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

private struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

private extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
