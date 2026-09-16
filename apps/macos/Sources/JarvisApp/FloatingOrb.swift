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
    @State private var shuffleReferenceTime = Date.now.timeIntervalSinceReferenceDate
    @State private var lastDragTranslation: CGSize = .zero
    let onDrag: (CGSize) -> Void

    var body: some View {
        let style = VoiceOrbStyle.resolve(
            preferred: model.voiceOrbStyle,
            shuffle: model.shuffleVoiceOrbs,
            enabled: model.shuffledVoiceOrbStyles,
            at: shuffleReferenceTime,
            reduceMotion: reduceMotion
        )

        Group {
            if style == .glass {
                // The WebGL orb owns its requestAnimationFrame loop. Keeping it out
                // of SwiftUI's TimelineView avoids a competing 60 Hz invalidation
                // cycle and mirrors the upstream single-clock architecture.
                ExactGlassVoiceOrb(
                    state: model.snapshot.state,
                    assistantText: model.snapshot.assistantText,
                    statusText: model.snapshot.statusText
                )
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                    let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                    VoiceOrbArtwork(
                        style: style,
                        state: model.snapshot.state,
                        time: time,
                        assistantText: model.snapshot.assistantText,
                        statusText: model.snapshot.statusText
                    )
                }
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
        .accessibilityLabel("J.A.R.V.I.S. \(style.displayName) voice orb")
        .accessibilityAction {
            model.toggleVoiceInteraction()
        }
        .help("Click to start or stop listening · drag to reposition")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard model.shuffleVoiceOrbs, !reduceMotion else { continue }
                let now = Date.now.timeIntervalSinceReferenceDate
                if Int(now / 12) != Int(shuffleReferenceTime / 12) {
                    shuffleReferenceTime = now
                }
            }
        }
    }
}

extension VoiceOrbStyle {
    static func resolve(
        preferred: VoiceOrbStyle,
        shuffle: Bool,
        enabled: Set<VoiceOrbStyle>,
        at time: Double,
        reduceMotion: Bool
    ) -> VoiceOrbStyle {
        guard shuffle, !reduceMotion else { return preferred }
        let choices = allCases.filter(enabled.contains)
        guard !choices.isEmpty else { return preferred }
        return choices[Int(time / 12) % choices.count]
    }
}

struct VoiceOrbAnimatedPreview: View {
    let style: VoiceOrbStyle
    var state: VoiceState = .speaking

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if style == .glass {
            ExactGlassVoiceOrb(
                state: state,
                assistantText: "Here is the response.",
                statusText: "Speaking"
            )
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                VoiceOrbArtwork(
                    style: style,
                    state: state,
                    time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                    assistantText: "Here is the response.",
                    statusText: "Speaking"
                )
            }
        }
    }
}

struct VoiceOrbArtwork: View {
    let style: VoiceOrbStyle
    let state: VoiceState
    let time: Double
    let assistantText: String
    let statusText: String

    var body: some View {
        switch style {
        case .thinking:
            ThinkingOrbCanvas(
                mode: OrbAnimationMode.select(for: state, at: time, reduceMotion: time == 0),
                time: time
            )
        case .radial:
            RadialVoiceOrb(state: state, time: time)
        case .cloud:
            CloudVoiceOrb(state: state, time: time)
        case .glass:
            ExactGlassVoiceOrb(
                state: state,
                assistantText: assistantText,
                statusText: statusText
            )
        }
    }
}

/// A native SwiftUI port inspired by Thinking Orbs (MIT, Jakub Antalik).
/// The renderer intentionally draws only the animated orb, never a tile or label.
private struct ThinkingOrbCanvas: View {
    let mode: OrbAnimationMode
    let time: Double

    var body: some View {
        Canvas { context, size in
            let renderer = ThinkingOrbRenderer(size: size, time: time, mode: mode)
            renderer.draw(in: context)
        }
        .drawingGroup()
    }
}

/// Native SwiftUI interpretations of the MIT-licensed orb-ui radial and cloud themes.
/// They preserve the high-level motion language without embedding its WebGL implementation.
private struct RadialVoiceOrb: View {
    let state: VoiceState
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) * 0.78
            let energy = state.orbEnergy
            let pulse = 1 + sin(time * (1.3 + Double(energy))) * 0.018 + energy * 0.025

            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.92))
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(red: 0.02, green: 0.18, blue: 0.62),
                                Color(red: 0.23, green: 0.82, blue: 0.84),
                                Color(red: 0.84, green: 0.98, blue: 0.96),
                                Color(red: 0.01, green: 0.12, blue: 0.42),
                                Color(red: 0.35, green: 0.9, blue: 0.86),
                                Color(red: 0.02, green: 0.18, blue: 0.62),
                            ],
                            center: .center
                        )
                    )
                    .rotationEffect(.radians(time * (0.16 + Double(energy) * 0.1)))
                RadialMembraneShape(time: time, energy: energy)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.82), Color.cyan.opacity(0.35), .white.opacity(0.16)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: max(2, diameter * 0.045)
                    )
                    .padding(diameter * 0.065)
                    .blendMode(.screen)
                Circle()
                    .stroke(.white.opacity(0.16), lineWidth: 1)
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(pulse)
            .shadow(color: Color.cyan.opacity(0.18 + Double(energy) * 0.22), radius: diameter * 0.1)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .drawingGroup()
        }
    }
}

private struct RadialMembraneShape: Shape {
    let time: Double
    let energy: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0...120 {
            let angle = Double(index) / 120 * .pi * 2
            let wave = 0.035 * sin(angle * 3 + time * 1.34)
                + 0.02 * sin(angle * 5 - time * 0.91 + 1.4)
                + 0.012 * sin(angle * 7 + time * 0.63)
            let radius = baseRadius * (0.9 + wave * (1 + Double(energy) * 0.7))
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

private struct CloudVoiceOrb: View {
    let state: VoiceState
    let time: Double

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height) * 0.78
            let energy = state.orbEnergy
            let scale = 0.96 + energy * 0.055 + CGFloat(sin(time * 1.25)) * 0.012

            ZStack {
                Circle()
                    .fill(Color(red: 0.3, green: 0.33, blue: 0.92))
                cloudBlob(color: Color(red: 0.88, green: 0.93, blue: 1), phase: 0.2, size: 0.72)
                cloudBlob(color: Color(red: 0.57, green: 0.63, blue: 1), phase: 2.3, size: 0.84)
                cloudBlob(color: Color(red: 0.74, green: 0.82, blue: 1), phase: 4.2, size: 0.66)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .clear, Color.indigo.opacity(0.25)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .scaleEffect(scale)
            .shadow(color: Color.indigo.opacity(0.28), radius: diameter * 0.12)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .drawingGroup()
        }
    }

    private func cloudBlob(color: Color, phase: Double, size: CGFloat) -> some View {
        let energy = state.orbEnergy
        return Circle()
            .fill(color.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(size * (1 + energy * 0.12))
            .offset(
                x: CGFloat(cos(time * 0.42 + phase)) * 26,
                y: CGFloat(sin(time * 0.36 + phase * 1.3)) * 24
            )
            .blur(radius: 17)
            .blendMode(.screen)
    }
}



private extension VoiceState {
    var orbEnergy: CGFloat {
        switch self {
        case .listening, .transcribing: 0.72
        case .thinking, .tool, .approval: 0.52
        case .speaking: 1
        case .interrupting, .error, .degraded: 0.84
        case .starting: 0.34
        case .idle: 0.18
        }
    }
}

private enum OrbAnimationMode: CaseIterable {
    case orbits
    case globe
    case solving
    case listening
    case ribbon
    case shaping

    static func select(for state: VoiceState, at time: Double, reduceMotion: Bool) -> Self {
        let preferred: Self
        switch state {
        case .listening, .transcribing:
            preferred = .listening
        case .thinking, .tool:
            preferred = .orbits
        case .speaking:
            preferred = .ribbon
        case .approval:
            preferred = .solving
        case .interrupting, .error, .degraded:
            preferred = .shaping
        case .idle, .starting:
            preferred = .globe
        }

        guard !reduceMotion else { return preferred }
        let rotation = Int(time / 7.5)
        let preferredIndex = allCases.firstIndex(of: preferred) ?? 0
        return allCases[(preferredIndex + rotation) % allCases.count]
    }

    var accessibilityLabel: String {
        switch self {
        case .orbits: "working animation"
        case .globe: "searching animation"
        case .solving: "solving animation"
        case .listening: "listening animation"
        case .ribbon: "composing animation"
        case .shaping: "shaping animation"
        }
    }
}

private struct ThinkingOrbRenderer {
    let size: CGSize
    let time: Double
    let mode: OrbAnimationMode

    private var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    private var radius: CGFloat { min(size.width, size.height) * 0.39 }
    private var dotScale: CGFloat { max(0.7, radius / 54) }

    func draw(in context: GraphicsContext) {
        drawOrbBackground(in: context)

        switch mode {
        case .orbits:
            drawOrbits(in: context)
        case .globe:
            drawGlobe(in: context)
        case .solving:
            drawSolving(in: context)
        case .listening:
            drawListening(in: context)
        case .ribbon:
            drawRibbon(in: context)
        case .shaping:
            drawShaping(in: context)
        }
    }

    private func drawOrbBackground(in context: GraphicsContext) {
        // Keep the dark backing just beyond the particles so the dots—not a black disc—define the orb.
        let backgroundRadius = radius * 1.05
        let rect = CGRect(
            x: center.x - backgroundRadius,
            y: center.y - backgroundRadius,
            width: backgroundRadius * 2,
            height: backgroundRadius * 2
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .radialGradient(
                Gradient(colors: [Color(white: 0.075), Color.black.opacity(0.9)]),
                center: center,
                startRadius: 0,
                endRadius: backgroundRadius
            )
        )
        context.stroke(
            Path(ellipseIn: rect.insetBy(dx: 0.5, dy: 0.5)),
            with: .color(.white.opacity(0.07)),
            lineWidth: 1
        )
    }

    private func drawOrbits(in context: GraphicsContext) {
        var dots: [OrbDot] = []
        let projection = Projection(yaw: time * 0.12, tilt: 0.3, center: center, scale: 1)

        for orbit in 0..<12 {
            let h1 = hash(orbit, 1.7)
            let h2 = hash(orbit, 5.2)
            let h3 = hash(orbit, 8.9)
            let orbitRadius = radius * (0.45 + 0.52 * h1)
            let theta = h1 * .pi * 2
            let phi = acos(2 * h2 - 1)
            let normal = Vector3(
                x: sin(phi) * cos(theta),
                y: cos(phi),
                z: sin(phi) * sin(theta)
            )
            let u = Vector3(x: -normal.y, y: normal.x, z: 0).normalized
            let v = normal.cross(u)

            for step in 0..<40 {
                let angle = Double(step) / 40 * .pi * 2
                let point = u * cos(angle) + v * sin(angle)
                let projected = projection.project(point * orbitRadius)
                let depth = (projected.z / orbitRadius + 1) / 2
                dots.append(OrbDot(
                    point: projected.point,
                    z: projected.z,
                    radius: 0.8 * dotScale,
                    opacity: 0.16 + 0.32 * depth
                ))
            }

            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)
            for particle in 0..<3 {
                let angle = time * speed + Double(particle) / 3 * .pi * 2 + h2 * 6
                let projected = projection.project((u * cos(angle) + v * sin(angle)) * orbitRadius)
                let depth = (projected.z / orbitRadius + 1) / 2
                dots.append(OrbDot(
                    point: projected.point,
                    z: projected.z,
                    radius: (1.2 + 1.8 * depth) * dotScale,
                    opacity: 0.6 + 0.4 * depth
                ))
            }
        }
        paint(dots, in: context)
    }

    private func drawGlobe(in context: GraphicsContext) {
        var dots: [OrbDot] = []
        let spin = 0.5
        let projection = Projection(yaw: time * spin, tilt: 0.42 + 0.06 * sin(time * 0.35), center: center, scale: radius)
        let scan = time * 1.7

        for latitudeIndex in 0...17 {
            let latitude = -.pi / 2 + Double(latitudeIndex) / 17 * .pi
            let cosineLatitude = cos(latitude)
            let longitudeCount = max(1, Int((abs(cosineLatitude) * 44).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = Double(longitudeIndex) / Double(longitudeCount) * .pi * 2
                let projected = projection.project(Vector3(
                    x: cosineLatitude * cos(longitude),
                    y: sin(latitude),
                    z: cosineLatitude * sin(longitude)
                ))
                let depth = (projected.z + 1) / 2
                let delta = angularDistance(longitude + time * spin, scan)
                let scanBoost = exp(-(delta * delta) / 0.18) * max(0, projected.z)
                dots.append(OrbDot(
                    point: projected.point,
                    z: projected.z,
                    radius: (0.65 + 1.65 * depth + scanBoost) * dotScale,
                    opacity: 0.2 + 0.72 * depth + 0.08 * scanBoost
                ))
            }
        }
        paint(dots, in: context)
    }

    private func drawSolving(in context: GraphicsContext) {
        var dots: [OrbDot] = []
        let projection = Projection(yaw: time * 0.55, tilt: 0.38, center: center, scale: radius)
        let cycle = time.truncatingRemainder(dividingBy: 6.8)
        let scramble = cycle < 4.8 ? sin(cycle * .pi / 4.8) : 0

        for latitudeIndex in 0...15 {
            let latitude = -.pi / 2 + Double(latitudeIndex) / 15 * .pi
            let cosineLatitude = cos(latitude)
            let longitudeCount = max(1, Int((abs(cosineLatitude) * 40).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = Double(longitudeIndex) / Double(longitudeCount) * .pi * 2
                let band = Int((longitude / (.pi * 2)) * 4)
                let twist = scramble * (Double(band) - 1.5) * .pi / 5
                let angle = longitude + twist
                let projected = projection.project(Vector3(
                    x: cosineLatitude * cos(angle),
                    y: sin(latitude),
                    z: cosineLatitude * sin(angle)
                ))
                let depth = (projected.z + 1) / 2
                dots.append(OrbDot(
                    point: projected.point,
                    z: projected.z,
                    radius: (0.7 + 1.7 * depth) * dotScale,
                    opacity: 0.22 + 0.76 * depth
                ))
            }
        }
        paint(dots, in: context)
    }

    private func drawListening(in context: GraphicsContext) {
        var dots: [OrbDot] = []
        let projection = Projection(yaw: time * 0.18, tilt: 0.38, center: center, scale: 1)

        for ring in 0...15 {
            let latitude = -.pi / 2 + Double(ring) / 15 * .pi
            let cosineLatitude = cos(latitude)
            let wave = 0.62 * sin(time * 2.1 - Double(ring) * 0.52)
                + 0.38 * sin(time * 1.27 + Double(ring) * 0.83)
            let waveRadius = radius * (0.88 + 0.105 * wave)
            let longitudeCount = max(1, Int((abs(cosineLatitude) * 40).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = Double(longitudeIndex) / Double(longitudeCount) * .pi * 2
                let projected = projection.project(Vector3(
                    x: cosineLatitude * cos(longitude) * waveRadius,
                    y: sin(latitude) * waveRadius,
                    z: cosineLatitude * sin(longitude) * waveRadius
                ))
                let depth = (projected.z / radius + 1) / 2
                let crest = max(0, wave)
                dots.append(OrbDot(
                    point: projected.point,
                    z: projected.z,
                    radius: (0.7 + 1.6 * depth) * (1 + 0.35 * crest) * dotScale,
                    opacity: 0.24 + 0.72 * depth
                ))
            }
        }
        paint(dots, in: context)
    }

    private func drawRibbon(in context: GraphicsContext) {
        var dots: [OrbDot] = []
        let projection = Projection(yaw: 0, tilt: 0.3, center: center, scale: 1)

        for lane in 0..<14 {
            let laneOffset = (Double(lane) - 6.5) * 0.052
            let edge = abs(Double(lane) - 6.5) / 6.5
            for segment in 0..<88 {
                let angle = Double(segment) / 88 * .pi * 2
                let wobble = 0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                    + 0.07 * sin(angle * 5 + time * 1.1)
                let offset = laneOffset + wobble
                let unnormalized = Vector3(x: cos(angle), y: sin(angle), z: offset)
                let projected = projection.project(unnormalized.normalized * radius)
                let depth = (projected.z / radius + 1) / 2
                dots.append(OrbDot(
                    point: projected.point,
                    z: projected.z,
                    radius: (0.85 + 1.55 * depth) * (1 - 0.25 * edge) * dotScale,
                    opacity: 0.22 + 0.78 * depth
                ))
            }
        }
        paint(dots, in: context)
    }

    private func drawShaping(in context: GraphicsContext) {
        let cycleTime = time.truncatingRemainder(dividingBy: 6.9)
        let shapeIndex = min(2, Int(cycleTime / 2.3))
        let localTime = cycleTime.truncatingRemainder(dividingBy: 2.3)
        let transition = localTime <= 1.4 ? 0 : smoothstep((localTime - 1.4) / 0.9)
        let outlines = [ShapeOutline.circle, .triangle, .square]
        let from = outlines[shapeIndex]
        let to = outlines[(shapeIndex + 1) % outlines.count]
        let breath = 1 + 0.02 * sin(time * 3.1)
        var dots: [OrbDot] = []

        for index in 0..<46 {
            let progress = Double(index) / 46
            let a = from.point(at: progress)
            let b = to.point(at: progress)
            let point = CGPoint(
                x: center.x + (a.x + (b.x - a.x) * transition) * radius * 2 * breath,
                y: center.y + (a.y + (b.y - a.y) * transition) * radius * 2 * breath
            )
            dots.append(OrbDot(point: point, z: 0, radius: 1.55 * dotScale, opacity: 0.9))
        }
        paint(dots, in: context)
    }

    private func paint(_ dots: [OrbDot], in context: GraphicsContext) {
        for dot in dots.sorted(by: { $0.z < $1.z }) {
            let diameter = max(0.8, dot.radius * 2)
            let rect = CGRect(
                x: dot.point.x - diameter / 2,
                y: dot.point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(dot.opacity)))
        }
    }

    private func hash(_ first: Int, _ second: Double) -> Double {
        let value = sin(Double(first) * 12.9898 + second * 78.233) * 43_758.5453
        return value - floor(value)
    }

    private func angularDistance(_ first: Double, _ second: Double) -> Double {
        atan2(sin(first - second), cos(first - second))
    }

    private func smoothstep(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return clamped * clamped * (3 - 2 * clamped)
    }
}

private struct OrbDot {
    let point: CGPoint
    let z: Double
    let radius: CGFloat
    let opacity: Double
}

private struct Projection {
    let yaw: Double
    let tilt: Double
    let center: CGPoint
    let scale: CGFloat

    func project(_ vector: Vector3) -> (point: CGPoint, z: Double) {
        let yawedX = vector.x * cos(yaw) + vector.z * sin(yaw)
        let yawedZ = -vector.x * sin(yaw) + vector.z * cos(yaw)
        let tiltedY = vector.y * cos(tilt) - yawedZ * sin(tilt)
        let tiltedZ = vector.y * sin(tilt) + yawedZ * cos(tilt)
        return (
            point: CGPoint(
                x: center.x + yawedX * scale,
                y: center.y - tiltedY * scale
            ),
            z: tiltedZ
        )
    }
}

private struct Vector3 {
    let x: Double
    let y: Double
    let z: Double

    static func * (lhs: Vector3, rhs: Double) -> Vector3 {
        Vector3(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
    }

    static func + (lhs: Vector3, rhs: Vector3) -> Vector3 {
        Vector3(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    var normalized: Vector3 {
        let length = max(0.000_001, sqrt(x * x + y * y + z * z))
        return self * (1 / length)
    }

    func cross(_ other: Vector3) -> Vector3 {
        Vector3(
            x: y * other.z - z * other.y,
            y: z * other.x - x * other.z,
            z: x * other.y - y * other.x
        )
    }
}

private enum ShapeOutline {
    case circle
    case triangle
    case square

    func point(at progress: Double) -> CGPoint {
        switch self {
        case .circle:
            let angle = -.pi / 2 + progress * .pi * 2
            return CGPoint(x: cos(angle) * 0.24, y: sin(angle) * 0.24)
        case .triangle:
            return polygonPoint(
                vertices: [
                    CGPoint(x: 0, y: -0.26),
                    CGPoint(x: 0.24, y: 0.16),
                    CGPoint(x: -0.24, y: 0.16),
                ],
                progress: progress
            )
        case .square:
            return polygonPoint(
                vertices: [
                    CGPoint(x: 0, y: -0.2),
                    CGPoint(x: 0.2, y: -0.2),
                    CGPoint(x: 0.2, y: 0.2),
                    CGPoint(x: -0.2, y: 0.2),
                    CGPoint(x: -0.2, y: -0.2),
                ],
                progress: progress
            )
        }
    }

    private func polygonPoint(vertices: [CGPoint], progress: Double) -> CGPoint {
        let lengths = zip(vertices, vertices.dropFirst()).map { first, second in
            hypot(second.x - first.x, second.y - first.y)
        }
        let perimeter = lengths.reduce(0, +)
        var remaining = progress * perimeter
        for (index, length) in lengths.enumerated() {
            if remaining <= length {
                let fraction = remaining / length
                let first = vertices[index]
                let second = vertices[index + 1]
                return CGPoint(
                    x: first.x + (second.x - first.x) * fraction,
                    y: first.y + (second.y - first.y) * fraction
                )
            }
            remaining -= length
        }
        return vertices[0]
    }
}
