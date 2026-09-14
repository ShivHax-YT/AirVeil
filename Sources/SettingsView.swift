import SwiftUI
import AppKit
import Combine

struct VeilPreview: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> VeilMetalView {
        let view = VeilMetalView(frame: NSRect(x:0,y:0,width:660,height:280))
        view.rendersBaseImage = true
        try? view.setImage(PreviewArt.image)
        model.previewFrame = { [weak view, weak model] strengths in
            guard let view, let model else { return }
            Self.update(view, model: model, strengths: strengths)
        }
        model.previewVisibility = { [weak view] visible in view?.renderingEnabled = visible }
        Self.update(view, model: model, strengths: model.strengths)
        return view
    }
    func updateNSView(_ view: VeilMetalView, context: Context) {
        Self.update(view, model: model, strengths: model.strengths)
    }
    static func dismantleNSView(_ view: VeilMetalView, coordinator: ()) { view.renderingEnabled = false }
    private static func update(_ view: VeilMetalView, model: AppModel, strengths: VeilStrength) {
        view.setEffect(left: strengths.left, right: strengths.right, blurPoints: model.blurPoints,
            feather: model.feather, opaque: model.opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            shield: model.shielded || (model.enabled && !model.overlay.isReady), wholeScreen: model.wholeScreen)
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
        Button("Enable blur") { model.enable() }.buttonStyle(.borderedProminent).controlSize(.large)
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
    let model: AppModel
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Label("Head tracking",systemImage:"airpodspro").font(.headline)
            Text(presentation.snapshot.status).font(.caption).foregroundStyle(.secondary)
                .frame(minHeight:34,alignment:.topLeading)
            Text("Detected automatically when worn").font(.caption2).foregroundStyle(.secondary)
            Label(presentation.snapshot.hasSavedCenter ? "Screen direction saved" : "Set your screen direction",
                  systemImage:presentation.snapshot.hasSavedCenter ? "scope" : "viewfinder")
                .font(.caption.weight(.medium))
            Text(model.cameraHeading.isEnabled ? "Face straight ahead within 5°. A brief camera and AirPods check establishes center after setup or reinsertion." : "AirPods can change their reference after removal. Use Set center again, or enable camera assistance below.")
                .font(.caption2).foregroundStyle(.secondary)
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

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tour: SettingsTour
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var advanced = false
    @State private var advancedBeforeTour = false
    private let accent = Color(red:0.18,green:0.43,blue:0.92)
    var body: some View {
        ScrollViewReader { proxy in
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:14) {
                    Image(systemName:"circle.lefthalf.filled")
                        .font(.system(size:30,weight:.medium)).foregroundStyle(.white)
                        .frame(width:58,height:58).background(accent,in:RoundedRectangle(cornerRadius:17))
                    VStack(alignment:.leading,spacing:4) {
                        Text("AirVeil").font(.system(size:30,weight:.bold))
                        Text("A screen that follows your attention.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !tour.isActive {
                        Button("Take a tour") { tour.replay() }.controlSize(.large)
                    }
                    Text(model.enabled ? "BLUR ON" : "BLUR PAUSED").font(.caption.weight(.bold))
                        .foregroundStyle(model.enabled ? Color.green : Color.secondary)
                        .padding(.horizontal,12).padding(.vertical,7)
                        .background(.quaternary,in:Capsule())
                }.tourTarget(.welcome)
                VStack(alignment:.leading,spacing:12) {
                    TrackingHeader(presentation:model.presentation)
                    VeilPreview(model:model)
                        .frame(height:280).clipShape(RoundedRectangle(cornerRadius:14))
                        .overlay(RoundedRectangle(cornerRadius:14).stroke(.primary.opacity(0.08)))
                        .accessibilityLabel("Directional blur preview").tourTarget(.preview)
                    HStack {
                        TrackingDirection(presentation:model.presentation)
                        Spacer()
                        Text(model.simulate && !model.enabled ? "SIMULATED PREVIEW" : "AIRPODS PREVIEW")
                            .font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                    }
                    if !model.enabled {
                        Toggle("Simulate a head turn",isOn:$model.simulate).toggleStyle(.switch).controlSize(.small)
                        if model.simulate {
                            HStack {
                                Text("Right").font(.caption).foregroundStyle(.secondary)
                                Slider(value:$model.previewYaw,in:-60...60).accessibilityLabel("Simulated head angle")
                                Text("Left").font(.caption).foregroundStyle(.secondary)
                                Button("Center") { model.previewYaw = 0 }.controlSize(.small)
                            }
                        }
                    }
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

                HStack(alignment:.top,spacing:16) {
                    HeadTrackingControls(presentation:model.presentation,model:model).tourTarget(.tracking)
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Label("Live blur access",systemImage:"display").font(.headline)
                        Text(model.permissionGranted ? "Screen capture allowed. Frames stay on this Mac." : "Allow screen capture for live blur. Preview needs no permission.")
                            .font(.caption).foregroundStyle(.secondary).frame(minHeight:34,alignment:.topLeading)
                        HStack {
                            Button(model.checkingAccess ? "Checking…" : (model.permissionGranted ? "Check access" : "Allow screen capture")) {
                                model.requestScreenPermission()
                            }.controlSize(.large).disabled(model.checkingAccess)
                        }
                        Text("Screen Recording permission is only needed for live blur. AirPod removal, seated blackout and display off work without it.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(model.overlay.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth:.infinity,alignment:.leading).tourTarget(.access)
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

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
                        Text("Face straight ahead, within 5° of center, and hold briefly. Each check finishes in one pass. If your face needs more light, the notch offers Face light. It starts off and switches off after the check.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Button(model.cameraHeading.isBusy ? "Waiting for camera permission…" : "Enable camera assistance") { model.enableCameraAssistance() }
                            .disabled(model.cameraHeading.isBusy)
                        Text(model.cameraHeading.status).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20)).tourTarget(.camera)

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
                    if model.blockInput {
                        Picker("Block interaction in",selection:$model.blocksEntireDisplay) {
                            Text("Blurred area").tag(false)
                            Text("Entire affected display").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    Text("The clear area stays usable in Blurred area mode. AirVeil controls and the menu bar remain available.")
                        .font(.caption2).foregroundStyle(.secondary)
                    }.tourTarget(.input)
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

                VStack(alignment:.leading,spacing:12) {
                    Label("When you take off your AirPods",systemImage:"moon.zzz").font(.headline)
                    Toggle("Automatically manage displays when AirPods are removed",isOn:$model.sleepDisplaysOnRemoval)
                        .toggleStyle(.switch).controlSize(.small).tourTarget(.removal)
                    Text(model.removalStatus).font(.caption).foregroundStyle(.secondary)
                    if model.sleepDisplaysOnRemoval {
                        AirPodsWearStatus(motion: model.motion)
                        Toggle("Dim while I am still seated", isOn: $model.dimWhilePresent)
                            .toggleStyle(.switch).controlSize(.small)
                        if model.dimWhilePresent {
                            HStack {
                                Text("Screen brightness while seated")
                                Slider(value: $model.removalBrightness, in: 0...0.50, step: 0.01)
                                    .accessibilityLabel("Dimmed brightness")
                                Text("\(Int((model.removalBrightness * 100).rounded()))%")
                                    .monospacedDigit().frame(width: 38, alignment: .trailing)
                            }
                            Text(model.cameraHeading.isEnabled
                                ? (model.presenceReady ? "Your seat is ready. Turning away is fine. At 0%, the display goes black without locking. Put an AirPod back in to restore your brightness." : "Use Set center once to remember your seat before removing AirPods.")
                                : "Enable camera assistance and use Set center to check your seat.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("The built-in camera stays on while AirPods are removed. Foreground position and size help exclude background or side occupants. No identity recognition or recordings. If you leave, or the view cannot be confirmed, displays turn off. Only the built-in display is dimmed.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Keep Automatic Ear Detection on. Removing either AirPod starts the check when its in-ear status is available. Idle audio, device switching, and unavailable in-ear status do not start removal checks. Tracking interruptions pause the blur; use Refresh direction to resume.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack(alignment:.top) {
                        Text("To require a password when the displays wake, set Require password to Immediately in your Mac’s Lock Screen settings.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Lock Screen settings") { model.openLockScreenSettings() }
                    }
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

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
                    BlurOnsetDial(left: $model.leftOnset, right: $model.rightOnset).tourTarget(.onset)
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
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

                HStack(spacing:12) {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    if model.enabled || model.starting {
                        Button("Pause & clear screen") { model.pause() }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        EnableEffectButton(presentation:model.presentation,model:model)
                    }
                }.tourTarget(.ready)
                HStack(alignment:.top) {
                    Text("Blur affects everyone viewing a selected display. Tracking loss pauses the blur. Camera assistance needs a clear view of your face; manual mode needs Set center after an interrupted reference.")
                    Spacer()
                    Text(model.pauseHint).fixedSize()
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth:800)
        }
        .scrollDisabled(tour.isActive)
        .allowsHitTesting(!tour.isActive)
        .accessibilityHidden(tour.isActive)
        .overlayPreferenceValue(TourAnchorKey.self) { anchors in
            if let step = tour.step {
                GeometryReader { geometry in
                    TourSpotlight(rect: anchors[step].map { geometry[$0] })
                }
            }
        }
        .clipped()
        if tour.isActive { SettingsTourCard(tour: tour).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .onChange(of: tour.step) { old, step in
            if old == nil, step != nil { advancedBeforeTour = advanced }
            if step == .tuning { advanced = true }
            if let step {
                // Let disclosure/layout changes settle before resolving the target.
                DispatchQueue.main.async {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(step, anchor: .center) }
                }
            } else { advanced = advancedBeforeTour }
        }
        .onAppear {
            if let step = tour.step { proxy.scrollTo(step, anchor: .center) }
        }
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: tour.isActive)
        .frame(minWidth:740,idealWidth:800,minHeight:660,idealHeight:850)
        .onAppear { model.refreshPermission() }
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
