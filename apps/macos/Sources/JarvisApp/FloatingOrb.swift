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
        let hostingView = NSHostingView(rootView: FloatingOrbView(model: model).background(Color.clear))
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
            .combineLatest(model.$orbVisibility)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, visibility in
                self?.updateVisibility(snapshot: snapshot, visibility: visibility)
            }
            .store(in: &cancellables)
    }

    func start() {
        updateVisibility(snapshot: model.snapshot, visibility: model.orbVisibility)
    }

    private func updateVisibility(snapshot: VoiceSnapshot, visibility: OrbVisibility) {
        let shouldShow = visibility == .always || Self.isActiveRunState(snapshot.state)
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let rawTime = timeline.date.timeIntervalSinceReferenceDate
            let time = rawTime * (reduceMotion ? 0.12 : 1)
            let motion = OrbMotion(state: model.snapshot.state)
            let breath = CGFloat(1 + sin(time * motion.breathSpeed) * motion.breathAmount)

            ZStack {
                ambientBloom(time: time, motion: motion)
                plasmaBody(time: time, motion: motion)
                energyRings(time: time, motion: motion)
                glassHighlights(time: time, motion: motion)
            }
            .scaleEffect(breath)
            .frame(width: 176, height: 176)
            .mask {
                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: 0.67),
                                .init(color: .white.opacity(0.72), location: 0.82),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 88
                        )
                    )
            }
            .contentShape(Circle())
            .onTapGesture {
                model.toggleVoiceInteraction()
            }
            .animation(.easeInOut(duration: 0.65), value: model.snapshot.state)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("J.A.R.V.I.S. \(model.snapshot.state.rawValue)")
            .accessibilityAction {
                model.toggleVoiceInteraction()
            }
            .help("Click to start or stop listening · drag to reposition")
        }
    }

    private func ambientBloom(time: Double, motion: OrbMotion) -> some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: motion.palette + [motion.palette[0]],
                        center: .center,
                        angle: .degrees(time * motion.rotationSpeed * 0.38)
                    )
                )
                .frame(width: 126, height: 126)
                .blur(radius: 22)
                .opacity(motion.bloomOpacity * 0.78)

            ForEach(0..<min(4, motion.palette.count), id: \.self) { index in
                let angle = time * (index.isMultiple(of: 2) ? 0.32 : -0.27)
                    + Double(index) * Double.pi / 2
                Circle()
                    .fill(motion.palette[index].opacity(0.54))
                    .frame(width: 58, height: 58)
                    .offset(
                        x: CGFloat(cos(angle)) * 48,
                        y: CGFloat(sin(angle)) * 48
                    )
                    .blur(radius: 17)
                    .blendMode(.plusLighter)
            }
        }
    }

    private func plasmaBody(time: Double, motion: OrbMotion) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.93, green: 0.95, blue: 0.96),
                            Color(red: 0.72, green: 0.76, blue: 0.8),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 62
                    )
                )

            ForEach(0..<7, id: \.self) { index in
                plasmaLobe(index: index, time: time, motion: motion)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(0.86),
                            .white.opacity(0.82),
                            .white.opacity(0.64),
                            .white.opacity(0.12),
                            .clear,
                        ],
                        center: UnitPoint(x: 0.46, y: 0.44),
                        startRadius: 1,
                        endRadius: 42
                    )
                )
                .frame(width: 86, height: 86)
                .blur(radius: 2.5)
                .blendMode(.screen)

            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: motion.palette + [motion.palette[0]],
                        center: .center,
                        angle: .degrees(time * motion.rotationSpeed * 0.2)
                    ),
                    lineWidth: 8
                )
                .blur(radius: 7)
                .opacity(0.72)
                .blendMode(.screen)

            Circle()
                .strokeBorder(.white.opacity(0.42), lineWidth: 0.75)
        }
        .frame(width: 116, height: 116)
        .clipShape(Circle())
        .compositingGroup()
        .shadow(color: motion.palette[2].opacity(0.24), radius: 15, x: 4, y: 7)
        .shadow(color: motion.palette[0].opacity(0.18), radius: 13, x: -5, y: -4)
    }

    private func plasmaLobe(index: Int, time: Double, motion: OrbMotion) -> some View {
        let phase = Double(index) * 1.73
        let direction = index.isMultiple(of: 2) ? 1.0 : -1.0
        let angle = time * motion.plasmaSpeed * direction * (0.72 + Double(index) * 0.055) + phase
        let secondaryAngle = time * motion.plasmaSpeed * 0.47 - phase * 0.8
        let orbit = 28 + CGFloat(index % 3) * 4
        let x = CGFloat(cos(angle)) * orbit + CGFloat(sin(secondaryAngle)) * 8
        let y = CGFloat(sin(angle * 0.91)) * (orbit - 2) + CGFloat(cos(secondaryAngle)) * 7
        let diameter = CGFloat(54 + (index * 11) % 24)
        let color = motion.palette[index % motion.palette.count]

        return Circle()
            .fill(
                RadialGradient(
                    colors: [
                        color,
                        color.opacity(0.9),
                        color.opacity(0.42),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
            .offset(x: x, y: y)
            .blur(radius: 5)
            .blendMode(.normal)
    }

    private func energyRings(time: Double, motion: OrbMotion) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let ringSize = CGFloat(93 + index * 6)
                let phase = time * motion.waveSpeed + Double(index) * 2.17
                let ring = OrganicOrbRing(
                    phase: phase,
                    amplitude: motion.waveAmplitude + Double(index) * 0.65,
                    seed: index
                )

                ring
                    .stroke(
                        motion.palette[(index + 2) % motion.palette.count].opacity(0.28),
                        style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: ringSize, height: ringSize)
                    .blur(radius: 4)
                    .blendMode(.plusLighter)

                ring
                    .stroke(
                        AngularGradient(
                            colors: [
                                .white.opacity(0.9),
                                motion.palette[2].opacity(0.62),
                                .white.opacity(0.44),
                                motion.palette[0].opacity(0.52),
                                .white.opacity(0.9),
                            ],
                            center: .center,
                            angle: .degrees(time * motion.rotationSpeed * 0.24 + Double(index) * 37)
                        ),
                        style: StrokeStyle(
                            lineWidth: index == 0 ? 1.05 : 0.72,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .frame(width: ringSize, height: ringSize)
                    .opacity(0.82 - Double(index) * 0.12)
                    .blendMode(.screen)
            }
        }
    }

    private func glassHighlights(time: Double, motion: OrbMotion) -> some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.7), .white.opacity(0.05)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 43, height: 6)
                .rotationEffect(.degrees(-31))
                .offset(x: -22, y: -34)
                .blur(radius: 1.4)
                .blendMode(.screen)

            Circle()
                .fill(.white.opacity(0.86))
                .frame(width: 5, height: 5)
                .offset(x: -34, y: -24)
                .blur(radius: 0.7)
                .shadow(color: .white.opacity(0.8), radius: 4)

            Circle()
                .trim(from: 0.08, to: 0.31)
                .stroke(.white.opacity(0.32), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                .frame(width: 111, height: 111)
                .rotationEffect(.degrees(time * motion.rotationSpeed * 0.08 - 18))
                .blendMode(.screen)
        }
    }
}

private struct OrbMotion {
    let palette: [Color]
    let rotationSpeed: Double
    let plasmaSpeed: Double
    let waveSpeed: Double
    let waveAmplitude: Double
    let breathSpeed: Double
    let breathAmount: Double
    let bloomOpacity: Double

    init(state: VoiceState) {
        switch state {
        case .listening:
            palette = [Self.cyan, Self.azure, Self.mint, Self.ice]
            rotationSpeed = 32
            plasmaSpeed = 1.45
            waveSpeed = 3.0
            waveAmplitude = 4.2
            breathSpeed = 4.6
            breathAmount = 0.032
            bloomOpacity = 0.72
        case .speaking:
            palette = [Self.violet, Self.magenta, Self.cyan, Self.coral]
            rotationSpeed = 27
            plasmaSpeed = 1.25
            waveSpeed = 2.7
            waveAmplitude = 4.7
            breathSpeed = 3.7
            breathAmount = 0.038
            bloomOpacity = 0.76
        case .approval:
            palette = [Self.amber, Self.coral, Self.magenta, Self.gold]
            rotationSpeed = 20
            plasmaSpeed = 0.9
            waveSpeed = 2.0
            waveAmplitude = 5.1
            breathSpeed = 2.7
            breathAmount = 0.045
            bloomOpacity = 0.78
        case .error, .degraded:
            palette = [Self.coral, Self.red, Self.magenta, Self.amber]
            rotationSpeed = 12
            plasmaSpeed = 0.65
            waveSpeed = 1.35
            waveAmplitude = 3.5
            breathSpeed = 2.0
            breathAmount = 0.025
            bloomOpacity = 0.62
        case .idle, .starting:
            palette = [Self.amber, Self.coral, Self.cyan, Self.mint]
            rotationSpeed = 14
            plasmaSpeed = 0.58
            waveSpeed = 1.25
            waveAmplitude = 2.8
            breathSpeed = 1.8
            breathAmount = 0.018
            bloomOpacity = 0.58
        case .transcribing, .thinking, .tool, .interrupting:
            palette = [Self.amber, Self.coral, Self.cyan, Self.mint, Self.violet]
            rotationSpeed = 24
            plasmaSpeed = 1.08
            waveSpeed = 2.35
            waveAmplitude = 4.25
            breathSpeed = 3.2
            breathAmount = 0.032
            bloomOpacity = 0.72
        }
    }

    private static let amber = Color(red: 0.97, green: 0.67, blue: 0.23)
    private static let gold = Color(red: 1.00, green: 0.83, blue: 0.35)
    private static let coral = Color(red: 0.98, green: 0.31, blue: 0.25)
    private static let red = Color(red: 0.92, green: 0.12, blue: 0.18)
    private static let magenta = Color(red: 0.89, green: 0.26, blue: 0.66)
    private static let violet = Color(red: 0.43, green: 0.34, blue: 0.96)
    private static let cyan = Color(red: 0.04, green: 0.79, blue: 0.91)
    private static let azure = Color(red: 0.12, green: 0.48, blue: 0.98)
    private static let ice = Color(red: 0.55, green: 0.92, blue: 1.00)
    private static let mint = Color(red: 0.48, green: 0.89, blue: 0.68)
}

private struct OrganicOrbRing: Shape {
    let phase: Double
    let amplitude: Double
    let seed: Int

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let baseRadius = min(rect.width, rect.height) / 2 - CGFloat(amplitude) - 2
        let steps = 220
        var path = Path()

        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let angle = progress * Double.pi * 2
            let seedPhase = Double(seed) * 0.91
            let first = sin(angle * Double(5 + seed) + phase + seedPhase) * amplitude
            let second = sin(angle * Double(9 + seed * 2) - phase * 0.67) * amplitude * 0.34
            let third = cos(angle * Double(3 + seed) + phase * 0.31) * amplitude * 0.2
            let radius = baseRadius + CGFloat(first + second + third)
            let point = CGPoint(
                x: center.x + CGFloat(cos(angle)) * radius,
                y: center.y + CGFloat(sin(angle)) * radius
            )
            if step == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}
