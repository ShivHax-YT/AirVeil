import AppKit
import SwiftUI

enum NotchTutorialStep: Int, CaseIterable {
    case tracking, center, light, controls
    var title: String {
        switch self {
        case .tracking: return "Your head guides the screen"
        case .center: return "Find your center"
        case .light: return "A little light, when needed"
        case .controls: return "You're always in control"
        }
    }
    var detail: String {
        switch self {
        case .tracking: return "AirPods track your head's turn, not your eyes. After centering, turning left covers the right side; turning right covers the left. Invert direction swaps the sides."
        case .center: return "Look straight at the built-in camera, within 5°, and hold briefly. The rail helps you line up. A green smile confirms the check; AirPods then follow your turns."
        case .light: return "When a visible face is too dark to read, a soft, rounded frame lights the display edges. It turns off when the check ends. You can turn Face light off in the notch controls."
        case .controls: return "Hover here for Set center, Enable blur, and Pause. If tracking stops, blur clears; use Refresh direction to retry. Clicking elsewhere keeps this tour open. Only End tutorial finishes it."
        }
    }
}

@MainActor final class NotchOverlayPresentation: ObservableObject {
    @Published var snapshot = NotchCoachSnapshot()
    @Published var expanded = false
    @Published var controls = false
    @Published var demo = false
    @Published var tutorialStep: NotchTutorialStep?
    var endTutorial: () -> Void = {}
    @Published var topInset: CGFloat = 32
    @Published var hardwareWidth: CGFloat = 180
    @Published var canCenter = false
    @Published var cameraEnabled = false
    @Published var enabled = false
    @Published var hovering = false
    /// Deterministic visual-fixture time; nil for every live presentation.
    var animationTime: Double?
    var revealProgress: CGFloat?
    var center: () -> Void = {}
    var refresh: () -> Void = {}
    var cancel: () -> Void = {}
    var settings: () -> Void = {}
    var toggleEffect: () -> Void = {}
    var toggleAssistLight: () -> Void = {}
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
    var contentWidth: CGFloat { tutorialStep != nil || controls ? 360 : min(248, max(212, hardwareWidth + 32)) }
    var contentHeight: CGFloat {
        if tutorialStep != nil { return 360 }
        if controls { return 118 }
        switch snapshot.phase {
        case .success: return 154
        case .lighting: return 190
        case .failure: return 218
        default: return 190
        }
    }
}

/// A fixed hardware stem and a growing rounded body. The mask changes shape;
/// camera pixels and the glyph are never squashed to simulate an opening.
struct NotchCanopy: Shape {
    var hardwareWidth: CGFloat
    var topInset: CGFloat
    var bodyWidth: CGFloat = 360
    var bodyHeight: CGFloat = 190
    var reveal: CGFloat = 1
    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(reveal, .init(bodyWidth, bodyHeight)) }
        set { reveal = newValue.first; bodyWidth = newValue.second.first; bodyHeight = newValue.second.second }
    }
    func path(in rect: CGRect) -> Path {
        let amount = min(1, max(0, reveal))
        let width = min(rect.width, hardwareWidth + (bodyWidth - hardwareWidth) * amount)
        let height = max(0, bodyHeight * amount)
        let left = rect.midX - width / 2, right = rect.midX + width / 2
        let bottom = topInset + height
        let r = min(28, height / 2, width / 4)
        guard topInset > 0 else {
            return Path(roundedRect: CGRect(x: left, y: 0, width: width, height: height), cornerRadius: r)
        }
        let stemLeft = rect.midX - hardwareWidth / 2, stemRight = rect.midX + hardwareWidth / 2
        let shoulder = min(7, max(0, (width - hardwareWidth) / 4))
        var path = Path()
        path.move(to: CGPoint(x: stemLeft, y: 0))
        path.addLine(to: CGPoint(x: stemRight, y: 0))
        path.addLine(to: CGPoint(x: stemRight, y: topInset - shoulder))
        path.addQuadCurve(to: CGPoint(x: stemRight + shoulder, y: topInset), control: CGPoint(x: stemRight, y: topInset))
        path.addLine(to: CGPoint(x: right - min(r, shoulder), y: topInset))
        path.addQuadCurve(to: CGPoint(x: right, y: topInset + min(r, shoulder)), control: CGPoint(x: right, y: topInset))
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: topInset + min(r, shoulder)))
        path.addQuadCurve(to: CGPoint(x: left + min(r, shoulder), y: topInset), control: CGPoint(x: left, y: topInset))
        path.addLine(to: CGPoint(x: stemLeft - shoulder, y: topInset))
        path.addQuadCurve(to: CGPoint(x: stemLeft, y: topInset - shoulder), control: CGPoint(x: stemLeft, y: topInset))
        path.closeSubpath()
        return path
    }
}

@MainActor struct NotchCoachView: View {
    @ObservedObject var presentation: NotchOverlayPresentation
    @ObservedObject var camera: CameraAnchorService
    let headMotion: NotchMotionFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var successStarted = Date()
    private var snapshot: NotchCoachSnapshot { presentation.snapshot }
    private var success: Bool { snapshot.phase == .success }
    private var accent: Color {
        if success || snapshot.phase == .holding { return .init(red: 0.34, green: 0.82, blue: 0.46) }
        if snapshot.phase == .lighting || snapshot.phase == .failure { return .init(red: 1, green: 0.77, blue: 0.43) }
        if snapshot.phase == .offCenter { return .init(red: 1, green: 0.43, blue: 0.43) }
        return .init(red: 0.78, green: 0.83, blue: 0.90)
    }
    private var expansion: Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : .timingCurve(0.22, 0.80, 0.24, 1, duration: 0.46)
    }
    private var morph: Animation {
        reduceMotion ? .easeInOut(duration: 0.16) : .spring(response: 0.40, dampingFraction: 0.9)
    }
    private var shape: NotchCanopy {
        .init(hardwareWidth: presentation.hardwareWidth, topInset: presentation.topInset,
              bodyWidth: presentation.contentWidth, bodyHeight: presentation.contentHeight,
              reveal: presentation.revealProgress ?? (reduceMotion || presentation.expanded ? 1 : 0))
    }
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: presentation.topInset)
            ZStack {
                if let step = presentation.tutorialStep { tutorial(step).transition(.opacity) }
                else if presentation.controls { controls.transition(.opacity) }
                else if success { successContent.transition(.opacity) }
                else if snapshot.phase == .lighting { lightingContent.transition(.opacity) }
                else { coachContent.transition(.opacity) }
            }
            .frame(width: presentation.contentWidth, height: presentation.contentHeight, alignment: .top)
            .overlay(alignment: .topTrailing) {
                if presentation.tutorialStep == nil, !presentation.controls, !success {
                    actions.opacity(presentation.hovering || snapshot.isAssistLightOn ? 1 : 0)
                        .animation(.easeInOut(duration: 0.16), value: presentation.hovering)
                        .padding(.trailing, 9).padding(.top, 5)
                }
            }
            .opacity(presentation.expanded ? 1 : 0)
            .offset(y: presentation.expanded || reduceMotion ? 0 : -12)
            .animation(expansion.delay(presentation.expanded && !reduceMotion ? 0.06 : 0), value: presentation.expanded)
            Spacer(minLength: 0)
        }
        .frame(width: 360, height: presentation.topInset + 380, alignment: .top)
        .background { shape.fill(.black) }
        .clipShape(shape)
        .opacity(reduceMotion && !presentation.expanded ? 0 : 1)
        .animation(expansion, value: presentation.expanded)
        .animation(morph, value: presentation.contentHeight)
        .animation(morph, value: presentation.contentWidth)
        .animation(.easeInOut(duration: reduceMotion ? 0.16 : 0.22), value: snapshot.phase)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onAppear { presentation.contentHeightChanged(presentation.contentHeight); successStarted = Date() }
        .onChange(of: presentation.contentHeight) { _, height in presentation.contentHeightChanged(height) }
        .onChange(of: success) { _, accepted in if accepted { successStarted = Date() } }
        .accessibilityAction(named: Text("Cancel check"), presentation.cancel)
        .accessibilityAction(named: Text("Open settings"), presentation.settings)
    }
    private func tutorial(_ step: NotchTutorialStep) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("NOTCH TOUR · \(step.rawValue + 1) OF 4")
                    .font(.system(size: 10, weight: .semibold)).tracking(1)
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Image(systemName: "sparkle").foregroundStyle(.blue)
            }
            ZStack {
                if step == .light {
                    RoundedRectangle(cornerRadius: 23)
                        .stroke(.white.opacity(0.32), lineWidth: 12).blur(radius: 8)
                    RoundedRectangle(cornerRadius: 23)
                        .stroke(.white, lineWidth: 7)
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 34, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.65))
                } else if step == .center {
                    NotchSuccessGlyph(elapsed: 1).padding(10)
                } else {
                    Image(systemName: step == .tracking ? "airpodspro" : "hand.raised")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(Color(red: 0.45, green: 0.7, blue: 1))
                }
            }.frame(width: 130, height: 74).padding(.top, 2).accessibilityHidden(true)
            Text(step.title).font(.system(size: 18, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(step.detail).font(.system(size: 12)).lineSpacing(3)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Text(camera.isRunning ? "Camera check running · tour stays open" : "Illustration · camera stays off for this tour")
                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 8) {
                Button("Back") {
                    presentation.tutorialStep = NotchTutorialStep(rawValue: step.rawValue - 1)
                }.disabled(step == .tracking).frame(minWidth: 48, minHeight: 44)
                Button("Next") {
                    presentation.tutorialStep = NotchTutorialStep(rawValue: step.rawValue + 1)
                }.disabled(step == .controls).frame(minWidth: 48, minHeight: 44)
                Spacer(minLength: 0)
                Button("End tutorial", action: presentation.endTutorial)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 112, minHeight: 44)
                    .background(Color.blue, in: Capsule())
            }.buttonStyle(.plain)
        }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notch tutorial, step \(step.rawValue + 1) of 4")
    }
    private var coachContent: some View {
        VStack(spacing: 10) {
            CameraCircle(camera: camera, accent: accent, demo: presentation.demo,
                         horizontalError: snapshot.horizontalError, progress: snapshot.progress)
                .frame(width: 112, height: 112)
                .padding(.top, 14)
            NotchHeadMotionRail(feedback: headMotion, demoError: presentation.demo ? snapshot.horizontalError : nil,
                                isDemo: presentation.demo, accent: accent)
                .frame(width: presentation.contentWidth - 42)
            if snapshot.phase == .failure {
                Button("Try again", action: presentation.refresh)
                    .font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(.white.opacity(0.12), in: Capsule())
                    .help(snapshot.title + ". " + snapshot.detail)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(snapshot.title + ". " + snapshot.detail)
        .help(snapshot.title + ". " + snapshot.detail)
    }
    private var lightingContent: some View {
        VStack(spacing: 12) {
            Button(action: presentation.demo ? {} : presentation.toggleAssistLight) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15).stroke(accent.opacity(0.16), lineWidth: 14).blur(radius: 6)
                    RoundedRectangle(cornerRadius: 15).stroke(accent.opacity(0.9), lineWidth: 3)
                    VStack(spacing: 8) {
                        Image(systemName: "power").font(.system(size: 24, weight: .medium))
                        Text(snapshot.isAssistLightOn ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.8)
                    }
                    .foregroundStyle(snapshot.isAssistLightOn ? accent : .white.opacity(0.75))
                }
                .frame(width: 128, height: 87).contentShape(RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain).padding(.top, 29)
            .accessibilityLabel("Face light")
            .accessibilityValue(snapshot.isAssistLightOn ? "On" : "Off")
            .accessibilityHint(presentation.demo ? "Visual preview only. The light stays off." : "Lights the edge of your display to help the camera see your face.")
            VStack(spacing: 4) {
                Text("Light too low").font(.system(size: 12, weight: .medium))
                Text(presentation.demo ? "Preview · light stays off" : "Tap to turn on Face light")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .accessibilityElement(children: .contain)
    }
    private var successContent: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || presentation.animationTime != nil)) { context in
            let elapsed = reduceMotion ? 1 : (presentation.animationTime ?? max(0, context.date.timeIntervalSince(successStarted)))
            NotchSuccessGlyph(elapsed: elapsed)
                .frame(width: 104, height: 104)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.demo ? "Animation preview complete. Camera stayed off." : snapshot.title)
    }
    private var actions: some View {
        Menu {
            if snapshot.phase == .failure { Button("Try again", action: presentation.refresh) }
            if snapshot.isAssistLightOn { Button("Turn Face light off", action: presentation.toggleAssistLight) }
            Button("Cancel check", action: presentation.cancel)
            Button("Settings…", action: presentation.settings)
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize().help("Check controls").accessibilityLabel("Check controls")
    }
    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.white.opacity(0.7))
                Text("AirVeil").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(presentation.enabled ? "Following your head" : "Blur paused")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.48))
                Button(action: presentation.settings) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(NotchTextButton()).help("Settings")
                    .accessibilityLabel("Open AirVeil settings")
            }
            HStack(spacing: 10) {
                Button(action: presentation.center) {
                    Text(presentation.cameraEnabled ? "Set center" : "Set up camera")
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 32)
                }
                .buttonStyle(.plain).background(.white.opacity(0.14), in: Capsule())
                .disabled(presentation.cameraEnabled && !presentation.canCenter)
                Button(presentation.enabled ? "Pause" : "Enable blur", action: presentation.toggleEffect)
                    .buttonStyle(NotchTextButton())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }
}

private struct NotchTextButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.65))
            .padding(.vertical, 6).padding(.horizontal, 4).contentShape(Rectangle())
    }
}

@MainActor private struct CameraCircle: View {
    @ObservedObject var camera: CameraAnchorService
    var accent: Color
    var demo: Bool
    var horizontalError: Double
    var progress: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle().fill(Color(white: 0.045))
                if let image = camera.previewImage, !demo {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width - 8, height: geometry.size.height - 8)
                        .scaleEffect(x: -1, y: 1).clipShape(Circle())
                } else {
                    Image(systemName: demo ? "person.crop.circle" : "camera")
                        .font(.system(size: demo ? 53 : 27, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.3))
                        .offset(x: demo ? horizontalError * 16 : 0)
                }
                Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1).padding(3)
                ForEach(0..<4) { segment in
                    Circle().trim(from: 0.04, to: 0.21)
                        .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(Double(segment) * 90))
                }
                if progress > 0 {
                    Circle().trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityLabel(demo ? "Simulated preview, camera off" : "Mirrored camera preview")
    }
}

/// Reference-proportioned face, with a short projected-loop transition. Its
/// input is elapsed presentation time; it has no access to sensor acceptance.
struct NotchSuccessGlyph: View {
    var elapsed: Double
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.46
            let progress = min(1, max(0, elapsed / 0.66))
            let face = min(1, max(0, (progress - 0.78) / 0.22))
            let swirl = sin(progress * .pi)
            let green = Color(red: 0.34, green: 0.82, blue: 0.46)
            let thickness = side * (0.037 + 0.017 * face)
            for loop in 0..<3 {
                let angle = Double(loop) * 2 * .pi / 3
                let yaw = swirl * (0.65 + Double(loop) * 0.18)
                let roll = progress * 2 * .pi + angle
                var path = Path()
                for point in 0...120 {
                    let phi = Double(point) / 120 * 2 * .pi
                    let x = cos(phi), y = sin(phi)
                    let compressedX = x * cos(yaw)
                    let twistedY = y * cos(swirl * 0.72) - x * sin(yaw) * sin(swirl * 0.72)
                    let projected = CGPoint(x: center.x + radius * (compressedX * cos(roll) - twistedY * sin(roll)),
                                            y: center.y + radius * (compressedX * sin(roll) + twistedY * cos(roll)))
                    if point == 0 { path.move(to: projected) } else { path.addLine(to: projected) }
                }
                context.stroke(path, with: .color(green.opacity(loop == 2 ? 1 : (1 - face) * 0.35)),
                               style: StrokeStyle(lineWidth: thickness, lineCap: .round, lineJoin: .round))
            }
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: center.x + side * (x - 0.5), y: center.y + side * (y - 0.5))
            }
            var features = Path()
            features.move(to: point(0.30, 0.365)); features.addLine(to: point(0.30, 0.445))
            features.move(to: point(0.70, 0.365)); features.addLine(to: point(0.70, 0.445))
            features.move(to: point(0.51, 0.365)); features.addLine(to: point(0.51, 0.555))
            features.addQuadCurve(to: point(0.455, 0.605), control: point(0.51, 0.605))
            features.move(to: point(0.33, 0.725))
            features.addQuadCurve(to: point(0.67, 0.725), control: point(0.50, 0.865))
            context.stroke(features, with: .color(green.opacity(face)),
                           style: StrokeStyle(lineWidth: side * 0.056, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

@MainActor private struct NotchHeadMotionRail: View {
    @ObservedObject var feedback: NotchMotionFeedback
    var demoError: Double?
    var isDemo: Bool
    var accent: Color
    private var pose: NotchPoseSnapshot { feedback.snapshot }
    private var label: String {
        if isDemo { return "Head movement preview" }
        switch pose.source {
        case .waiting: return "Finding your direction"
        case .airPods: return "AirPods · waiting for camera"
        case .camera: return "Camera · aim within 5°"
        case .cameraAndAirPods: return "Camera + AirPods · aim within 5°"
        }
    }
    private var value: String {
        if isDemo { return "Preview · camera off" }
        guard let angle = pose.yawDegrees else { return "Aim within 5°" }
        let magnitude = Int(abs(angle).rounded())
        if !pose.directionKnown { return "\(magnitude)° from center" }
        if magnitude == 0 { return "Facing center" }
        return "\(magnitude)° \(angle > 0 ? "left" : "right")"
    }
    private var tint: Color {
        guard !isDemo, pose.isScreenRelative, let angle = pose.yawDegrees else { return accent }
        guard pose.source != .airPods else { return accent }
        return abs(angle) <= HeadingFusionEngine.centerYawToleranceDegrees
            ? Color(red: 0.34, green: 0.82, blue: 0.46) : Color(red: 1, green: 0.43, blue: 0.43)
    }
    var body: some View {
        VStack(spacing: 5) {
            AlignmentRail(error: isDemo ? demoError : pose.normalizedYaw,
                          symmetric: !isDemo && !pose.directionKnown, accent: tint)
                .frame(height: 24)
            Text(value).monospacedDigit().font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label).accessibilityValue(value)
    }
}

private struct AlignmentRail: View {
    var error: Double?
    var symmetric = false
    var accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geo in
            let width = min(196, geo.size.width)
            let selected = error.map { Int((min(1, max(-1, $0)) * 15).rounded()) }
            ZStack {
                ForEach(-15...15, id: \.self) { index in
                    let highlighted = selected.map { abs(index - $0) <= 1 || (symmetric && abs(index + $0) <= 1) } ?? false
                    Capsule().fill(highlighted ? accent : .white.opacity(index == 0 ? 0.50 : 0.20))
                        .frame(width: index == 0 ? 2 : 1.5, height: highlighted ? 11 : (index == 0 ? 9 : 5))
                        .rotationEffect(.degrees(Double(index) * 1.4))
                        .position(x: geo.size.width / 2 + CGFloat(index) * width / 30,
                                  y: 12 - pow(CGFloat(index) / 15, 2) * 9)
                }
                if let error {
                    Circle().fill(accent).frame(width: 3, height: 3)
                        .position(x: geo.size.width / 2 + min(1, max(-1, error)) * width / 2, y: 23)
                    if symmetric {
                        Circle().fill(accent).frame(width: 3, height: 3)
                            .position(x: geo.size.width / 2 - min(1, max(-1, error)) * width / 2, y: 23)
                    }
                }
            }
        }
        .animation(reduceMotion ? .none : .linear(duration: 0.04), value: error)
        .accessibilityHidden(true)
    }
}
