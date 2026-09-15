import AppKit
import SwiftUI
import Carbon
import ScreenCaptureKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var model: AppModel!
    private let onboarding = PermissionOnboarding(provider: SystemPermissionOnboardingProvider())
    private let tour = SettingsTour(startImmediately: false)
    private var window: AirVeilSettingsWindow!
    private var item: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotHandler: EventHandlerRef?
    private var diagnosticTimer: Timer?
    private var permissionBackgroundTickCount = 0
    private var permissionBackgroundElapsed: TimeInterval = 0
    private var lockObservers: [NSObjectProtocol] = []
    private var terminationPending = false
    private var globalPauseActivations = 0
    private var lastIconName: String?
    private var notch: NotchOverlayController?
    private var settingsVisibleAtLaunch = false
    private var diagnosticCaptureExclusion = "Not checked"
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        model.sessionLockState = Self.isScreenLocked
        let lockCenter = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            lockObservers.append(lockCenter.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    // A lock notification can only pause. An unlock hint must
                    // also agree with the current WindowServer session state.
                    let locked = notification.name.rawValue == "com.apple.screenIsLocked" || Self.isScreenLocked()
                    self?.model.handleScreenLock(locked)
                }
            })
        }
        if !onboarding.isActive { tour.beginIfNeeded() }
        model.permissionSetupActive = onboarding.isActive
        model.motionAccessAllowedByOnboarding = onboarding.headTrackingChoiceAllowsMotion
        model.startupTourActive = onboarding.isActive || tour.isActive
        onboarding.onBegin = { [weak self] in
            guard let self else { return }
            model.startupTourActive = true
            model.permissionSetupActive = true
            model.pause()
            model.motion.stop()
            model.cameraHeading.setSessionActive(false)
            tour.suspendForPermissions()
        }
        onboarding.onFinish = { [weak self] in
            guard let self else { return }
            model.motionAccessAllowedByOnboarding = onboarding.headTrackingChoiceAllowsMotion
            model.startupTourActive = true
            model.permissionSetupActive = false
            if onboarding.cameraChoiceAllowsAssistance {
                if !model.cameraHeading.isEnabled {
                    model.cameraHeading.setSessionActive(!Self.isScreenLocked())
                    model.enableCameraAssistance()
                }
            } else {
                model.disableCameraAssistance()
            }
            tour.replay()
        }
        model.showPermissionSetup = { [weak self] in
            guard let self else { return }
            onboarding.replay()
            showSettings()
        }
        tour.onFinish = { [weak self] in
            guard let self, !onboarding.isActive, model.startupTourActive else { return }
            model.startupTourActive = false
            model.startMotionAutomatically()
        }
        // Restore any previously owned brightness immediately; sensor startup
        // waits for the welcome tour, while restoration must never wait on UI.
        model.prepareAfterLaunch()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
        window = AirVeilSettingsWindow(contentRect:NSRect(x:0,y:0,width:800,height:min(850,screen.height-70)))
        window.delegate = self
        var backgroundTick: ((TimeInterval) -> Void)?
        if CommandLine.arguments.contains("--diagnostics") {
            backgroundTick = { [weak self] elapsed in
                guard let self else { return }
                permissionBackgroundTickCount += 1
                permissionBackgroundElapsed = elapsed
            }
        }
        window.contentView = NSHostingView(rootView:AirVeilSetupView(model:model,tour:tour,onboarding:onboarding,
                                                                   onBackgroundAnimationTick:backgroundTick))
        window.center()
        model.overlay.registerSettingsWindow(window)
        model.showWindow = { [weak self] in self?.showSettings() }
        model.stateChanged = { [weak self] in self?.refreshStatus() }
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        notch = NotchOverlayController(model: model)
        refreshStatus(); configureAppMenu(); installHotKey()
        model.setPreviewVisible(false)
        if onboarding.isActive || tour.isActive || CommandLine.arguments.contains("--settings") { showSettings() }
        settingsVisibleAtLaunch = window.isVisible
        if !onboarding.isActive && !tour.isActive { model.startMotionAutomatically() }
        if let index = CommandLine.arguments.firstIndex(of:"--diagnostics"),CommandLine.arguments.count > index+1 {
            let path = CommandLine.arguments[index+1]
            diagnosticTimer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
                Task { @MainActor in self?.writeDiagnostics(path) }
            }
        }
        if CommandLine.arguments.contains("--verify-capture-exclusion") {
            Task {
                guard CGPreflightScreenCaptureAccess() else {
                    diagnosticCaptureExclusion = "Skipped: existing screen permission required"
                    return
                }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    diagnosticCaptureExclusion = content.applications.contains { $0.processID == ProcessInfo.processInfo.processIdentifier }
                        ? "Own application available for exclusion" : "Own application missing"
                } catch { diagnosticCaptureExclusion = "Check failed: \(error.localizedDescription)" }
            }
        }
    }
    private func configureAppMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle:"AirVeil Settings…",action:#selector(showSettings),keyEquivalent:",").target = self
        appMenu.addItem(withTitle:"Pause & Clear Screen",action:#selector(pause),keyEquivalent:"p").target = self
        appMenu.addItem(withTitle:"Show Notch Controls",action:#selector(showNotch),keyEquivalent:"").target = self
        #if AIRVEIL_DEVELOPMENT
        appMenu.addItem(withTitle:"Preview Notch Animation",action:#selector(previewNotch),keyEquivalent:"").target = self
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Hide AirVeil",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        let hideOthers = appMenu.addItem(withTitle:"Hide Others",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle:"Show All",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit AirVeil",action:#selector(quit),keyEquivalent:"q").target = self
        appItem.submenu = appMenu; menu.addItem(appItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title:model.headline,action:nil,keyEquivalent:""); status.isEnabled = false; menu.addItem(status)
        menu.addItem(withTitle:model.headTrackingStatus,action:nil,keyEquivalent:"").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle:model.pauseShortcutAvailable ? "Pause & Clear Screen  ⌃⌥⌘P" : "Pause & Clear Screen",action:#selector(pause),keyEquivalent:"").target = self
        let center = menu.addItem(withTitle:"Set Center",action:#selector(calibrate),keyEquivalent:""); center.target=self; center.isEnabled = !onboarding.isActive && model.motion.isFresh && !model.centerBusy
        if !model.enabled {
            let enable = menu.addItem(withTitle:"Enable Desktop Blur",action:#selector(enable),keyEquivalent:"")
            enable.target=self; enable.isEnabled = !onboarding.isActive && model.canRequestEnable && model.selectedDisplayCount > 0
        }
        menu.addItem(withTitle:"Settings…",action:#selector(showSettings),keyEquivalent:",").target=self
        menu.addItem(withTitle:"Show Notch Controls",action:#selector(showNotch),keyEquivalent:"").target=self
        #if AIRVEIL_DEVELOPMENT
        let preview = menu.addItem(withTitle:"Preview Notch Animation",action:#selector(previewNotch),keyEquivalent:"")
        preview.target=self; preview.isEnabled = !model.cameraHeading.isBusy
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle:"Quit AirVeil",action:#selector(quit),keyEquivalent:"q").target=self
    }
    private func refreshStatus() {
        notch?.updateControls()
        let icon = model.shielded ? "exclamationmark.shield.fill" : "circle.lefthalf.filled"
        if lastIconName != icon {
            item?.button?.image = NSImage(systemSymbolName:icon,accessibilityDescription:"AirVeil")
            lastIconName = icon
        }
        let title = model.enabled ? " On" : ""
        if item?.button?.title != title { item?.button?.title = title }
        let tip = model.headline + " · " + model.pauseHint
        if item?.button?.toolTip != tip { item?.button?.toolTip = tip }
    }
    @objc func showSettings() {
        window.showSettings()
        model.overlay.settingsWindowDidBecomeVisible()
        model.setPreviewVisible(!onboarding.isActive); model.refreshPermission()
        onboarding.refresh()
    }
    func windowWillClose(_ notification: Notification) {
        if onboarding.isActive { onboarding.cancelPendingRequest() }
        else { tour.finish() }
        model.stopHeadPreviewSync()
        model.setPreviewVisible(false)
    }
    func windowDidMiniaturize(_ notification: Notification) {
        model.stopHeadPreviewSync()
        model.setPreviewVisible(false)
    }
    func windowDidDeminiaturize(_ notification: Notification) { updatePreviewVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updatePreviewVisibility() }
    private func updatePreviewVisibility() {
        let visible = !onboarding.isActive && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        if visible { model.overlay.settingsWindowDidBecomeVisible() }
        model.setPreviewVisible(visible)
    }
    @objc private func pause() { model.pause() }
    @objc private func calibrate() { if !onboarding.isActive { model.calibrate() } }
    @objc private func enable() { if !onboarding.isActive { model.enable() } }
    @objc private func showNotch() { notch?.showControls() }
    #if AIRVEIL_DEVELOPMENT
    @objc private func previewNotch() { notch?.previewAnimation() }
    #endif
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool { showSettings(); return true }
    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        guard session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return true }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        onboarding.cancelPendingRequest()
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification) {
        onboarding.cancelPendingRequest()
        for observer in lockObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        lockObservers.removeAll()
        diagnosticTimer?.invalidate(); notch?.shutdown(); model.shutdown()
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
            "permissionSetupActive":onboarding.isActive,
            "wearAirPodsPrompt":model.wearAirPodsPrompt,
            "automaticFeaturesPaused":model.automaticFeaturesPaused,
            "sessionState":model.sessionDiagnosticState,
            "recentSessionEvents":model.recentSessionEvents,
            "headPreviewSyncRequested":model.headPreviewSync.snapshot.requested,
            "headPreviewSyncStatus":model.headPreviewSync.snapshot.status,
            "headPreviewSyncYaw":model.headPreviewSync.snapshot.yaw as Any? ?? NSNull(),
            "permissionBackgroundTickCount":permissionBackgroundTickCount,
            "permissionBackgroundElapsed":permissionBackgroundElapsed,
            "motionAllowedBySetup":model.motionAccessAllowedByOnboarding,
            "tutorialActive":tour.isActive,
            "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown",
            "referenceJumpCount":model.motion.referenceJumpCount,"lastReferenceJump":model.motion.lastReferenceJump,
            "activeDisplayCount":model.overlay.activeDisplayCount,
            "selectedDisplayCount":model.selectedDisplayCount,"connectedDisplayCount":model.overlay.availableDisplays.count,
            "blockedPointerEventCount":model.overlay.blockedPointerEventCount,
            "blockInput":model.blockInput,"blocksEntireDisplay":model.blocksEntireDisplay,
            "sleepDisplaysOnRemoval":model.sleepDisplaysOnRemoval,"removalStatus":model.removalStatus,
            "dimWhilePresent":model.dimWhilePresent,"removalBrightness":model.removalBrightness,
            "presenceReady":model.presenceReady,"presencePhase":model.removalPresence.phase.rawValue,
            "presenceState":model.presence.state.rawValue,"presenceCameraRunning":model.presence.isRunning,
            "presenceAssistLightOn":model.presence.isAssistLightOn,
            "presenceLowLight":model.presence.isLowLight,
            "lowLightRecoveryState":model.removalPresence.lowLightRecoveryState.rawValue,
            "presenceStatus":model.presence.status,"displayDimmed":model.dimming.isDimmed,
            "brightnessRestorePending":model.dimming.hasPendingRestore,"brightnessStatus":model.dimming.status,
            "brightnessOriginal":model.dimming.restorationSnapshot?.baseline as Any? ?? NSNull(),
            "brightnessLastApplied":model.dimming.restorationSnapshot?.lastApplied as Any? ?? NSNull(),
            "brightnessPendingTarget":model.dimming.restorationSnapshot?.pendingTarget as Any? ?? NSNull(),
            "brightnessRequiresWakeRestore":model.dimming.restorationSnapshot?.requiresWakeRestore as Any? ?? NSNull(),
            "brightnessAwaitingWakeStability":model.dimming.awaitingWakeStability,
            "brightnessLastRestoreReading":model.dimming.lastRestoreObservedBrightness as Any? ?? NSNull(),
            "brightnessRestorationDecision":model.dimming.lastRestorationDecision,
            "displayIdleSleepPrevented":model.dimming.keepsDisplayAwake,
            "motionConnectionState":model.motion.connectionState.rawValue,"disconnectEventCount":model.motion.disconnectEventCount,
            "removalEventCount":model.motion.removalEventCount,"removalConnectionState":model.motion.removalConnectionState.rawValue,
            "wearStatus":model.motion.wearStatus,
            "automaticReturnCheckCount":model.cameraHeading.automaticReturnCheckCount,
            "wearDiagnosticStatus":model.motion.wearDiagnosticStatus,"leftBlurOnset":model.leftOnset,"rightBlurOnset":model.rightOnset,
            "displaySleepRequestCount":model.displaySleepRequestCount,
            "referenceState":model.motion.referenceState.rawValue,"hasSavedCenter":model.motion.hasSavedCenter,
            "referenceUsable":model.motion.referenceUsable,
            "centerRevision":model.motion.centerRevision,
            "cameraAssistance":model.cameraHeading.isEnabled,
            "cameraRunning":model.cameraHeading.camera.isRunning,
            "faceLightOn":model.cameraHeading.camera.isAssistLightOn,
            "cameraCenterRevision":model.cameraHeading.centerRevision,
            "cameraHasCenteredSetup":model.cameraHeading.hasCenter,
            "cameraAlignmentRevision":model.cameraHeading.alignmentRevision,
            "cameraStatus":model.cameraHeading.status,
            "notchPhase":model.cameraHeading.coach.phase.rawValue,
            "notchTitle":model.cameraHeading.coach.title,
            "notchMotionSource":model.cameraHeading.notchMotion.snapshot.source.rawValue,
            "notchYawDegrees":model.cameraHeading.notchMotion.snapshot.yawDegrees.map { $0 as Any } ?? NSNull(),
            "notchYawScreenRelative":model.cameraHeading.notchMotion.snapshot.isScreenRelative,
            "notchDirectionKnown":model.cameraHeading.notchMotion.snapshot.directionKnown,
            "notchVisible":notch?.presentation.expanded ?? false,
            "notchWearReminderVisible":(notch?.presentation.expanded == true && notch?.presentation.wearAirPodsPrompt == true),
            "notchBrightnessStage":notch?.presentation.brightnessRecovery.rawValue ?? "none",
            "settingsVisible":window?.isVisible ?? false,
            "settingsWindowLevel":window?.level.rawValue ?? -1,
            "applicationActivationPolicy":NSApp.activationPolicy().rawValue,
            "settingsCaptureStatus":model.overlay.settingsCaptureStatus,
            "notchWindowLevel":notch?.windowLevel ?? -1,
            "settingsVisibleAtLaunch":settingsVisibleAtLaunch,
            "captureExclusionPreflight":diagnosticCaptureExclusion,
            "trackingValid":model.trackingValid,
            "drawSubmissionCount":model.overlay.drawSubmissionCount,
            "sourceBlitCount":model.overlay.sourceBlitCount,
            "gaussianPassCount":model.overlay.gaussianPassCount,
            "redrawRequestCount":model.overlay.redrawRequestCount,
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
