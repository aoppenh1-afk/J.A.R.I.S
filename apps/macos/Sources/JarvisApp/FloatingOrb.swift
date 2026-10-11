import AppKit
import Combine
import JarvisCore
import SwiftUI

@MainActor
final class FloatingOrbWindowController {
    private let model: AppModel
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 176, height: 176),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(rootView: FloatingOrbView(model: model, onDrag: { [weak self] delta in
            self?.movePanel(by: delta)
        }).background(Color.clear))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        panel.contentView = hostingView

        let restoredFrame = panel.setFrameUsingName("JarvisFloatingOrb")
        panel.setContentSize(NSSize(width: 176, height: 176))
        if !restoredFrame {
            positionNearBottomTrailingEdge()
        }
        panel.setFrameAutosaveName("JarvisFloatingOrb")

        model.$snapshot
            .combineLatest(model.$orbVisibility, model.$isVoiceInteraction)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, visibility, isVoiceInteraction in
                self?.resizePanel(for: snapshot)
                self?.updateVisibility(
                    snapshot: snapshot,
                    visibility: visibility,
                    isVoiceInteraction: isVoiceInteraction
                )
            }
            .store(in: &cancellables)
    }

    func start() {
        updateVisibility(
            snapshot: model.snapshot,
            visibility: model.orbVisibility,
            isVoiceInteraction: model.isVoiceInteraction
        )
    }

    func movePanel(by delta: CGSize) {
        guard delta != .zero else { return }
        var origin = panel.frame.origin
        origin.x += delta.width
        origin.y -= delta.height
        if let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let size = panel.frame.size
            let grabHeight: CGFloat = 48
            origin.x = min(max(origin.x, visibleFrame.minX - size.width + grabHeight), visibleFrame.maxX - grabHeight)
            origin.y = min(max(origin.y, visibleFrame.minY - size.height + grabHeight), visibleFrame.maxY - grabHeight)
        }
        panel.setFrameOrigin(origin)
    }

    private func resizePanel(for snapshot: VoiceSnapshot) {
        let expanded = snapshot.state == .speaking || snapshot.state == .approval || snapshot.state == .error || snapshot.state == .degraded
        let target = expanded ? NSSize(width: 560, height: 220) : NSSize(width: 176, height: 176)
        guard panel.contentLayoutRect.size != target else { return }

        let oldFrame = panel.frame
        var newOrigin = NSPoint(
            x: oldFrame.midX - target.width / 2,
            y: oldFrame.midY - target.height / 2
        )

        if let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame {
            let edgeThreshold: CGFloat = 96
            let minimumInset: CGFloat = 16
            let leftGap = oldFrame.minX - visibleFrame.minX
            let rightGap = visibleFrame.maxX - oldFrame.maxX
            let bottomGap = oldFrame.minY - visibleFrame.minY
            let topGap = visibleFrame.maxY - oldFrame.maxY

            if rightGap >= 0, rightGap <= edgeThreshold {
                newOrigin.x = visibleFrame.maxX - target.width - max(minimumInset, rightGap)
            } else if leftGap >= 0, leftGap <= edgeThreshold {
                newOrigin.x = visibleFrame.minX + max(minimumInset, leftGap)
            }

            if bottomGap >= 0, bottomGap <= edgeThreshold {
                newOrigin.y = visibleFrame.minY + max(minimumInset, bottomGap)
            } else if topGap >= 0, topGap <= edgeThreshold {
                newOrigin.y = visibleFrame.maxY - target.height - max(minimumInset, topGap)
            }

            newOrigin.x = min(
                max(newOrigin.x, visibleFrame.minX + minimumInset),
                visibleFrame.maxX - target.width - minimumInset
            )
            newOrigin.y = min(
                max(newOrigin.y, visibleFrame.minY + minimumInset),
                visibleFrame.maxY - target.height - minimumInset
            )
        }

        panel.setFrame(NSRect(origin: newOrigin, size: target), display: true, animate: true)
    }

    private func updateVisibility(
        snapshot: VoiceSnapshot,
        visibility: OrbVisibility,
        isVoiceInteraction: Bool
    ) {
        let shouldShow = visibility == .always || (isVoiceInteraction && Self.isActiveRunState(snapshot.state))
        if model.isFloatingOrbVisible != shouldShow {
            model.isFloatingOrbVisible = shouldShow
        }
        guard panel.isVisible != shouldShow else { return }
        if shouldShow {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func positionNearBottomTrailingEdge() {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let visibleFrame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frame.width - 24,
            y: visibleFrame.minY + 24
        ))
    }

    private static func isActiveRunState(_ state: VoiceState) -> Bool {
        switch state {
        case .listening, .transcribing, .thinking, .tool, .approval, .speaking, .interrupting:
            true
        case .starting, .idle, .degraded, .error:
            false
        }
    }
}

private struct FloatingOrbView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastDragTranslation: CGSize = .zero
    let onDrag: (CGSize) -> Void

    private var framesPerSecond: Int {
        model.animationQuality.framesPerSecond(
            isActive: model.snapshot.state != .idle,
            lowPowerMode: model.lowPowerMode,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        Group {
            if model.isFloatingOrbVisible {
                ExactGlassVoiceOrb(
                    state: model.snapshot.state,
                    assistantText: model.snapshot.assistantText,
                    statusText: model.snapshot.statusText,
                    framesPerSecond: framesPerSecond
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let translation = CGSize(width: value.translation.width, height: value.translation.height)
                    let delta = CGSize(
                        width: translation.width - lastDragTranslation.width,
                        height: translation.height - lastDragTranslation.height
                    )
                    lastDragTranslation = translation
                    onDrag(delta)
                }
                .onEnded { _ in
                    lastDragTranslation = .zero
                }
        )
        .onTapGesture {
            model.toggleVoiceInteraction()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("J.A.R.V.I.S. Liquid Glass voice orb")
        .accessibilityAction {
            model.toggleVoiceInteraction()
        }
        .help("Click to start or stop listening · drag to reposition")
    }
}
