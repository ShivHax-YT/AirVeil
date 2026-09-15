# Permission onboarding: consent and accessibility review

Reviewed September 14, 2026. This is an implementation review, not a legal opinion or accessibility certification.

## Permission choices

Apple recommends requesting protected access when its purpose is clear and respecting the person's decision. The permission cards explain Camera, Screen Recording, and Motion & Fitness separately. They do not start normal capture or tracking. Camera alignment and seat checks, live desktop blur, and head tracking each have a specific consequence when declined. The operating system's authorization result remains the authority; clicking an AirVeil button never counts as a grant. [Apple HIG: Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy), [Apple: User privacy and data use](https://developer.apple.com/app-store/user-privacy-and-data-use/)

The user specifically requested scrolling before acceptance. This is a review affordance, **not evidence that someone read, understood, or legally consented to every paragraph**. Only Allow/Continue with access is gated. Continue without access remains available immediately; a person can decline all three permissions, complete setup, and use the simulated preview. Denial has a neutral status and a Settings route. Returning to the app refreshes real OS status, and unfinished choices survive relaunch. This avoids turning explanation into coerced permission. [Apple: User privacy and data use](https://developer.apple.com/app-store/user-privacy-and-data-use/)

Headphone motion has no separate documented request-access API. Its explicit Allow action briefly starts a Core Motion request session and stops that session on resolution, cancellation, or timeout. Normal tracking remains gated until permission choices are complete and the tutorial starts tracking or finishes. No Bluetooth permission is required by the current public-motion implementation. [Apple: CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager)

## Keyboard and assistive technology

Use native buttons and a native scroll view. A keyboard-accessible Scroll to the end button moves the actual scroll position, so an inaccessible pointer gesture is not required. Back, decline, status refresh, and offline policy links remain reachable. Hidden side cards are removed from hit testing and accessibility. Each active heading receives VoiceOver focus; semantic heading traits and status labels accompany icons. Inactive visual cards must not create duplicate focus destinations. [W3C: Keyboard](https://www.w3.org/WAI/WCAG22/Understanding/keyboard.html), [W3C: No Keyboard Trap](https://www.w3.org/WAI/WCAG22/Understanding/no-keyboard-trap.html), [W3C: Focus Order](https://www.w3.org/WAI/WCAG22/Understanding/focus-order.html)

WCAG supplies useful engineering checks here; its web criteria are not a claim of native macOS conformance. Native render checks can verify layout and scroll gating, but they do not replace a VoiceOver and Full Keyboard Access pass in the actual app.

## Motion, transparency, and readability

The requested card choreography is decorative. When Reduce Motion is enabled, phase changes do not animate, decorative perspective rotation is removed, and the scroll shortcut jumps without animation. Reduce Transparency replaces the frosted card with an opaque pale background. Dark text on pale cards, white text on the black stage, a fixed 44-point primary target, and explicit status text preserve hierarchy without depending on color alone. [W3C: Animation from Interactions](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html), [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Apple: Testing system accessibility features](https://developer.apple.com/documentation/accessibility/testing-system-accessibility-features-in-your-app)

## Verification boundary

Controller tests use a fake provider and isolated UserDefaults. Native offscreen renders use that fake provider, including denied/unverified/unavailable states; no OS permission prompts, sensor sessions, or desktop capture are invoked. Verify the real permission prompt sequence, screen-access restart, keyboard focus, VoiceOver announcements, and system accessibility settings in the installed app separately.

## Follow-up visual refinement

The user requested lighter translucent white panels and slower, more natural card movement. The content cards now use an ultra-thin native material with a restrained white tint and edge highlights. This keeps macOS 14 support. Apple's current HIG places Liquid Glass primarily in the navigation/control layer and standard materials in content surfaces, so the large reading panels retain standard material. Reduced Transparency stays opaque; Increased Contrast strengthens the tint. Collapsed cards have their own icon/label composition, uniform scaling, and mild perspective, avoiding compressed text. [Apple: Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
