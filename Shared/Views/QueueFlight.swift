import SwiftUI

/// Positions the Mac uses to carry a card from the composer down into its new
/// queue row. Both are reported in one named space so a single overlay can
/// animate between them; platforms that don't define the space ignore them.
enum QueueFlightSpace {
    static let name = "bitmatch.queue-flight"
}

struct ComposerFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct QueueRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct HiddenQueueRowKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The queue row a flying card is about to land on; it stays invisible
    /// until the card arrives so the two read as one object.
    var hiddenQueueRowID: UUID? {
        get { self[HiddenQueueRowKey.self] }
        set { self[HiddenQueueRowKey.self] = newValue }
    }
}
