# Trackpad feedback

App controls use AppKit's `NSHapticFeedbackManager.defaultPerformer`: level-change feedback for button actions and accepted toggle/selection changes, alignment ticks for slider detents, and generic feedback at slider endpoints. Settings, permissions, legal documents, the tour, and notch buttons share the same wrapper while keeping native SwiftUI controls, glass styles, accessibility, and disabled behavior.

Slider feedback is quantized to approximately 40 positions (respecting existing steps) and limited to one pulse per 45 ms. Values remain continuous; no timers, delayed pulses, gesture overlays, or sensor observers are added. The onset dial now follows direct manipulation without a trailing interpolation. Programmatic model updates remain silent.

Appearance → Trackpad feedback is enabled by default and persisted as a UserDefaults boolean through AppStorage. No database, serialization schema, or UIKit bridge is needed for this preference. Window chrome and operating-system-owned controls retain system behavior.

Validation: `scripts/test-haptics.sh` injects a clock and performer to verify detents, endpoints, reversals, rate limiting, rejected/duplicate/external writes, opt-out, and value precision. Permissions and dial rendering checks also pass. These checks establish integration and scheduling behavior, not physical trackpad sensation. Supported hardware and a finger touching the trackpad are needed to assess the final feel; macOS controls actual feedback delivery.

Reference: [Apple — perform(_:performanceTime:)](https://developer.apple.com/documentation/appkit/nshapticfeedbackperformer/perform(_:performancetime:)).
