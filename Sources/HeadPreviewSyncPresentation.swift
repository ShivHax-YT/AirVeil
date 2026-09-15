import Combine

struct HeadPreviewSyncSnapshot: Equatable {
    var requested = false
    var status = "Sync with your head to see this illustration follow your turns."
    /// Camera-aligned head direction, before the optional blur inversion.
    /// Positive is a left turn; nil means that no live alignment is usable.
    var yaw: Double?
}

/// Only the small head illustration observes this live pose, not all Settings.
@MainActor final class HeadPreviewSyncPresentation: ObservableObject {
    @Published private(set) var snapshot = HeadPreviewSyncSnapshot()
    func update(_ value: HeadPreviewSyncSnapshot) {
        if snapshot != value { snapshot = value }
    }
}
