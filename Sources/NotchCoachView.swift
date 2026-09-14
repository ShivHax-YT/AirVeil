import AppKit
import SwiftUI

@MainActor final class NotchOverlayPresentation: ObservableObject {
    @Published var snapshot = NotchCoachSnapshot()
    @Published var expanded = false
    @Published var controls = false
    @Published var demo = false
    @Published var topInset: CGFloat = 32
    @Published var hardwareWidth: CGFloat = 180
    @Published var canCenter = false
    @Published var cameraEnabled = false
    @Published var enabled = false
    var center: () -> Void = {}
    var refresh: () -> Void = {}
    var cancel: () -> Void = {}
    var settings: () -> Void = {}
    var toggleEffect: () -> Void = {}
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
}

/// A hardware-width stem joins a wider canopy entirely below the menu bar.
struct NotchCanopy: Shape {
    var hardwareWidth: CGFloat
    var topInset: CGFloat
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 24
        guard topInset > 0 else { return Path(roundedRect: rect, cornerRadius: r) }
        let left = (rect.width - hardwareWidth) / 2
        let right = left + hardwareWidth
        var p = Path()
        p.move(to: CGPoint(x: left, y: 0))
        p.addLine(to: CGPoint(x: right, y: 0))
        p.addLine(to: CGPoint(x: right, y: topInset - 5))
        p.addQuadCurve(to: CGPoint(x: right + 5, y: topInset), control: CGPoint(x: right, y: topInset))
        p.addLine(to: CGPoint(x: rect.width - r, y: topInset))
        p.addQuadCurve(to: CGPoint(x: rect.width, y: topInset + r), control: CGPoint(x: rect.width, y: topInset))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        p.addQuadCurve(to: CGPoint(x: rect.width - r, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        p.addLine(to: CGPoint(x: r, y: rect.height))
        p.addQuadCurve(to: CGPoint(x: 0, y: rect.height - r), control: CGPoint(x: 0, y: rect.height))
        p.addLine(to: CGPoint(x: 0, y: topInset + r))
        p.addQuadCurve(to: CGPoint(x: r, y: topInset), control: CGPoint(x: 0, y: topInset))
        p.addLine(to: CGPoint(x: left - 5, y: topInset))
        p.addQuadCurve(to: CGPoint(x: left, y: topInset - 5), control: CGPoint(x: left, y: topInset))
        p.addLine(to: CGPoint(x: left, y: 0)); p.closeSubpath()
        return p
    }
}

@MainActor struct NotchCoachView: View {
    @ObservedObject var presentation: NotchOverlayPresentation
    @ObservedObject var camera: CameraAnchorService
    let headMotion: NotchMotionFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var snapshot: NotchCoachSnapshot { presentation.snapshot }
    private var success: Bool { snapshot.phase == .success }
    private var warning: Bool { snapshot.issue == .lowLight || snapshot.phase == .failure }
    private var accent: Color {
        if success || snapshot.phase == .holding { return Color(red: 0.42, green: 0.91, blue: 0.64) }
        if warning { return Color(red: 1, green: 0.74, blue: 0.39) }
        if snapshot.phase == .offCenter { return Color(red: 1, green: 0.43, blue: 0.43) }
        return Color(red: 0.78, green: 0.83, blue: 0.90)
    }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.30, dampingFraction: 0.88) }
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: presentation.topInset)
            if presentation.controls { controls }
            else if success { successContent }
            else { coachContent }
        }
        .frame(width: 360)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { presentation.contentHeightChanged(geometry.size.height - presentation.topInset) }
                    .onChange(of: geometry.size.height) { _, height in
                        presentation.contentHeightChanged(height - presentation.topInset)
                    }
            }
        }
        .background {
            NotchCanopy(hardwareWidth: presentation.hardwareWidth, topInset: presentation.topInset)
                .fill(.black)
        }
        .clipShape(NotchCanopy(hardwareWidth: presentation.hardwareWidth, topInset: presentation.topInset))
        .scaleEffect(x: presentation.expanded || reduceMotion ? 1 : 0.62,
                     y: presentation.expanded || reduceMotion ? 1 : 0.05, anchor: .top)
        .opacity(presentation.expanded ? 1 : 0)
        .animation(motion, value: presentation.expanded)
        .animation(motion, value: presentation.controls)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.30, dampingFraction: 0.90), value: success)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
    private var coachContent: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 18) {
                CameraCircle(camera: camera, accent: accent, demo: presentation.demo,
                             horizontalError: snapshot.horizontalError, direction: snapshot.direction)
                    .frame(width: 108, height: 108)
                VStack(alignment: .leading, spacing: 7) {
                    Text(presentation.demo ? "ANIMATION PREVIEW" : "AIRVEIL")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(1.4)
                        .foregroundStyle(.white.opacity(0.45))
                    HStack(spacing: 5) {
                        if let direction = snapshot.direction {
                            Image(systemName: directionSymbol(direction)).font(.system(size: 12, weight: .semibold))
                        } else if warning {
                            Image(systemName: snapshot.issue == .lowLight ? "sun.max.fill" : "exclamationmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(snapshot.title).font(.system(size: 17, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(accent)
                    Text(snapshot.detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.66))
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            NotchHeadMotionRail(feedback: headMotion, demoError: presentation.demo ? snapshot.horizontalError : nil,
                                isDemo: presentation.demo, accent: accent)
            GeometryReader { geo in
                Capsule().fill(.white.opacity(0.10))
                Capsule().fill(accent).frame(width: geo.size.width * min(1, max(0, snapshot.progress)))
            }
            .frame(height: 2)
            .accessibilityLabel("Calibration progress")
            .accessibilityValue("\(Int(snapshot.progress * 100)) percent")
            HStack {
                Button(snapshot.phase == .failure ? "Try again" : "Cancel") {
                    if snapshot.phase == .failure { presentation.refresh() } else { presentation.cancel() }
                }
                .buttonStyle(NotchTextButton())
                if snapshot.phase == .failure {
                    Button("Cancel", action: presentation.cancel).buttonStyle(NotchTextButton())
                }
                if camera.canOpenEdgeLightControls, !presentation.demo {
                    Button("Open Edge Light", action: camera.openEdgeLightControls)
                        .buttonStyle(NotchTextButton())
                        .help("Choose Edge Light in Apple's Video Effects controls.")
                }
                Spacer()
                Text(presentation.demo ? "Camera is off" : (camera.canOpenEdgeLightControls ? "" : "On-device camera check"))
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Button(action: presentation.settings) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                }
                .buttonStyle(NotchTextButton()).help("Advanced settings")
                .accessibilityLabel("Open AirVeil settings")
            }
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 13)
    }
    private var successContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.13)).frame(width: 38, height: 38)
                Image(systemName: "checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.demo ? "Preview complete" : snapshot.title).font(.system(size: 16, weight: .semibold))
                Text(presentation.demo ? "Your camera stayed off" : "Your screen direction is ready")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30).frame(height: 84)
        .accessibilityElement(children: .combine)
    }
    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.white.opacity(0.7))
                Text("AirVeil").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(presentation.enabled ? "Following your head" : "Paused")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.48))
                Button(action: presentation.settings) { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(NotchTextButton()).help("Advanced settings")
                    .accessibilityLabel("Open AirVeil settings")
            }
            HStack(spacing: 10) {
                Button(action: presentation.center) {
                    Text(presentation.cameraEnabled ? "Set center" : "Set up camera")
                        .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 32)
                }
                .buttonStyle(.plain).background(.white.opacity(0.14), in: Capsule())
                .disabled(presentation.cameraEnabled && !presentation.canCenter)
                Button(presentation.enabled ? "Pause" : "Enable", action: presentation.toggleEffect)
                    .buttonStyle(NotchTextButton())
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }
    private func directionSymbol(_ direction: NotchCoachDirection) -> String {
        switch direction { case .left: return "arrow.left"; case .right: return "arrow.right"
        case .up: return "arrow.up"; case .down: return "arrow.down" }
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
    var direction: NotchCoachDirection?
    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.08))
            if let image = camera.previewImage, !demo {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
                    .frame(width: 100, height: 100).scaleEffect(x: -1, y: 1)
                    .clipShape(Circle())
            } else {
                Image(systemName: demo ? "person.crop.circle" : "camera")
                    .font(.system(size: demo ? 48 : 27, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.28))
                    .offset(x: demo ? horizontalError * 16 : 0)
            }
            Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1).padding(3)
            Circle().trim(from: 0.04, to: 0.21).stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(0))
            Circle().trim(from: 0.04, to: 0.21).stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(90))
            Circle().trim(from: 0.04, to: 0.21).stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(180))
            Circle().trim(from: 0.04, to: 0.21).stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(270))
        }
        .accessibilityLabel(demo ? "Simulated preview, camera off" : "Mirrored camera preview")
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
        guard !isDemo, let angle = pose.yawDegrees else { return "—" }
        let magnitude = Int(abs(angle).rounded())
        if !pose.directionKnown { return "\(magnitude)° from center" }
        if magnitude == 0 { return "Facing center" }
        return "\(magnitude)° \(angle > 0 ? "left" : "right")"
    }
    private var tint: Color {
        guard !isDemo, pose.isScreenRelative, let angle = pose.yawDegrees else { return accent }
        guard pose.source != .airPods else { return accent }
        return abs(angle) <= HeadingFusionEngine.centerYawToleranceDegrees ? Color(red: 0.42, green: 0.91, blue: 0.64) : Color(red: 1, green: 0.43, blue: 0.43)
    }
    var body: some View {
        VStack(spacing: 3) {
            AlignmentRail(error: isDemo ? demoError : pose.normalizedYaw,
                          symmetric: !isDemo && !pose.directionKnown, accent: tint)
                .frame(height: 24)
            HStack {
                Text(label)
                Spacer(minLength: 4)
                Text(value).monospacedDigit()
            }
            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
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
            let width = min(230, geo.size.width)
            let selected = error.map { Int((min(1, max(-1, $0)) * 15).rounded()) }
            ZStack {
                ForEach(-15...15, id: \.self) { index in
                    let highlighted = selected.map { abs(index - $0) <= 1 || (symmetric && abs(index + $0) <= 1) } ?? false
                    Capsule().fill(highlighted ? accent : .white.opacity(index == 0 ? 0.50 : 0.20))
                        .frame(width: index == 0 ? 2 : 1.5, height: highlighted ? 12 : (index == 0 ? 10 : 5))
                        .position(x: geo.size.width / 2 + CGFloat(index) * width / 30,
                                  y: 10 - pow(CGFloat(index) / 15, 2) * 7)
                }
                if let error {
                    Circle().fill(accent).frame(width: 3, height: 3)
                        .position(x: geo.size.width / 2 + min(1, max(-1, error)) * width / 2, y: 22)
                    if symmetric {
                        Circle().fill(accent).frame(width: 3, height: 3)
                            .position(x: geo.size.width / 2 - min(1, max(-1, error)) * width / 2, y: 22)
                    }
                }
            }
        }
        .animation(reduceMotion ? .none : .linear(duration: 0.04), value: error)
        .accessibilityHidden(true)
    }
}
