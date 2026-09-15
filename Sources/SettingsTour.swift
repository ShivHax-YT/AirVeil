import SwiftUI
import Combine

enum SettingsSection: String, CaseIterable, Identifiable {
    case preview = "Preview", tracking = "Tracking", displays = "Displays", appearance = "Appearance", power = "Power"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .preview: return "play.rectangle"
        case .tracking: return "airpodspro"
        case .displays: return "display.2"
        case .appearance: return "slider.horizontal.3"
        case .power: return "leaf"
        }
    }
}

/// Stable identifiers also serve as scroll destinations and spotlight anchors.
enum SettingsTourStep: String, CaseIterable, Identifiable {
    case welcome, preview, tracking, access, camera, displays, input, removal, seated
    case energy, coverage, onset, full, appearance, tuning, ready
    var id: String { rawValue }
    var section: SettingsSection {
        switch self {
        case .welcome, .preview, .ready: return .preview
        case .tracking, .camera: return .tracking
        case .access, .displays, .input: return .displays
        case .coverage, .onset, .full, .appearance, .tuning: return .appearance
        case .removal, .seated, .energy: return .power
        }
    }
    var title: String {
        switch self {
        case .welcome: return "Meet AirVeil"
        case .preview: return "Try a head turn"
        case .tracking: return "Tell AirVeil where your screen is"
        case .access: return "Allow live desktop blur"
        case .camera: return "A little help finding center"
        case .displays: return "Choose your displays"
        case .input: return "Keep covered areas protected"
        case .removal: return "When both AirPods come out"
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
        case .welcome: return "AirVeil follows your AirPods to cover your screen as you turn away. Settings are grouped into five tabs. This tour opens each tab for you; try its highlighted controls as you go."
        case .preview: return "Drag the highlighted slider to simulate a head turn. Center resets it. This tour preview works even while live blur is on, and changes only the example image."
        case .tracking: return "Wear compatible AirPods and choose Start head tracking if shown. Once motion is detected, face your display and choose Set center. Manual tracking needs a new center after an interruption."
        case .access: return "Screen Recording access lets AirVeil blur your actual desktop. Screen frames stay on this Mac. The preview and AirPod removal features work without this permission."
        case .camera: return "Camera assistance checks screen direction when AirPods resume tracking after an interruption. Enable it here, then set your center while facing the display. Use Refresh direction if a check fails. Images stay on your Mac and are discarded."
        case .displays: return "Select the screens AirVeil should cover. Check displays refreshes the list after connecting a monitor. Only selected displays receive the effect."
        case .input: return "Block clicks and scrolling in the blurred area, or across the entire affected display. The menu bar and notch controls stay available so you can pause."
        case .removal: return "Lock when I leave is on by default. With camera assistance and a saved center, removing both AirPods starts a seat check; confirmed absence turns displays off. Set Require password to Immediately in macOS to lock. Keep Automatic Ear Detection on. AirVeil cannot identify individual earbuds."
        case .seated: return "Dimming is off until you turn it on. Choose a seated brightness; 0% goes black without locking. Returning AirPods restores brightness. If the camera view becomes too dark, AirVeil restores brightness and keeps checking without dimming again. Dimming and locking work independently."
        case .energy: return "Automatic reduces desktop refresh in Low Power Mode or when your Mac is running hot. Smoothest keeps the usual refresh; Reduced energy always refreshes less often. Head tracking, camera checks, and removal behavior keep their normal timing."
        case .coverage: return "Directional half covers one side as you turn. Whole-screen sweep spreads the effect across the screen. Choose either option here; open Preview to compare them."
        case .onset: return "Set separate left and right starting angles with the dial. Sync head uses a camera check, then lets the illustration follow your AirPods. Syncing does not change either starting angle."
        case .full: return "Fully obscured sets the angle where the effect reaches maximum coverage. Keep it beyond the starting angles for a gradual transition."
        case .appearance: return "Opaque cover replaces blur with a solid cover. Invert direction swaps which side responds to a head turn. Try either switch, then open Preview to see the result."
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
    init(defaults: UserDefaults = .standard, startImmediately: Bool = true) {
        self.defaults = defaults
        step = startImmediately && !defaults.bool(forKey: Self.completionKey) ? .welcome : nil
    }
    func beginIfNeeded() {
        guard !isActive, !defaults.bool(forKey: Self.completionKey) else { return }
        step = .welcome
    }
    /// Hiding setup for permission review is not tutorial completion.
    func suspendForPermissions() { step = nil }
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
    var showHighlightedControl: (() -> Void)? = nil
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
                    if let showHighlightedControl {
                        Button("Show control", action: showHighlightedControl).controlSize(.large)
                            .accessibilityHint("Returns to the tab for this tutorial step.")
                    } else {
                        ProgressView(value: Double(tour.index + 1), total: Double(SettingsTourStep.allCases.count))
                            .progressViewStyle(.linear).frame(width: 108)
                            .accessibilityLabel("Tour progress")
                    }
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
