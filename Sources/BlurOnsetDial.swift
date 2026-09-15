import SwiftUI

/// A selected side owns a positive magnitude; crossing center never wraps into
/// the other side. Live head feedback never writes either threshold.
enum BlurTurnSide: String, CaseIterable, Identifiable {
    case left = "Left", right = "Right"
    var id: String { rawValue }
    var screenSign: Double { self == .left ? -1 : 1 }
    var headingSign: Double { self == .left ? 1 : -1 }
}

enum BlurDialGeometry {
    static let maximum = 60.0
    static let sweep = 75.0 * Double.pi / 180
    static func bounded(_ value: Double) -> Double { value.isFinite ? min(maximum, max(0, value)) : 0 }
    static func point(value: Double, side: BlurTurnSide, center: CGPoint, radius: Double) -> CGPoint {
        let angle = bounded(value) / maximum * sweep
        return CGPoint(x: center.x + side.screenSign * sin(angle) * radius,
                       y: center.y + cos(angle) * radius)
    }
    static func value(at point: CGPoint, side: BlurTurnSide, center: CGPoint) -> Double {
        let x = Double(point.x - center.x) * side.screenSign
        let y = Double(point.y - center.y)
        guard x.isFinite, y.isFinite, x > 0 else { return 0 }
        return bounded(atan2(x, max(0, y)) / sweep * maximum)
    }
}

/// A live reading is a separate presentation mode, never an onset-setting write.
enum BlurDialFeedback: Equatable {
    case editing(side: BlurTurnSide, threshold: Double)
    case waiting
    case live(yaw: Double)

    init(side: BlurTurnSide, threshold: Double, liveYaw: Double?, syncing: Bool) {
        if !syncing { self = .editing(side: side, threshold: BlurDialGeometry.bounded(threshold)) }
        else if let liveYaw, liveYaw.isFinite { self = .live(yaw: liveYaw) }
        else { self = .waiting }
    }
    var allowsEditing: Bool { if case .editing = self { return true }; return false }
    var showsMarker: Bool { self != .waiting }
    /// Positive yaw is a physical left turn. Only the artwork is limited by the arc.
    var arcYaw: Double {
        switch self {
        case .editing(let side, let threshold): return side.headingSign * threshold
        case .waiting: return 0
        case .live(let yaw): return min(BlurDialGeometry.maximum, max(-BlurDialGeometry.maximum, yaw))
        }
    }
    var angleText: String {
        switch self {
        case .editing(_, let threshold): return String(format: "%.0f°", threshold)
        case .waiting: return "—"
        case .live(let yaw): return yaw.rounded() == 0 ? "0°" : String(format: "%+.0f°", yaw)
        }
    }
    var caption: String {
        switch self {
        case .editing(let side, _): return "\(side.rawValue) turn starts blur"
        case .waiting: return "Waiting for head tracking"
        case .live(let yaw): return yaw.rounded() == 0 ? "Facing forward" : (yaw > 0 ? "Left head turn" : "Right head turn")
        }
    }
    var isAtArcLimit: Bool { if case .live(let yaw) = self { return abs(yaw) > BlurDialGeometry.maximum }; return false }
    var accessibilityValue: String {
        switch self {
        case .editing(_, let threshold): return String(format: "%.0f degrees", threshold)
        case .waiting: return "Waiting for a valid head angle"
        case .live(let yaw):
            let angle = yaw.rounded() == 0 ? "0" : String(format: "%.0f", abs(yaw))
            let direction = yaw.rounded() == 0 ? "straight ahead" : (yaw > 0 ? "left" : "right")
            return "\(angle) degrees, \(direction)" + (isAtArcLimit ? ". Marker at the 60-degree arc limit" : "")
        }
    }
    func acceptedEdit(_ proposed: Double) -> Double? {
        allowsEditing ? BlurDialGeometry.bounded(proposed) : nil
    }
}

struct BlurOnsetDial: View {
    @Binding var left: Double
    @Binding var right: Double
    @State private var side = BlurTurnSide.left
    var liveYaw: Double?
    var syncRequested: Bool
    var syncStatus: String
    var compact: Bool
    var toggleSync: (() -> Void)?
    init(left: Binding<Double>, right: Binding<Double>, initialSide: BlurTurnSide = .left,
         liveYaw: Double? = nil, syncRequested: Bool = false,
         syncStatus: String = "Align with the camera, then follow your AirPods.",
         compact: Bool = false, toggleSync: (() -> Void)? = nil) {
        _left = left; _right = right; _side = State(initialValue: initialSide)
        self.liveYaw = liveYaw; self.syncRequested = syncRequested; self.syncStatus = syncStatus
        self.compact = compact; self.toggleSync = toggleSync
    }
    private var selection: Binding<Double> { side == .left ? $left : $right }
    private var feedback: BlurDialFeedback {
        BlurDialFeedback(side: side, threshold: selection.wrappedValue, liveYaw: liveYaw, syncing: syncRequested)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(syncRequested ? "Follow your head" : "Start blur when turning").font(.headline)
                    Text(syncRequested ? "Live angle from your AirPods." : "Choose a separate starting angle for each side.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Head turn", selection: $side) {
                    ForEach(BlurTurnSide.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                    .disabled(syncRequested)
                    .help(syncRequested ? "Stop sync to choose and edit a starting angle." : "Choose the starting angle to edit.")
            }
            HStack(spacing: compact ? 20 : 28) {
                OnsetArc(side: side, value: selection, feedback: feedback)
                    .frame(width: 300, height: 176)
                    .scaleEffect(compact ? 0.84 : 1)
                    .frame(width: compact ? 252 : 300, height: compact ? 148 : 176)
                VStack(alignment: .leading, spacing: 8) {
                    Text(feedback.angleText)
                        .font(.system(size: 42, weight: .medium, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("onset-angle-readout")
                    Text(feedback.caption)
                        .font(.subheadline.weight(.medium))
                    Text(syncRequested
                         ? "Stop sync to adjust when blur starts."
                         : "0° is straight ahead. Drag along the arc to choose when the opposite side begins to blur.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if feedback.isAtArcLimit {
                        Text("Marker at arc limit · 60°")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if syncRequested { Text("Blur starts") }
                        Label("Left \(Int(left.rounded()))°", systemImage: "arrow.turn.up.left")
                        Label("Right \(Int(right.rounded()))°", systemImage: "arrow.turn.up.right")
                    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Text(syncStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button(syncRequested ? "Stop sync" : "Sync head") { toggleSync?() }
                    .controlSize(.large).frame(minHeight: 44).disabled(toggleSync == nil)
                    .accessibilityIdentifier("onset-head-sync")
                    .accessibilityHint(syncRequested ? "Stops live feedback and returns to editing starting angles."
                                       : "Uses a camera alignment before following your AirPods. Starting angles stay unchanged.")
            }
        }
    }
}

private struct OnsetArc: View {
    let side: BlurTurnSide
    @Binding var value: Double
    let feedback: BlurDialFeedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let center = CGPoint(x: 150, y: 10)
    var body: some View {
        if feedback.allowsEditing {
            artwork
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    if let edit = feedback.acceptedEdit(BlurDialGeometry.value(at: drag.location, side: side, center: center).rounded()) {
                        value = edit
                    }
                })
                .accessibilityLabel("\(side.rawValue) turn blur starting angle")
                .accessibilityHint("Adjust between zero and sixty degrees. Zero is straight ahead.")
                .accessibilityAdjustableAction { direction in
                    if let edit = feedback.acceptedEdit(value + (direction == .increment ? 1 : -1)) { value = edit }
                }
        } else {
            artwork
                .accessibilityLabel("Live head angle")
                .accessibilityHint("Read-only while syncing. Stop sync to edit starting angles.")
        }
    }
    private var artwork: some View {
        OnsetArcArtwork(yaw: feedback.arcYaw, showsMarker: feedback.showsMarker,
                        editingSide: feedback.allowsEditing ? side : nil)
            .animation(reduceMotion ? nil : .linear(duration: 0.1), value: feedback.arcYaw)
            .accessibilityElement(children: .ignore)
            .accessibilityValue(feedback.accessibilityValue)
            .accessibilityIdentifier("onset-angle-arc")
    }
}

/// Interpolate a signed angle so the marker follows the curved track through
/// center instead of jumping sides or cutting across the arc in a straight line.
private struct OnsetArcArtwork: View, Animatable {
    var yaw: Double
    let showsMarker: Bool
    let editingSide: BlurTurnSide?
    var animatableData: Double { get { yaw } set { yaw = newValue } }
    private let accent = Color.green
    private let center = CGPoint(x: 150, y: 10)
    private let radius = 135.0
    private var side: BlurTurnSide { yaw == 0 ? (editingSide ?? .left) : (yaw > 0 ? .left : .right) }
    private var value: Double { abs(yaw) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for direction in BlurTurnSide.allCases {
                    var arc = Path()
                    for degree in 0...60 {
                        let p = BlurDialGeometry.point(value: Double(degree), side: direction, center: center, radius: radius)
                        if degree == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
                    }
                    let sideVisible = editingSide == nil || direction == editingSide
                    context.stroke(arc, with: .color(.primary.opacity(sideVisible ? 0.16 : 0.07)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    for degree in stride(from: 0, through: 60, by: 5) {
                        let major = degree % 15 == 0
                        var tick = Path()
                        tick.move(to: BlurDialGeometry.point(value: Double(degree), side: direction, center: center, radius: radius - (major ? 7 : 4)))
                        tick.addLine(to: BlurDialGeometry.point(value: Double(degree), side: direction, center: center, radius: radius + (major ? 7 : 4)))
                        let active = showsMarker && direction == side && Double(degree) <= value
                        context.stroke(tick, with: .color(active ? accent : .primary.opacity(sideVisible ? 0.35 : 0.1)),
                                       style: StrokeStyle(lineWidth: major ? 2 : 1.5, lineCap: .round))
                    }
                }
                var filled = Path()
                let end = BlurDialGeometry.bounded(value)
                for step in 0...120 {
                    let p = BlurDialGeometry.point(value: end * Double(step) / 120, side: side, center: center, radius: radius)
                    if step == 0 { filled.move(to: p) } else { filled.addLine(to: p) }
                }
                if showsMarker { context.stroke(filled, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round)) }
            }
            IllustrativeHead()
                .stroke(.primary.opacity(0.8), style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
                .frame(width: 58, height: 74)
                .rotation3DEffect(.degrees(-yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .opacity(showsMarker ? 1 : 0.25)
                .position(x: center.x, y: 61)
                .accessibilityHidden(true)
            if showsMarker {
                Circle().fill(accent).frame(width: 15, height: 15)
                    .overlay(Circle().stroke(.background, lineWidth: 3))
                    .shadow(color: accent.opacity(0.25), radius: 5, y: 1)
                    .position(BlurDialGeometry.point(value: value, side: side, center: center, radius: radius))
            }
            Text("0°").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .position(x: center.x, y: 169)
        }
    }
}

private struct IllustrativeHead: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        p.move(to: pt(0.17, 0.40))
        p.addCurve(to: pt(0.50, 0.04), control1: pt(0.12, 0.05), control2: pt(0.28, 0.04))
        p.addCurve(to: pt(0.83, 0.40), control1: pt(0.72, 0.04), control2: pt(0.88, 0.05))
        p.addCurve(to: pt(0.50, 0.92), control1: pt(0.84, 0.74), control2: pt(0.70, 0.92))
        p.addCurve(to: pt(0.17, 0.40), control1: pt(0.30, 0.92), control2: pt(0.16, 0.74))
        p.move(to: pt(0.14, 0.39)); p.addCurve(to: pt(0.18, 0.63), control1: pt(0.01, 0.34), control2: pt(0.03, 0.66))
        p.move(to: pt(0.86, 0.39)); p.addCurve(to: pt(0.82, 0.63), control1: pt(0.99, 0.34), control2: pt(0.97, 0.66))
        p.move(to: pt(0.30, 0.39)); p.addLine(to: pt(0.35, 0.39))
        p.move(to: pt(0.65, 0.39)); p.addLine(to: pt(0.70, 0.39))
        p.move(to: pt(0.51, 0.39)); p.addLine(to: pt(0.47, 0.59)); p.addLine(to: pt(0.54, 0.59))
        p.move(to: pt(0.37, 0.72)); p.addQuadCurve(to: pt(0.63, 0.72), control: pt(0.50, 0.80))
        return p
    }
}
