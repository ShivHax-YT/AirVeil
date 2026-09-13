import AppKit
import SwiftUI
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var window: NSWindow!
    private var item: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotHandler: EventHandlerRef?
    private var diagnosticTimer: Timer?
    private var globalPauseActivations = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:min(850,screen.height-70)),
                          styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "AirVeil"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width:740,height:660)
        window.level = .normal
        window.contentView = NSHostingView(rootView:SettingsView(model:model))
        window.center()
        model.showWindow = { [weak self] in self?.showSettings() }
        model.stateChanged = { [weak self] in self?.refreshStatus() }
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        refreshStatus(); configureAppMenu(); installHotKey(); showSettings()
        model.startMotionAutomatically()
        if let index = CommandLine.arguments.firstIndex(of:"--diagnostics"),CommandLine.arguments.count > index+1 {
            let path = CommandLine.arguments[index+1]
            diagnosticTimer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
                Task { @MainActor in self?.writeDiagnostics(path) }
            }
        }
    }
    private func configureAppMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle:"AirVeil Settings…",action:#selector(showSettings),keyEquivalent:",").target = self
        appMenu.addItem(withTitle:"Pause & Clear Screen",action:#selector(pause),keyEquivalent:"p").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit AirVeil",action:#selector(quit),keyEquivalent:"q").target = self
        appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title:model.headline,action:nil,keyEquivalent:""); status.isEnabled = false; menu.addItem(status)
        menu.addItem(withTitle:model.motion.status,action:nil,keyEquivalent:"").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle:model.pauseShortcutAvailable ? "Pause & Clear Screen  ⌃⌥⌘P" : "Pause & Clear Screen",action:#selector(pause),keyEquivalent:"").target = self
        let center = menu.addItem(withTitle:"Set Center",action:#selector(calibrate),keyEquivalent:""); center.target=self; center.isEnabled=model.motion.isFresh && !model.calibrating
        if !model.enabled {
            let enable = menu.addItem(withTitle:"Enable Desktop Effect",action:#selector(enable),keyEquivalent:"")
            enable.target=self; enable.isEnabled=model.motion.isCalibrated && model.motion.isFresh && model.selectedDisplayCount > 0
        }
        menu.addItem(withTitle:"Settings…",action:#selector(showSettings),keyEquivalent:",").target=self
        menu.addItem(.separator())
        menu.addItem(withTitle:"Quit AirVeil",action:#selector(quit),keyEquivalent:"q").target=self
    }
    private func refreshStatus() {
        window?.level = model.enabled || model.starting ? NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1) : .normal
        item?.button?.image=NSImage(systemSymbolName:model.shielded ? "exclamationmark.shield.fill" : "circle.lefthalf.filled",accessibilityDescription:"AirVeil")
        item?.button?.title = model.enabled ? " On" : ""
        item?.button?.toolTip = model.headline + " · " + model.pauseHint
    }
    @objc func showSettings() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true); model.refreshPermission() }
    @objc private func pause() { model.pause() }
    @objc private func calibrate() { model.calibrate() }
    @objc private func enable() { model.enable() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification:Notification) {
        diagnosticTimer?.invalidate(); model.shutdown()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotHandler { RemoveEventHandler(hotHandler) }
    }
    private func installHotKey() {
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _,_,context in
            guard let context else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                delegate.globalPauseActivations += 1
                delegate.model.pause()
            }
            return noErr
        },1,&type,pointer,&hotHandler)
        guard result == noErr else { model.message = "Global pause shortcut unavailable. Use the AirVeil menu to pause."; return }
        let id=EventHotKeyID(signature:0x4156524C,id:1)
        if RegisterEventHotKey(UInt32(kVK_ANSI_P),UInt32(controlKey|optionKey|cmdKey),id,GetApplicationEventTarget(),0,&hotKey) != noErr {
            model.message = "Global pause shortcut is already in use. Use the AirVeil menu to pause."
        } else { model.pauseShortcutAvailable = true }
    }
    private func writeDiagnostics(_ path:String) {
        let snapshot:[String:Any] = ["timestamp":Date().timeIntervalSince1970,
            "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
            "referenceJumpCount":model.motion.referenceJumpCount,"lastReferenceJump":model.motion.lastReferenceJump,
            "activeDisplayCount":model.overlay.activeDisplayCount,
            "selectedDisplayCount":model.selectedDisplayCount,"connectedDisplayCount":model.overlay.availableDisplays.count,
            "blockedPointerEventCount":model.overlay.blockedPointerEventCount,
            "blockInput":model.blockInput,"blocksEntireDisplay":model.blocksEntireDisplay,
            "sleepDisplaysOnRemoval":model.sleepDisplaysOnRemoval,"removalStatus":model.removalStatus,
            "motionConnectionState":model.motion.connectionState.rawValue,"disconnectEventCount":model.motion.disconnectEventCount,
            "displaySleepRequestCount":model.displaySleepRequestCount,
            "referenceState":model.motion.referenceState.rawValue,"hasSavedCenter":model.motion.hasSavedCenter,
            "referenceUsable":model.motion.referenceUsable,
            "centerRevision":model.motion.centerRevision,
            "reportedHeadingDegrees":model.motion.reportedHeadingDegrees,
            "reportedMagneticAccuracy":model.motion.reportedMagneticAccuracy,
            "wholeScreen":model.wholeScreen,"leftStrength":model.strengths.left,"rightStrength":model.strengths.right,
            "captureReady":model.overlay.isReady,"motionStatus":model.motion.status,
            "motionFresh":model.motion.isFresh,"calibrated":model.motion.isCalibrated,"motionRunning":model.motion.isRunning,
            "yawDegrees":model.effectiveYaw,"addedDeliveryLag":model.motion.addedDeliveryLag,"sampleRate":model.motion.sampleRate,"source":model.motion.sourceName,
            "captureStatus":model.overlay.status,"captureRunning":model.overlay.isRunning,"enabled":model.enabled,
            "shielded":model.shielded,"screenPermission":model.permissionGranted,"captureErrorDetails":model.captureErrorDetails,
            "globalPauseRegistered":hotKey != nil,"globalPauseActivations":globalPauseActivations]
        if let data=try? JSONSerialization.data(withJSONObject:snapshot,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:URL(fileURLWithPath:path),options:.atomic)
        }
    }
}
