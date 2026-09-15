import SwiftUI
import AppKit

struct PermissionOnboardingView: View {
    @ObservedObject var onboarding: PermissionOnboarding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    private var transition: Animation? { reduceMotion ? nil : .spring(response: 0.90, dampingFraction: 0.90) }

    var body: some View {
        GeometryReader { geometry in
            let cardWidth = min(520.0, max(390.0, geometry.size.width - 240))
            let cardHeight = min(550.0, max(430.0, geometry.size.height - 170))
            VStack(spacing: 0) {
                header
                    .padding(.top, 24).padding(.horizontal, 32).padding(.bottom, 12)
                ZStack {
                    ForEach(Array(AirVeilPermission.allCases.enumerated()), id: \.element.id) { index, permission in
                        permissionCard(permission, index: index, width: cardWidth, height: cardHeight)
                    }
                    if onboarding.phase == .welcome {
                        welcome(width: cardWidth)
                            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                    }
                    if onboarding.phase == .summary {
                        summary(width: cardWidth)
                            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.96)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                LegalFooter().padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(PermissionStarfieldBackground())
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .frame(minWidth: 740, idealWidth: 800, minHeight: 660, idealHeight: 850)
        .animation(transition, value: onboarding.phase)
        .onAppear { onboarding.refresh(); headingFocused = true }
        .onChange(of: onboarding.phase) { _, _ in headingFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in onboarding.refresh() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 22, weight: .medium))
                Text("AirVeil").font(.system(size: 20, weight: .semibold))
            }.foregroundStyle(.white)
            Spacer()
            Text(onboarding.currentIndex.map { "Permission \($0 + 1) of 3" } ?? "A little setup. Then your space.")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.72))
        }
    }

    private func permissionCard(_ permission: AirVeilPermission, index: Int, width: CGFloat, height: CGFloat) -> some View {
        let selected = onboarding.currentPermission == permission
        let activeIndex = onboarding.currentIndex ?? (onboarding.phase == .summary ? 3 : -1)
        let past = index < activeIndex
        let rank = max(0, past ? activeIndex - index - 1 : index - activeIndex - 1)
        let offset = selected ? 0 : (past ? -1.0 : 1.0) * (width / 2 + 28 + Double(rank) * 32)
        let depthScale = max(0.72, 0.90 - Double(rank) * 0.08)
        return Group {
            if selected {
                PermissionConsentCard(onboarding: onboarding, permission: permission)
            } else {
                // A separate compact composition keeps the label and corners
                // natural as the full permission card moves into the stack.
                VStack(spacing: 12) {
                    Image(systemName: permission.symbol).font(.system(size: 30, weight: .light))
                    Text(permission.title).font(.system(size: 13, weight: .medium))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 106)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: past ? .leading : .trailing)
                .padding(20)
                .modifier(PermissionGlassSurface())
            }
        }
        .frame(width: selected ? width : 216, height: selected ? height : height * 0.72)
        .scaleEffect(selected ? 1 : depthScale)
        .rotation3DEffect(.degrees(reduceMotion || selected ? 0 : (past ? -1 : 1) * (12 + Double(rank) * 2)),
                          axis: (x: 0, y: 1, z: 0), perspective: 0.28)
        .offset(x: offset, y: selected ? 0 : 8 + Double(rank) * 24)
        .opacity(selected ? 1 : (onboarding.phase == .welcome ? 0.34 : max(0.30, 0.46 - Double(rank) * 0.07)))
        .blur(radius: selected ? 0 : (onboarding.phase == .welcome ? 3.0 : 2.4) + Double(rank) * 0.3)
        .zIndex(selected ? 10 : Double(3 - rank))
        .allowsHitTesting(selected)
        .accessibilityHidden(!selected)
    }

    private func welcome(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "hand.raised").font(.system(size: 32, weight: .light)).foregroundStyle(.black.opacity(0.85))
            VStack(alignment: .leading, spacing: 10) {
                Text("Ready to enable\npermissions?")
                    .font(.system(size: 32, weight: .semibold)).tracking(-0.6)
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Text("Three short cards explain what AirVeil needs and what stays on your Mac. You choose what to allow.")
                    .font(.system(size: 14)).lineSpacing(4).foregroundStyle(.black.opacity(0.78))
            }
            Button(action: { onboarding.begin() }) {
                HStack { Text("Review permissions"); Spacer(); Image(systemName: "arrow.right") }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minHeight: 44).padding(.horizontal, 16)
                    .foregroundStyle(.white).background(.black.opacity(0.88), in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("permission-begin")
            Text("Nothing starts until you choose.")
                .font(.system(size: 12)).foregroundStyle(.black.opacity(0.68))
        }
        .padding(32).frame(width: width)
        .modifier(PermissionGlassSurface())
        .zIndex(20)
    }

    private func summary(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "checkmark.circle").font(.system(size: 34, weight: .light))
            VStack(alignment: .leading, spacing: 10) {
                Text("Your choices are set.").font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Text("Next, try AirVeil at your own pace. You can review these permissions again in Settings.")
                    .font(.system(size: 14)).lineSpacing(3).foregroundStyle(.black.opacity(0.78))
            }
            VStack(spacing: 16) {
                ForEach(AirVeilPermission.allCases) { permission in
                    let allowed = onboarding.choices[permission] == .allowed && onboarding.status(for: permission).authorization.allowsAccess
                    HStack(spacing: 12) {
                        Image(systemName: permission.symbol).frame(width: 24)
                        Text(permission.title)
                        Spacer()
                        Label(allowed ? "Allowed" : "Not enabled", systemImage: allowed ? "checkmark" : "minus")
                            .foregroundStyle(.black.opacity(allowed ? 1 : 0.65))
                    }.font(.system(size: 13, weight: .medium))
                }
            }.padding(.vertical, 6)
            Button(action: { onboarding.finish() }) {
                HStack { Text("Start the tour"); Spacer(); Image(systemName: "arrow.right") }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minHeight: 44).padding(.horizontal, 16)
                    .foregroundStyle(.white).background(.black.opacity(0.88), in: Capsule())
            }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("permission-finish")
            Button("Back to permissions") { onboarding.back() }
                .buttonStyle(.plain).font(.system(size: 13)).frame(minHeight: 44)
                .foregroundStyle(.black.opacity(0.78))
        }
        .padding(32).frame(width: width)
        .modifier(PermissionGlassSurface()).zIndex(20)
    }
}

private struct PermissionGlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.black.opacity(0.88))
            .tint(.black)
            .background {
                if reduceTransparency {
                    RoundedRectangle(cornerRadius: 26).fill(Color(white: 0.94))
                } else if #available(macOS 26.0, *) {
                    // Let the real background pass through the system glass.
                    // The regular variant preserves legibility for this text-heavy card.
                    RoundedRectangle(cornerRadius: 26).fill(.clear)
                        .glassEffect(.regular.tint(.white.opacity(contrast == .increased ? 0.28 : 0.10)),
                                     in: RoundedRectangle(cornerRadius: 26))
                } else {
                    RoundedRectangle(cornerRadius: 26).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 26).fill(.white.opacity(contrast == .increased ? 0.50 : 0.18)))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 26).stroke(
                LinearGradient(colors: [.white.opacity(reduceTransparency ? 1 : 0.72),
                                        .white.opacity(reduceTransparency ? 1 : 0.14),
                                        .white.opacity(reduceTransparency ? 1 : 0.42)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .environment(\.colorScheme, .light)
    }
}

private struct PermissionEndPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PermissionConsentCard: View {
    @ObservedObject var onboarding: PermissionOnboarding
    let permission: AirVeilPermission
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var detailsFocused: Bool
    private var snapshot: PermissionAccessSnapshot { onboarding.status(for: permission) }
    private var reviewed: Bool { onboarding.reviewed.contains(permission) }
    private var requesting: Bool { onboarding.requestingPermission == permission }
    private var settingsRequired: Bool { snapshot.authorization == .denied || snapshot.authorization == .restricted }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: permission.symbol).font(.system(size: 27, weight: .light))
                    .frame(width: 44, height: 44).background(.black.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(permission.title).font(.system(size: 25, weight: .semibold)).tracking(-0.4)
                        .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                    Text(permission.subtitle).font(.system(size: 12)).foregroundStyle(.black.opacity(0.74))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }.padding(.bottom, 18)
            permissionDetails
            Divider().overlay(.black.opacity(0.1)).padding(.top, 12).padding(.bottom, 12)
            footer
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PermissionGlassSurface())
        .onAppear { headingFocused = true }
    }

    private var permissionDetails: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(permission.sections.enumerated()), id: \.offset) { _, section in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(section.title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                                    Text(section.detail).font(.system(size: 13)).lineSpacing(4)
                                        .foregroundStyle(.black.opacity(0.79))
                                }
                            }
                            Text(permission.skipConsequence).font(.system(size: 12, weight: .medium)).lineSpacing(3)
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                            Text("End of permission details")
                                .font(.system(size: 11)).foregroundStyle(.black.opacity(0.6))
                                .id("permission-end")
                                .background(GeometryReader { end in
                                    Color.clear.preference(key: PermissionEndPositionKey.self,
                                        value: end.frame(in: .named(permission.rawValue)).maxY)
                                })
                        }.padding(.trailing, 8).padding(.bottom, 2)
                    }
                    .coordinateSpace(name: permission.rawValue)
                    .focusable().focused($detailsFocused)
                    .accessibilityLabel("\(permission.title) permission details")
                    .accessibilityHint("Scroll to the end to enable Allow. You can choose to continue without access at any time.")
                    .onPreferenceChange(PermissionEndPositionKey.self) { bottom in
                        if bottom.isFinite && bottom <= viewport.size.height + 2 && bottom >= 0 {
                            onboarding.markReviewed(permission)
                        }
                    }
                }
                if !reviewed {
                    Button {
                        detailsFocused = true
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                            proxy.scrollTo("permission-end", anchor: .bottom)
                        }
                    } label: {
                        Label("Scroll to the end to enable Allow", systemImage: "arrow.down")
                            .font(.system(size: 11, weight: .medium)).frame(minHeight: 44)
                    }.buttonStyle(.plain).foregroundStyle(.black.opacity(0.72))
                        .accessibilityIdentifier("permission-read-to-end")
                } else {
                    Label("Details reviewed", systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.black.opacity(0.7)).frame(height: 44)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                if requesting { ProgressView().controlSize(.small).tint(.black) }
                else { Image(systemName: snapshot.authorization.allowsAccess ? "checkmark.circle.fill" : "circle") }
                Text(requesting ? "Waiting for macOS…" : snapshot.authorization.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if !requesting && snapshot.authorization != .notDetermined {
                    Button("Check again") { onboarding.refresh() }
                        .buttonStyle(.plain).font(.system(size: 11)).frame(minHeight: 44)
                        .accessibilityIdentifier("permission-check-again")
                    if permission == .screenRecording && snapshot.authorization == .notGranted {
                        Button("System Settings") { onboarding.openCurrentSettings() }
                            .buttonStyle(.plain).font(.system(size: 11)).frame(minHeight: 44)
                            .disabled(!reviewed)
                            .accessibilityLabel("Open Screen Recording in System Settings")
                            .accessibilityIdentifier("permission-system-settings")
                    }
                }
            }.foregroundStyle(.black.opacity(0.82)).accessibilityElement(children: .contain)
            if let message = snapshot.message {
                Text(message).font(.system(size: 11)).lineSpacing(2).foregroundStyle(.black.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            Button(action: primaryAction) {
                HStack {
                    Text(primaryTitle); Spacer()
                    Image(systemName: snapshot.authorization.allowsAccess ? "arrow.right" : (settingsRequired ? "arrow.up.right" : "plus"))
                }
                .font(.system(size: 13, weight: .semibold)).frame(minHeight: 44).padding(.horizontal, 16)
                .foregroundStyle(.white).background(.black.opacity(reviewed && !requesting ? 0.88 : 0.22), in: Capsule())
            }.buttonStyle(.plain).disabled(!reviewed || requesting).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("permission-primary")
                .accessibilityHint(reviewed ? "" : "Scroll to the end of the permission details first.")
            HStack(spacing: 12) {
                Button("Back") { onboarding.back() }.disabled(requesting).frame(minHeight: 44).contentShape(Rectangle())
                    .accessibilityIdentifier("permission-back")
                Spacer(minLength: 0)
                Button(permission.skipTitle) { onboarding.continueWithoutAccess() }.disabled(requesting).frame(minHeight: 44).contentShape(Rectangle())
                    .accessibilityIdentifier("permission-skip")
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.black.opacity(0.78))
            .frame(minHeight: 44)
        }
    }
    private var primaryTitle: String {
        if requesting { return "Waiting for macOS…" }
        if snapshot.authorization.allowsAccess { return "Continue" }
        if settingsRequired { return "Open System Settings" }
        if snapshot.authorization == .unavailable || snapshot.message != nil { return "Try again" }
        return permission.allowTitle
    }
    private func primaryAction() {
        if snapshot.authorization.allowsAccess { onboarding.continueWithAccess() }
        else if settingsRequired { onboarding.openCurrentSettings() }
        else { Task { await onboarding.requestCurrentPermission() } }
    }
}
