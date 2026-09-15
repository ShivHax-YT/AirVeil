import SwiftUI
import Combine

/// Stable identifiers also serve as scroll destinations and spotlight anchors.
enum SettingsTourStep: String, CaseIterable, Identifiable {
    case welcome, preview, tracking, access, camera, displays, input, removal, seated
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
        case .seated: return "Dim while you stay seated"
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
        case .welcome: return "AirVeil follows your AirPods to cover your screen as you turn away. Try the highlighted controls as you go, or scroll to explore. You can replay this tour anytime."
        case .preview: return "Drag the highlighted slider to simulate a head turn. Center resets it. This tour preview works even while live blur is on, and changes only the example image."
        case .tracking: return "Wear compatible AirPods and choose Start head tracking if shown. Once motion is detected, face your display and choose Set center. Manual tracking needs a new center after an interruption."
        case .access: return "Screen Recording access lets AirVeil blur your actual desktop. Screen frames stay on this Mac. The preview and AirPod removal features work without this permission."
        case .camera: return "Camera assistance checks screen direction after a confirmed AirPod return or reconnection. Enable it here, then set your center while facing the display. Use Refresh direction if a check fails. Images stay on your Mac and are discarded."
        case .displays: return "Select the screens AirVeil should cover. Check displays refreshes the list after connecting a monitor. Only selected displays receive the effect."
        case .input: return "Block clicks and scrolling in the blurred area, or across the entire affected display. The menu bar and notch controls stay available so you can pause."
        case .removal: return "Turn on automatic display management and keep Automatic Ear Detection on. Confirmed removal of either AirPod supports dimming. When in-ear status is unavailable, camera checks after connection changes turn displays off only if you have left."
        case .seated: return "Choose your seated brightness; 0% goes black without locking. Dimming needs confirmed in-ear status, camera assistance, and a saved seat. A confirmed return restores brightness. Connection-only checks leave seated brightness unchanged."
        case .energy: return "Automatic reduces desktop refresh in Low Power Mode or when your Mac is running hot. Smoothest keeps the usual refresh; Reduced energy always refreshes less often. Head tracking, camera checks, and removal behavior keep their normal timing."
        case .coverage: return "Directional half covers one side as you turn. Whole-screen sweep spreads the effect across the screen. Choose either option here; scroll up to compare them in the preview."
        case .onset: return "Set separate left and right angles with the dial. A smaller angle begins blur sooner; a larger angle gives you more room to move before it starts."
        case .full: return "Fully obscured sets the angle where the effect reaches maximum coverage. Keep it beyond the starting angles for a gradual transition."
        case .appearance: return "Opaque cover replaces blur with a solid cover. Invert direction swaps which side responds to a head turn. Try either switch, then scroll up to see the result in the preview."
        case .tuning: return "Blur strength changes how much detail disappears. Soft edge controls the fade boundary. Response sets smoothing time: lower feels quicker, higher feels gentler. Try the sliders to find your preferred feel."
        case .ready: return "Wear your AirPods, set your center, and allow screen access before choosing Enable blur. Pause & clear screen stays available in the menu bar. You can return to these settings anytime."
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
        case .removal, .seated: return "airpodspro"
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
    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let hole = rect?.insetBy(dx: -8, dy: -8).intersection(bounds.insetBy(dx: 8, dy: 8)) ?? .null
            Path { path in
                path.addRect(bounds)
                if !hole.isNull { path.addRoundedRect(in: hole, cornerSize: CGSize(width: 16, height: 16)) }
            }.fill(.black.opacity(0.48), style: FillStyle(eoFill: true))
            if !hole.isNull {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.12), radius: 8)
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
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: step.symbol).font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Quick tour · \(tour.index + 1) of \(SettingsTourStep.allCases.count)")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text(step.title).font(.system(size: 20, weight: .semibold))
                            .accessibilityAddTraits(.isHeader).accessibilityFocused($titleFocused)
                    }
                    Spacer()
                    Button(action: { tour.finish() }) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Close tour").accessibilityLabel("Close tour")
                        .accessibilityIdentifier("tour-close")
                }
                Text(step.detail).font(.system(size: 13)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    ProgressView(value: Double(tour.index + 1), total: Double(SettingsTourStep.allCases.count))
                        .progressViewStyle(.linear).frame(width: 108)
                        .accessibilityLabel("Tour progress")
                    Spacer()
                    Button(action: { tour.back() }) {
                        Text("Back").frame(minWidth: 64, minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(tour.index == 0)
                        .accessibilityIdentifier("tour-back")
                    Button(action: { tour.next() }) {
                        Text(step == .ready ? "Get started" : "Continue")
                            .frame(minWidth: 104, minHeight: 32)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("tour-next")
                }
            }
            .padding(20).frame(maxWidth: 680)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 4)
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity)
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
