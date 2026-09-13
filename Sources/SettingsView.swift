import SwiftUI
import AppKit

struct VeilPreview: NSViewRepresentable {
    var left: Double
    var right: Double
    var blur: Double
    var feather: Double
    var opaque: Bool
    var shield: Bool
    func makeNSView(context: Context) -> VeilMetalView {
        let view = VeilMetalView(frame: NSRect(x:0,y:0,width:660,height:280))
        view.rendersBaseImage = true
        try? view.setImage(PreviewArt.image)
        return view
    }
    func updateNSView(_ view: VeilMetalView, context: Context) {
        view.setEffect(left:left,right:right,blurPoints:blur,feather:feather,opaque:opaque,shield:shield)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var advanced = false
    private let accent = Color(red:0.18,green:0.43,blue:0.92)
    var body: some View {
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
                    Text(model.enabled ? "ON" : "PAUSED").font(.caption.weight(.bold))
                        .foregroundStyle(model.enabled ? Color.green : Color.secondary)
                        .padding(.horizontal,12).padding(.vertical,7)
                        .background(.quaternary,in:Capsule())
                }
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Label(model.headline,systemImage:model.shielded ? "exclamationmark.shield" : "airpodspro")
                            .font(.headline)
                        Spacer()
                        Text(String(format:"%+.0f°",model.simulate && !model.enabled ? model.previewYaw : model.effectiveYaw))
                            .font(.system(.title3,design:.rounded).monospacedDigit().weight(.semibold))
                    }
                    VeilPreview(left:model.strengths.left,right:model.strengths.right,blur:model.blurPoints,
                                feather:model.feather,opaque:model.opaque || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                                shield:model.shielded || (model.enabled && !model.overlay.isReady))
                        .frame(height:280).clipShape(RoundedRectangle(cornerRadius:14))
                        .overlay(RoundedRectangle(cornerRadius:14).stroke(.primary.opacity(0.08)))
                        .accessibilityLabel("Directional blur preview. " + model.direction)
                    HStack {
                        Text(model.direction).font(.subheadline.weight(.medium))
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
                    VStack(alignment:.leading,spacing:10) {
                        Label("Head tracking",systemImage:"airpodspro").font(.headline)
                        Text(model.motion.status).font(.caption).foregroundStyle(.secondary).frame(minHeight:34,alignment:.topLeading)
                        HStack {
                            Button(model.motion.isRunning ? "Reconnect" : "Connect AirPods") { model.connectMotion() }
                            Button(model.calibrating ? "Hold still…" : "Set center") { model.calibrate() }.disabled(!model.motion.isFresh || model.calibrating)
                        }.controlSize(.large)
                        if model.motion.isFresh {
                            Text(String(format:"%.0f samples/s · %@",model.motion.sampleRate,model.motion.sourceName))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                    Divider()
                    VStack(alignment:.leading,spacing:10) {
                        Label("Desktop access",systemImage:"display").font(.headline)
                        Text(model.permissionGranted ? "Screen capture allowed. Frames stay on this Mac." : "Allow screen capture for live blur. Preview needs no permission.")
                            .font(.caption).foregroundStyle(.secondary).frame(minHeight:34,alignment:.topLeading)
                        HStack {
                            Button(model.permissionGranted ? "Check access" : "Allow screen capture") {
                                if model.permissionGranted { model.refreshPermission() } else { model.requestScreenPermission() }
                            }.controlSize(.large)
                        }
                        Text(model.overlay.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

                VStack(alignment:.leading,spacing:16) {
                    HStack {
                        Text("Make it feel right").font(.headline)
                        Spacer()
                        Button("Reset defaults",systemImage:"arrow.counterclockwise") { model.resetDefaults() }.controlSize(.small)
                    }
                    Picker("Screen coverage",selection:$model.wholeScreen) {
                        Text("Directional half").tag(false)
                        Text("Whole screen").tag(true)
                    }.pickerStyle(.segmented).accessibilityLabel("Screen coverage")
                    setting("Starts blurring",value:$model.onset,range:0...25,unit:"°")
                    setting("Fully obscured",value:$model.fullAngle,range:26...70,unit:"°")
                    HStack {
                        Toggle("Opaque cover",isOn:$model.opaque).toggleStyle(.switch)
                        Spacer()
                        Toggle("Invert direction",isOn:$model.inverted).toggleStyle(.switch)
                    }.controlSize(.small)
                    DisclosureGroup("Fine-tune the animation",isExpanded:$advanced) {
                        VStack(spacing:14) {
                            setting("Blur strength",value:$model.blurPoints,range:8...64,unit:" pt")
                            setting("Soft edge",value:Binding(get:{model.feather*100},set:{model.feather=$0/100}),range:2...30,unit:"%").disabled(model.wholeScreen)
                            setting("Response",value:Binding(get:{model.response*1000},set:{model.response=$0/1000}),range:25...200,unit:" ms")
                        }.padding(.top,14)
                    }.font(.subheadline)
                }.padding(20).background(.background,in:RoundedRectangle(cornerRadius:20))

                HStack(spacing:12) {
                    Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    Spacer()
                    if model.enabled || model.starting {
                        Button("Pause & clear screen") { model.pause() }.buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Button("Enable desktop effect") { model.enable() }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!model.motion.isFresh || !model.motion.isCalibrated)
                    }
                }
                HStack(alignment:.top) {
                    Text("Blur affects everyone viewing this screen. If tracking stops while enabled, an opaque cover appears until you pause or recalibrate.")
                    Spacer()
                    Text(model.pauseHint).fixedSize()
                }.font(.caption2).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth:800)
        }
        .background(Color(nsColor:.windowBackgroundColor))
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
