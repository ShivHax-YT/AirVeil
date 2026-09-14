import SwiftUI
import Combine

/// Stable identifiers also serve as scroll destinations and spotlight anchors.
enum SettingsTourStep: String, CaseIterable, Identifiable {
    case welcome, preview, tracking, access, camera, displays, input, removal
    case energy, coverage, onset, full, appearance, tuning, ready
    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: return "Meet AirVeil"
        case .preview: return "Try a head turn"
        case .tracking: return "Tell AirVeil where your screen is"
        case .access: return "Allow live desktop blur"
        case .camera: return "A little help finding center"
        case .displays: return "Choose your displays"
        case .input: return "Keep covered areas protected"
        case .removal: return "When an AirPod comes out"
        case .energy: return "Choose how AirVeil uses energy"
        case .coverage: return "Choose how the screen fades"
        case .onset: return "Pick when blur begins"
        case .full: return "Set the finishing angle"
        case .appearance: return "Choose the cover and direction"
        case .tuning: return "Make the motion feel natural"
        case .ready: return "You're ready when you are"
        }
    }
    var detail: String {
        switch self {
        case .welcome: return "AirVeil uses AirPods head motion to cover your screen as you turn away. This quick tour shows you the controls. You can replay it here anytime."
        case .preview: return "Simulate a head turn to explore the effect without screen access. Move the slider left or right; Center resets the preview. Your desktop stays clear until you enable blur."
        case .tracking: return "Wear compatible AirPods, look straight at your display, and choose Set center. Manual tracking needs a new center after an interruption. The angle shows your head's turn from center."
        case .access: return "Screen Recording access lets AirVeil blur your actual desktop. Screen frames stay on this Mac. The preview and AirPod removal features work without this permission."
        case .camera: return "Optional camera assistance checks your screen direction and can restore it after confirmed reinsertion. Refresh direction starts a check; Stop check cancels it. Face light turns on when repeated camera frames confirm it is needed. Images stay local and are discarded."
        case .displays: return "Select the screens AirVeil should cover. Check displays refreshes the list after connecting a monitor. Only selected displays receive the effect."
        case .input: return "Block clicks and scrolling in the blurred area, or across the entire affected display. AirVeil controls and the menu bar stay available so you can pause."
        case .removal: return "Optional removal control needs confirmed in-ear status and Automatic Ear Detection. Seated dimming uses the camera: 0% goes black without locking; reinsertion restores brightness. If your seat cannot be confirmed, displays turn off. Lock Screen settings controls the wake password."
        case .energy: return "Automatic reduces desktop refresh in Low Power Mode or when your Mac is running hot. Smoothest keeps the usual refresh; Reduced energy always refreshes less often. Head tracking, camera checks, and removal behavior keep their normal timing."
        case .coverage: return "Directional half covers one side as you turn. Whole-screen sweep spreads the effect across the screen. You can compare both in the preview after this tour."
        case .onset: return "Set separate left and right angles with the dial. A smaller angle begins blur sooner; a larger angle gives you more room to move before it starts."
        case .full: return "Fully obscured sets the angle where the effect reaches maximum coverage. Keep it beyond the starting angles for a gradual transition."
        case .appearance: return "Opaque cover replaces blur with a solid cover. Invert direction swaps which side responds to a head turn. Use the preview to choose the behavior that feels right."
        case .tuning: return "Blur strength changes how much detail disappears. Soft edge controls the fade boundary. Response sets smoothing time: lower feels quicker, higher feels gentler. Reset defaults pauses the effect and restores its settings."
        case .ready: return "Set center, allow screen access if you want live blur, then choose Enable blur. Pause & clear screen is always in the menu bar. Control–Option–Command–P pauses when the shortcut is available."
        }
    }
    var symbol: String {
        switch self {
        case .welcome: return "circle.lefthalf.filled"
        case .preview: return "play.rectangle"
        case .tracking, .onset, .full: return "scope"
        case .access, .displays: return "display"
        case .camera: return "camera"
        case .input: return "cursorarrow"
        case .removal: return "airpodspro"
        case .energy: return "leaf"
        case .coverage, .appearance: return "circle.lefthalf.filled"
        case .tuning: return "slider.horizontal.3"
        case .ready: return "checkmark"
        }
    }
}

@MainActor final class SettingsTour: ObservableObject {
    static let completionKey = "settingsTourCompletedV1"
    @Published private(set) var step: SettingsTourStep?
    private let defaults: UserDefaults
    var onFinish: (() -> Void)?
    var isActive: Bool { step != nil }
    var index: Int { step.flatMap { SettingsTourStep.allCases.firstIndex(of: $0) } ?? 0 }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        step = defaults.bool(forKey: Self.completionKey) ? nil : .welcome
    }
    func replay() { step = .welcome }
    func back() {
        guard isActive, index > 0 else { return }
        step = SettingsTourStep.allCases[index - 1]
    }
    func next() {
        guard isActive else { return }
        if index == SettingsTourStep.allCases.count - 1 { finish() }
        else { step = SettingsTourStep.allCases[index + 1] }
    }
    func finish() {
        guard isActive else { return }
        defaults.set(true, forKey: Self.completionKey)
        step = nil
        onFinish?()
    }
}

struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [SettingsTourStep: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [SettingsTourStep: Anchor<CGRect>],
                       nextValue: () -> [SettingsTourStep: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
extension View {
    func tourTarget(_ step: SettingsTourStep) -> some View {
        self.anchorPreference(key: TourAnchorKey.self, value: .bounds) { [step: $0] }.id(step)
    }
}

/// A true cutout leaves the original control visible, with no duplicate controls.
struct TourSpotlight: View {
    let rect: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let hole = rect?.insetBy(dx: -8, dy: -8).intersection(bounds.insetBy(dx: 8, dy: 8)) ?? .null
            Path { path in
                path.addRect(bounds)
                if !hole.isNull { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16)) }
            }.fill(.black.opacity(0.56), style: FillStyle(eoFill: true))
            if !hole.isNull {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.95), lineWidth: 2)
                    .shadow(color: .blue.opacity(0.3), radius: 12)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct SettingsTourCard: View {
    @ObservedObject var tour: SettingsTour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var appeared = false
    var body: some View {
        if let step = tour.step {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: step.symbol).font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("QUICK TOUR · \(tour.index + 1) OF \(SettingsTourStep.allCases.count)")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        Text(step.title).font(.system(size: 21, weight: .semibold))
                            .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    }
                    Spacer()
                    Button("Skip tour") { tour.finish() }.buttonStyle(.plain)
                        .frame(minWidth: 64, minHeight: 44)
                }
                Text(step.detail).font(.system(size: 13)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back") { tour.back() }.disabled(tour.index == 0)
                        .frame(minWidth: 64, minHeight: 44)
                    Spacer()
                    Text("\(Int(Double(tour.index + 1) / Double(SettingsTourStep.allCases.count) * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button(action: { tour.next() }) {
                        Text(step == .ready ? "Get started" : "Continue")
                            .frame(minWidth: 104, minHeight: 32)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(maxWidth: 680)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .padding(16).frame(maxWidth: .infinity)
            .onChange(of: step) { _, _ in titleFocused = true }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 14)
            .onAppear {
                titleFocused = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { appeared = true }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
        }
    }
}
