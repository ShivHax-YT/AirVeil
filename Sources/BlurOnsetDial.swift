import SwiftUI

/// A selected side owns a positive magnitude; crossing center never wraps into
/// the other side. The preview is illustrative, separate from sensor heading.
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

struct BlurOnsetDial: View {
    @Binding var left: Double
    @Binding var right: Double
    @State private var side = BlurTurnSide.left
    init(left: Binding<Double>, right: Binding<Double>, initialSide: BlurTurnSide = .left) {
        _left = left; _right = right; _side = State(initialValue: initialSide)
    }
    private var selection: Binding<Double> { side == .left ? $left : $right }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Start blur when turning").font(.headline)
                    Text("Choose a separate starting angle for each side.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Head turn", selection: $side) {
                    ForEach(BlurTurnSide.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            HStack(spacing: 28) {
                OnsetArc(side: side, value: selection).id(side)
                    .frame(width: 300, height: 176)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Int(selection.wrappedValue.rounded()))°")
                        .font(.system(size: 42, weight: .medium, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("\(side.rawValue) turn starts blur")
                        .font(.subheadline.weight(.medium))
                    Text("0° is straight ahead. Drag along the arc to choose when the opposite side begins to blur.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Label("Left \(Int(left.rounded()))°", systemImage: "arrow.turn.up.left")
                        Label("Right \(Int(right.rounded()))°", systemImage: "arrow.turn.up.right")
                    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct OnsetArc: View {
    let side: BlurTurnSide
    @Binding var value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var faceAngle = 0.0
    private let accent = Color.green
    private let center = CGPoint(x: 150, y: 10)
    private let radius = 135.0
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for direction in BlurTurnSide.allCases {
                    var arc = Path()
                    for degree in 0...60 {
                        let p = BlurDialGeometry.point(value: Double(degree), side: direction, center: center, radius: radius)
                        if degree == 0 { arc.move(to: p) } else { arc.addLine(to: p) }
                    }
                    context.stroke(arc, with: .color(.primary.opacity(direction == side ? 0.16 : 0.07)),
                                   style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    for degree in stride(from: 0, through: 60, by: 5) {
                        let major = degree % 15 == 0
                        var tick = Path()
                        tick.move(to: BlurDialGeometry.point(value: Double(degree), side: direction, center: center, radius: radius - (major ? 7 : 4)))
                        tick.addLine(to: BlurDialGeometry.point(value: Double(degree), side: direction, center: center, radius: radius + (major ? 7 : 4)))
                        let active = direction == side && Double(degree) <= value
                        context.stroke(tick, with: .color(active ? accent : .primary.opacity(direction == side ? 0.35 : 0.1)),
                                       style: StrokeStyle(lineWidth: major ? 2 : 1.5, lineCap: .round))
                    }
                }
                var filled = Path()
                let end = BlurDialGeometry.bounded(value)
                for step in 0...120 {
                    let p = BlurDialGeometry.point(value: end * Double(step) / 120, side: side, center: center, radius: radius)
                    if step == 0 { filled.move(to: p) } else { filled.addLine(to: p) }
                }
                context.stroke(filled, with: .color(accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            IllustrativeHead()
                .stroke(.primary.opacity(0.8), style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round))
                .frame(width: 58, height: 74)
                .rotation3DEffect(.degrees(side.screenSign * faceAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .position(x: center.x, y: 61)
                .accessibilityHidden(true)
            Circle().fill(accent).frame(width: 15, height: 15)
                .overlay(Circle().stroke(.background, lineWidth: 3))
                .shadow(color: accent.opacity(0.25), radius: 5, y: 1)
                .position(BlurDialGeometry.point(value: value, side: side, center: center, radius: radius))
            Text("0°").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .position(x: center.x, y: 169)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            value = BlurDialGeometry.value(at: drag.location, side: side, center: center).rounded()
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(side.rawValue) turn blur starting angle")
        .accessibilityValue("\(Int(value.rounded())) degrees")
        .accessibilityHint("Adjust between zero and sixty degrees. Zero is straight ahead.")
        .accessibilityAdjustableAction { direction in
            value = BlurDialGeometry.bounded(value + (direction == .increment ? 1 : -1))
        }
        .task { moveHead(to: value) }
        .onChange(of: value) { _, next in moveHead(to: next) }
    }
    private func moveHead(to next: Double) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) { faceAngle = BlurDialGeometry.bounded(next) }
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
