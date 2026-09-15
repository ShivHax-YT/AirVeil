# Terms and release disclosures research

Reviewed September 14, 2026. These are implementation and drafting notes, not a legal opinion or a certification of compliance.

## Scope and confirmed identity

The user supplied the public developer identity ShivHax-YT, individual developer in Nevada, USA, and public contact shivhax@gmail.com. No company, LLC, postal address, registered agent, paid subscription, support SLA, source-code license, or target-market restriction was invented.

The notice is for downloaders/users of the native app. A public policy remains useful even while the source repository is access-controlled; it travels inside the app and can be read without network access. Distribution visibility must be verified separately.

## Sources and drafting decisions

- [FTC: Marketing Your Mobile App](https://www.ftc.gov/business-guidance/resources/marketing-your-mobile-app-get-it-right-start) emphasizes accurate feature claims, clear disclosures, useful privacy choices, and honoring stated practices. The terms explain visual-overlay and hardware limits alongside feature descriptions rather than promising complete privacy or locking.
- [Nevada NRS Chapter 603A](https://www.leg.state.nv.us/nrs/nrs-603a.html), especially 603A.330, .340, and .345, defines the online-service operator scope and notice/verified-request rules. An individual developer is not automatically outside these rules. Applicability to this offline native app and its separate support/distribution channels depends on the facts; no exemption or universal compliance claim is made. The companion privacy notice identifies a contact and actual data practices.
- [FTC: Consumer Review Fairness Act](https://www.ftc.gov/business-guidance/resources/consumer-review-fairness-act-what-businesses-need-know) supports avoiding restrictions on honest reviews. The terms expressly retain that freedom.
- [FTC: Consumer Reviews and Testimonials Rule Q&A](https://www.ftc.gov/business-guidance/resources/consumer-reviews-testimonials-rule-questions-answers) addresses fake reviews and misleading testimonials. No reviews or testimonials exist in the current app source; none were introduced to the onboarding or policy UI.
- [Apple: CMHeadphoneMotionManager](https://developer.apple.com/documentation/coremotion/cmheadphonemotionmanager) describes headphone motion and the Motion usage description. Motion-session loss is not a public per-ear wear-state guarantee, which is disclosed in product copy and terms.
- [W3C: Animation from Interactions](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html) provides a useful accessibility benchmark. Native macOS Reduce Motion/Reduce Transparency preferences are used for the permission flow. WCAG is not claimed as a completed app-wide certification.

## Contract choices and release review

Terms describe a free binary-use permission and preserve any separately supplied source licenses. They contain no forced arbitration, arbitrary damages cap, automatic future-charge authorization, or blanket waiver of mandatory consumer rights. The drafted Nevada choice-of-law clause preserves mandatory protections elsewhere.

Permission consent is kept specific to each feature; the policy footer is readable before any permission request. A separate generic cookie-acceptance box would be misleading in an app with no browser cookies or tracking SDK. The storage notice still describes native functional records; lack of cookies alone does not settle every jurisdiction's storage rules.

The second-editor source review corrected one material behavior distinction: automatic display management uses confirmed-absence sleep only when camera assistance and seated dimming are both enabled. If either is off, sustained motion loss can request display sleep directly. An uncertain or unavailable seat check does not cause sleep in the camera-presence mode. Terms now state both paths, the separate disable control, the public-motion signal's limits, and dependence on macOS password-on-wake settings.

Remaining legal review is about legal enforceability and jurisdiction-specific obligations, not whether the app has a footer or a checkbox. The developer should have the documents reviewed as distribution markets, pricing, data use, or business structure change. Do not describe these generated drafts as lawyer-approved.
