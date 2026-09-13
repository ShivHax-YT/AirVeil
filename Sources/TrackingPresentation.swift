import Combine

struct TrackingSnapshot: Equatable {
    var headline = "Desktop effect paused"
    var direction = "Centered · screen clear"
    var angle = 0
    var status = "Waiting for AirPods"
    var source = ""
    var sampleRate = 0
    var canSetCenter = false
    var trackingValid = false
    var hasSavedCenter = false
    var centerBusy = false
}

/// Only the small tracking controls observe telemetry. Motion and animation
/// never invalidate the entire settings hierarchy through AppModel.
@MainActor final class TrackingPresentation: ObservableObject {
    @Published private(set) var snapshot = TrackingSnapshot()
    func update(_ next: TrackingSnapshot) {
        if next != snapshot { snapshot = next }
    }
}
