import SwiftUI
import AppKit
import Combine

struct VeilPreview: NSViewRepresentable {
    let model: AppModel
    /// Tour simulation is confined to this view, including while live blur is on.
    var simulationYaw: Double? = nil
    final class Coordinator { var simulationYaw: Double? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> VeilMetalView {
        let view = VeilMetalView(frame: NSRect(x:0,y:0,width:660,height:280))
        view.rendersBaseImage = true
        try? view.setImage(PreviewArt.image)
        let coordinator = context.coordinator
        coordinator.simulationYaw = simulationYaw
        model.previewFrame = { [weak view, weak model] strengths in
            guard let view, let model else { return }
            Self.update(view, model: model, strengths: strengths, simulationYaw: coordinator.simulationYaw)
        }
        model.previewVisibility = { [weak view] visible in view?.renderingEnabled = visible }
        Self.update(view, model: model, strengths: model.strengths, simulationYaw: simulationYaw)
        return view
    }
    func updateNSView(_ view: VeilMetalView, context: Context) {
        context.coordinator.simulationYaw = simulationYaw
        Self.update(view, model: model, strengths: model.strengths, simulationYaw: simulationYaw)
    }
    static func dismantleNSView(_ view: VeilMetalView, coordinator: Coordinator) { view.renderingEnabled = false }
    private static func update(_ view: VeilMetalView, model: AppModel, strengths: VeilStrength, simulationYaw: Double?) {
        let strengths = simulationYaw.map {
            VeilMath.target(yawDegrees: model.inverted ? -$0 : $0, leftOnset: model.leftOnset,
                rightOnset: model.rightOnset, full: model.fullAngle, wholeScreen: model.wholeScreen)
        } ?? strengths
        view.setEffect(left: strengths.left, right: strengths.right, blurPoints: model.blurPoints,
            feather: model.feather, opaque: model.opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            shield: simulationYaw == nil && (model.shielded || (model.enabled && !model.overlay.isReady)), wholeScreen: model.wholeScreen)
    }
}

private struct TrackingHeader: View {
    @ObservedObject var presentation: TrackingPresentation
    var body: some View {
        HStack {
            Label(presentation.snapshot.headline,systemImage:"airpodspro").font(.headline)
            Spacer()
            Text(String(format:"%+d°",presentation.snapshot.angle))
                .font(.system(.title3,design:.rounded).monospacedDigit().weight(.semibold))
        }
    }
}
private struct TrackingDirection: View {
    @ObservedObject var presentation: TrackingPresentation
    var body: some View { Text(presentation.snapshot.direction).font(.subheadline.weight(.medium)) }
}
private struct EnableEffectButton: View {
    @ObservedObject var presentation: TrackingPresentation
    let model: AppModel
    var body: some View {
        Button("Enable blur") { model.enable() }.modifier(SettingsPrimaryAction())
            .disabled(!presentation.snapshot.canEnable)
    }
}
private struct RefreshDirectionButton: View {
    @ObservedObject var presentation: TrackingPresentation
    let model: AppModel
    var body: some View {
        Button("Refresh direction") { model.refreshCameraDirection() }
            .disabled(!presentation.snapshot.hasSavedCenter || !presentation.snapshot.canSetCenter)
    }
}
private struct HeadTrackingControls: View {
    @ObservedObject var presentation: TrackingPresentation
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Head tracking",systemImage:"airpodspro").font(.headline)
            Text(presentation.snapshot.status).font(.caption).foregroundStyle(.secondary)
                .frame(minHeight:34,alignment:.topLeading)
            Text("Detected automatically when worn").font(.caption2).foregroundStyle(.secondary)
            Label(presentation.snapshot.hasSavedCenter ? "Screen direction saved" : "Set your screen direction",
                  systemImage:presentation.snapshot.hasSavedCenter ? "scope" : "viewfinder")
                .font(.caption.weight(.medium))
            Text(model.cameraHeading.isEnabled ? "Face straight ahead within 5°. A brief camera and AirPods check establishes center after setup or a supported return event." : "AirPods can change their reference after removal. Use Set center again, or enable camera assistance below.")
                .font(.caption2).foregroundStyle(.secondary)
            if model.startupTourActive || !model.motionAccessAllowedByOnboarding {
                Button(model.motionAccessAllowedByOnboarding ? "Start head tracking" : "Review head-tracking access") { model.startTrackingFromTour() }
                    .controlSize(.large)
                Text(model.motionAccessAllowedByOnboarding
                     ? "Starts AirPods motion tracking so you can set your center during the tour."
                     : "Review Motion & Fitness access before starting AirPods tracking.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button(presentation.snapshot.centerBusy ? "Checking direction…" : "Set center") { model.calibrate() }
                .disabled(!presentation.snapshot.canSetCenter).controlSize(.large)
            if !presentation.snapshot.source.isEmpty {
                Text("≈\(presentation.snapshot.sampleRate) samples/s · \(presentation.snapshot.source)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

/// Observe just the low-frequency wear-status publisher. MotionService also
/// publishes head pose at sensor rate; the whole Settings view must not subscribe.
@MainActor private struct AirPodsWearStatus: View {
    let motion: MotionService
    @State private var status: String
    init(motion: MotionService) {
        self.motion = motion
        _status = State(initialValue: motion.wearStatus)
    }
    var body: some View {
        Label(status, systemImage: "airpodspro")
            .font(.caption2).foregroundStyle(.secondary)
            .onReceive(motion.$wearStatus.removeDuplicates()) { status = $0 }
    }
}

/// Energy changes publish only when a mode or system condition changes.
/// Keep them separate from the high-frequency tracking presentation.
struct EnergySettingsView: View {
    @ObservedObject var energy: EnergyController
    @ObservedObject var overlay: DesktopOverlayController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Energy use", systemImage: "leaf").font(.headline)
            Picker("Energy use", selection: $energy.mode) {
                ForEach(EnergyMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented).controlSize(.large)
            .frame(minHeight: 44).accessibilityLabel("Energy use")
            Text(energy.reason).font(.subheadline).foregroundStyle(.secondary)
            if let status = overlay.captureEnergyStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Desktop refresh status: " + status)
            }
            Text("Reduced energy refreshes the desktop image less often. Head tracking and the cover stay responsive; camera and AirPod removal checks keep their normal timing.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .modifier(SettingsContentSurface())
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tour: SettingsTour
    var showPermissions: (() -> Void)? = nil
    var onBackgroundAnimationTick: ((TimeInterval) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSection: SettingsSection
    var onTourTargetResolved: ((SettingsSection, SettingsTourStep, CGRect?, CGSize) -> Void)? = nil
    @State private var advanced = false
    @State private var advancedBeforeTour = false
    @State private var tourSimulation = true
    @State private var tourPreviewYaw = 0.0
    private var simulating: Bool { tour.isActive ? tourSimulation : model.simulate }
    private var previewAngle: Binding<Double> {
        Binding(get: { tour.isActive ? tourPreviewYaw : model.previewYaw }, set: { angle in
            if tour.isActive { tourSimulation = true; tourPreviewYaw = angle }
            else { model.simulate = true; model.previewYaw = angle }
        })
    }
    private var simulation: Binding<Bool> {
        tour.isActive ? $tourSimulation : $model.simulate
    }
    init(model: AppModel, tour: SettingsTour, showPermissions: (() -> Void)? = nil,
         initialSection: SettingsSection = .preview,
         onBackgroundAnimationTick: ((TimeInterval) -> Void)? = nil,
         onTourTargetResolved: ((SettingsSection, SettingsTourStep, CGRect?, CGSize) -> Void)? = nil) {
        self.model = model; self.tour = tour; self.showPermissions = showPermissions
        self.onBackgroundAnimationTick = onBackgroundAnimationTick
        self.onTourTargetResolved = onTourTargetResolved
        _selectedSection = State(initialValue: tour.step?.section ?? initialSection)
    }
    private let accent = Color(red:0.18,green:0.43,blue:0.92)
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                TabView(selection: $selectedSection) {
                    ForEach(SettingsSection.allCases) { section in
                        sectionPage(section)
                            .tabItem { Label(section.rawValue, systemImage: section.symbol) }
                            .tag(section)
                    }
                }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("settings-sections")
                if !tour.isActive { LegalFooter().padding(.horizontal, 20).padding(.vertical, 10) }
            }
            .overlayPreferenceValue(TourAnchorKey.self) { anchors in
                if let step = tour.step {
                    GeometryReader { geometry in
                        let rect = anchors[step].map { geometry[$0] }
                        TourSpotlight(rect: rect).id(step)
                            .onAppear { onTourTargetResolved?(selectedSection, step, rect, geometry.size) }
                            .onChange(of: rect) { _, next in
                                onTourTargetResolved?(selectedSection, step, next, geometry.size)
                            }
                    }.allowsHitTesting(false)
                }
            }
            if tour.isActive {
                SettingsTourCard(tour: tour, showHighlightedControl: tour.step?.section != selectedSection ? {
                    if let section = tour.step?.section { selectedSection = section }
                } : nil)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: tour.step) { old, step in
            if old == nil, step != nil {
                advancedBeforeTour = advanced
                tourSimulation = true; tourPreviewYaw = 0
            }
            if step == .tuning { advanced = true }
            if let step { selectedSection = step.section }
            else { advanced = advancedBeforeTour }
        }
        .onChange(of: selectedSection) { old, _ in
            if old == .appearance { model.stopHeadPreviewSync() }
        }
        .onDisappear { model.stopHeadPreviewSync() }
        // Keep the main settings surface visually connected to the permission
        // flow. Content surfaces remain inexpensive to composite; native controls
        // supply the refractive glass. The starfield suspends when hidden
        // or Reduce Motion is enabled.
        .background(PermissionStarfieldBackground(placement: .settings, onAnimationTick: onBackgroundAnimationTick))
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .animation(reduceMotion ? nil : SettingsMotion.reveal, value: tour.isActive)
        .frame(minWidth: 740, idealWidth: 800, minHeight: 660, idealHeight: 850)
        .onAppear { model.refreshPermission() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(accent, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("AirVeil").font(.system(size: 22, weight: .semibold))
                    Text(model.enabled ? "Blur is on" : "Blur is paused")
                        .font(.caption).foregroundStyle(model.enabled ? Color.green : Color.secondary)
                }
            }.tourTarget(.welcome)
            Spacer()
            Group {
                if model.enabled || model.starting {
                    Button("Pause & clear screen") { model.pause() }
                        .modifier(SettingsPrimaryAction())
                } else { EnableEffectButton(presentation: model.presentation, model: model) }
            }.tourTarget(.ready)
            Menu {
                if let showPermissions { Button("Permissions", action: showPermissions) }
                Button("Take a tour") { tour.replay() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).frame(width: 32, height: 32)
            }.menuStyle(.borderlessButton).fixedSize().help("Setup and tutorial")
                .accessibilityLabel("Setup and tutorial")
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func sectionPage(_ section: SettingsSection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if selectedSection == section {
                    VStack(alignment: .leading, spacing: 20) {
                        sectionContent(section)
                    }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
                }
            }
            .modifier(SettingsScrollEdge())
            .accessibilityIdentifier("settings-page-" + section.rawValue.lowercased())
            .task(id: "\(selectedSection.rawValue)-\(tour.step?.rawValue ?? "none")") {
                guard selectedSection == section, let step = tour.step, step.section == section else { return }
                // Wait for the newly selected native tab to lay out its anchors.
                await Task.yield()
                try? await Task.sleep(nanoseconds: 30_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : SettingsMotion.reveal) {
                    proxy.scrollTo(step, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder private func sectionContent(_ section: SettingsSection) -> some View {
        switch section {
        case .preview:
            previewCard
            Text(model.message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Blur affects everyone viewing a selected display. Tracking loss pauses the effect. Use the menu bar or the pause shortcut to clear the screen.")
                .font(.caption2).foregroundStyle(.secondary)
            Text(model.pauseHint).font(.caption2).foregroundStyle(.secondary)
        case .tracking:
            HeadTrackingControls(presentation: model.presentation, model: model)
                .modifier(SettingsContentSurface()).tourTarget(.tracking)
            cameraCard
        case .displays:
            accessCard
            displaysCard
        case .appearance:
            appearanceCard
        case .power:
            powerCards
        }
    }

    @ViewBuilder private var previewCard: some View {
                VStack(alignment:.leading,spacing:12) {
                    if tour.isActive {
                        HStack {
                            Label("Interactive preview", systemImage: "play.rectangle").font(.headline)
                            Spacer()
                            Text(String(format: "%+.0f°", tourPreviewYaw)).monospacedDigit()
                        }
                    } else { TrackingHeader(presentation:model.presentation) }
                    VeilPreview(model:model, simulationYaw: tour.isActive && simulating ? tourPreviewYaw : nil)
                        .frame(height:tour.isActive ? 128 : 260).clipShape(RoundedRectangle(cornerRadius:14))
                        .overlay(RoundedRectangle(cornerRadius:14).stroke(.primary.opacity(0.08)))
                        .accessibilityLabel("Directional blur preview")
                    HStack {
                        if tour.isActive {
                            Text("Try the effect in this preview.").font(.caption).foregroundStyle(.secondary)
                        } else { TrackingDirection(presentation:model.presentation) }
                        Spacer()
                        Text(simulating && (tour.isActive || !model.enabled) ? "SIMULATED PREVIEW" : (tour.isActive ? "CURRENT PREVIEW" : "AIRPODS PREVIEW"))
                            .font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                    }
                    if !model.enabled || tour.isActive {
                        Toggle("Simulate a head turn",isOn:simulation).toggleStyle(.switch).controlSize(.small)
                            .accessibilityIdentifier("preview-simulation")
                        HStack {
                            Text("Right").font(.caption).foregroundStyle(.secondary)
                            Slider(value:previewAngle,in:-60...60).accessibilityLabel("Simulated head angle")
                                .accessibilityIdentifier("preview-angle")
                            Text("Left").font(.caption).foregroundStyle(.secondary)
                            Button("Center") { previewAngle.wrappedValue = 0 }
                                .modifier(SettingsSecondaryAction())
                                .accessibilityIdentifier("preview-center")
                        }
                    }
                }.modifier(SettingsContentSurface()).tourTarget(.preview)

    }

    @ViewBuilder private var accessCard: some View {
                    VStack(alignment:.leading,spacing:10) {
                        Label("Live blur access",systemImage:"display").font(.headline)
                        Text(model.permissionGranted ? "Screen capture allowed. Frames stay on this Mac." : "Allow screen capture for live blur. Preview needs no permission.")
                            .font(.caption).foregroundStyle(.secondary).frame(minHeight:34,alignment:.topLeading)
                        HStack {
                            Button(model.checkingAccess ? "Checking…" : (model.permissionGranted ? "Check access" : "Allow screen capture")) {
                                model.requestScreenPermission()
                            }.controlSize(.large).disabled(model.checkingAccess)
                        }
                        Text("Screen Recording permission is only needed for live blur. AirPods removal checks use Camera and Head Tracking permissions.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(model.overlay.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth:.infinity,alignment:.leading).modifier(SettingsContentSurface()).tourTarget(.access)
    }

    @ViewBuilder private var cameraCard: some View {
                VStack(alignment:.leading,spacing:12) {
                    Label("Remember screen direction with the camera",systemImage:"camera")
                        .font(.headline)
                    Text("Optional, brief checks use your Mac’s built-in camera to match returning AirPods to the screen. Images stay on this Mac and are discarded; nothing is recorded.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.cameraHeading.isEnabled {
                        Text(model.cameraHeading.status).font(.caption)
                        HStack {
                            RefreshDirectionButton(presentation:model.presentation,model:model)
                            if model.cameraHeading.isBusy {
                                Button("Stop check") { model.cameraHeading.cancelPendingRecovery() }
                            }
                            Spacer()
                            Button("Turn camera assistance off") { model.disableCameraAssistance() }
                        }
                        Text("Face straight ahead, within 5° of center, and hold briefly. Each check finishes in one pass. If repeated camera frames show your face needs more light, a rounded edge light turns on. Turn it off in the notch controls; it switches off after the check.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button(model.cameraHeading.isBusy ? "Waiting for camera permission…" : "Enable camera assistance") { model.enableCameraAssistance() }
                            .disabled(model.cameraHeading.isBusy)
                        Text(model.cameraHeading.status).font(.caption2).foregroundStyle(.secondary)
                    }
                }.modifier(SettingsContentSurface()).tourTarget(.camera)

    }

    @ViewBuilder private var displaysCard: some View {
                VStack(alignment:.leading,spacing:12) {
                    VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Label("Displays",systemImage:"display.2").font(.headline)
                        Spacer()
                        Text("\(model.overlay.availableDisplays.count) connected · \(model.selectedDisplayCount) selected")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Check displays",systemImage:"arrow.clockwise") { model.overlay.refreshDisplays() }
                    }
                    ForEach(model.overlay.availableDisplays) { display in
                        Toggle(isOn:Binding(get:{model.isDisplaySelected(display)},set:{model.selectDisplay(display,selected:$0)})) {
                            Text(display.name)
                        }.toggleStyle(.checkbox)
                    }
                    }.tourTarget(.displays)
                    VStack(alignment:.leading,spacing:12) {
                    Toggle("Block clicks and scrolling while blurred",isOn:$model.blockInput).toggleStyle(.switch).controlSize(.small)
                    if model.blockInput || tour.step == .input {
                        Picker("Block interaction in",selection:$model.blocksEntireDisplay) {
                            Text("Blurred area").tag(false)
                            Text("Entire affected display").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    Text(model.blockInput
                         ? "The clear area stays usable in Blurred area mode. The menu bar and notch controls remain available."
                         : "Choose an area, then turn on blocking to apply it. The menu bar and notch controls remain available.")
                        .font(.caption2).foregroundStyle(.secondary)
                    }.tourTarget(.input)
                }.modifier(SettingsContentSurface())

    }

    @ViewBuilder private var appearanceCard: some View {
                VStack(alignment:.leading,spacing:16) {
                    HStack {
                        Text("Make it feel right").font(.headline)
                        Spacer()
                        Button("Reset defaults",systemImage:"arrow.counterclockwise") { model.resetDefaults() }.controlSize(.small)
                    }
                    Picker("Screen coverage",selection:$model.wholeScreen) {
                        Text("Directional half").tag(false)
                        Text("Whole-screen sweep").tag(true)
                    }.pickerStyle(.segmented).accessibilityLabel("Screen coverage").tourTarget(.coverage)
                    SyncedBlurOnsetDial(model: model, sync: model.headPreviewSync, compact: tour.isActive).tourTarget(.onset)
                    setting("Fully obscured",value:$model.fullAngle,range:model.minimumFullAngle...70,unit:"°").tourTarget(.full)
                    HStack {
                        Toggle("Opaque cover",isOn:$model.opaque).toggleStyle(.switch)
                        Spacer()
                        Toggle("Invert direction",isOn:$model.inverted).toggleStyle(.switch)
                    }.controlSize(.small).tourTarget(.appearance)
                    DisclosureGroup("Fine-tune the animation",isExpanded:$advanced) {
                        VStack(spacing:14) {
                            setting("Blur strength",value:$model.blurPoints,range:8...64,unit:" pt")
                            setting("Soft edge",value:Binding(get:{model.feather*100},set:{model.feather=$0/100}),range:2...30,unit:"%")
                            setting("Response",value:Binding(get:{model.response*1000},set:{model.response=$0/1000}),range:25...200,unit:" ms")
                        }.padding(.top,14)
                    }.font(.subheadline).tourTarget(.tuning)
                }.modifier(SettingsContentSurface())

    }

    @ViewBuilder private var powerCards: some View {
                VStack(alignment:.leading,spacing:12) {
                    VStack(alignment:.leading,spacing:12) {
                    Label("When you remove both AirPods",systemImage:"airpodspro").font(.headline)
                    Text("Choose what happens after the camera checks your seat.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Toggle("Lock when I leave",isOn:$model.sleepDisplaysOnRemoval)
                        .toggleStyle(.switch).controlSize(.small)
                        .accessibilityIdentifier("lock-on-removal")
                    Text("Turn off displays when the camera confirms your seat is empty. On by default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.removalStatus).font(.caption).foregroundStyle(.secondary)
                    }.tourTarget(.removal)
                        VStack(alignment:.leading,spacing:12) {
                        Divider()
                        Toggle("Dim while I stay seated", isOn: $model.dimWhilePresent)
                            .toggleStyle(.switch).controlSize(.small)
                            .accessibilityIdentifier("dim-on-removal")
                        Text("Lower the built-in display's brightness while your seat is occupied. Off until you turn it on.")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.dimWhilePresent || tour.step == .seated {
                            HStack {
                                Text("Screen brightness while seated")
                                Slider(value: $model.removalBrightness, in: 0...0.50, step: 0.01)
                                    .accessibilityLabel("Dimmed brightness")
                                    .accessibilityIdentifier("seated-brightness")
                                Text("\(Int((model.removalBrightness * 100).rounded()))%")
                                    .monospacedDigit().frame(width: 38, alignment: .trailing)
                            }
                            Text(!model.dimWhilePresent
                                ? "Choose a brightness, then turn on Dim while I stay seated to apply it."
                                : model.cameraHeading.isEnabled
                                ? (model.presenceReady ? "Your seat is ready. Turning away is fine. At 0%, the display goes black without locking. Put your AirPods back in to restore brightness when motion resumes." : "Use Set center once to remember your seat before removing AirPods.")
                                : "Enable camera assistance and use Set center to check your seat.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("If dimming makes the camera view too dark, AirVeil explains why, restores your brightness, and keeps checking your seat. It will not dim again during that removal check.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        }.tourTarget(.seated)
                    Divider()
                    AirPodsWearStatus(motion: model.motion)
                    Text("Both options need camera assistance and a saved center. With both off, AirPods removal does not start seat checks. Camera images stay on this Mac and are not recorded or used to identify you.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Keep Automatic Ear Detection on. After tracking is established, removing both AirPods can trigger a check when motion stops for a sustained period or disconnects. AirVeil cannot identify individual earbuds. Tracking interruptions pause blur; use Refresh direction if an automatic check cannot restore it.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(alignment:.top) {
                        Text("macOS controls locking after displays turn off. Set Require password to Immediately in Lock Screen settings to lock as soon as you leave.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Lock Screen settings") { model.openLockScreenSettings() }
                    }
                }.modifier(SettingsContentSurface())

                EnergySettingsView(energy: model.energy, overlay: model.overlay).tourTarget(.energy)

    }

    private func setting(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,unit:String) -> some View {
        HStack {
            Text(title).font(.subheadline).frame(width:126,alignment:.leading)
            Slider(value:value,in:range).accessibilityLabel(title)
            Text(String(format:"%.0f",value.wrappedValue)+unit).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary).frame(width:60,alignment:.trailing)
        }
    }
}


/// Sensor telemetry updates this small control, not the entire Settings tree.
private struct SyncedBlurOnsetDial: View {
    let model: AppModel
    @ObservedObject var sync: HeadPreviewSyncPresentation
    var compact: Bool
    var body: some View {
        BlurOnsetDial(left: Binding(get: { model.leftOnset }, set: { model.leftOnset = $0 }),
                      right: Binding(get: { model.rightOnset }, set: { model.rightOnset = $0 }),
                      liveYaw: sync.snapshot.yaw, syncRequested: sync.snapshot.requested,
                      syncStatus: sync.snapshot.status, compact: compact,
                      toggleSync: {
                          if sync.snapshot.requested { model.stopHeadPreviewSync() }
                          else { model.startHeadPreviewSync() }
                      })
    }
}


private enum SettingsMotion {
    static let reveal = Animation.smooth(duration: 0.24)
}

/// Content is a quiet surface beneath the native glass controls. No live blur
/// is applied to the full card, so stars do not force a large material resample.
private struct SettingsContentSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(
                        colors: dark
                            ? [Color(white: 0.115), Color(white: 0.075)]
                            : [Color(white: 0.99), Color(white: 0.95)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(reduceTransparency ? 1 : 0.96)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(contrast == .increased ? 0.38 : 0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct SettingsPrimaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent).controlSize(.large)
        } else {
            content.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

private struct SettingsSecondaryAction: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).controlSize(.large)
        }
    }
}

private struct SettingsScrollEdge: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}
