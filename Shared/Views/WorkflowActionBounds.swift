import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Layout evidence for viewport action tests. These preferences have no
/// storage, access grants or transfer behavior.
enum WorkflowActionRole: Hashable, Sendable { case primary, cancel }
struct WorkflowActionBoundsPreferenceKey: PreferenceKey {
    static let defaultValue: [WorkflowActionRole: CGRect] = [:]
    static func reduce(value: inout [WorkflowActionRole: CGRect], nextValue: () -> [WorkflowActionRole: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Environment observation crosses a native sheet boundary, unlike a parent
/// preference reader. Nil in normal use; no app or transfer state is recorded.
private struct WorkflowActionBoundsObserverKey: EnvironmentKey {
    static let defaultValue: (@Sendable (WorkflowActionRole, CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var workflowActionBoundsObserver: (@Sendable (WorkflowActionRole, CGRect) -> Void)? {
        get { self[WorkflowActionBoundsObserverKey.self] }
        set { self[WorkflowActionBoundsObserverKey.self] = newValue }
    }
}

private struct WorkflowActionBounds: ViewModifier {
    @Environment(\.workflowActionBoundsObserver) private var observer
    let role: WorkflowActionRole
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                Color.clear.preference(key: WorkflowActionBoundsPreferenceKey.self, value: [role: frame])
                    .overlay {
                        #if canImport(UIKit)
                        if let observer { WorkflowActionWindowBounds(role: role, observer: observer) }
                        #endif
                    }
            }
        }
    }
}

#if canImport(UIKit)
/// Native sheets have a separate SwiftUI global coordinate space. Convert to
/// their actual window instead, so a sheet target cannot pass using root bounds.
private struct WorkflowActionWindowBounds: UIViewRepresentable {
    let role: WorkflowActionRole
    let observer: @Sendable (WorkflowActionRole, CGRect) -> Void
    func makeUIView(context: Context) -> BoundsView { BoundsView(role: role, observer: observer) }
    func updateUIView(_ view: BoundsView, context: Context) {
        view.observer = observer
        view.setNeedsLayout()
    }
    final class BoundsView: UIView {
        let role: WorkflowActionRole
        var observer: @Sendable (WorkflowActionRole, CGRect) -> Void
        init(role: WorkflowActionRole, observer: @escaping @Sendable (WorkflowActionRole, CGRect) -> Void) {
            self.role = role
            self.observer = observer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if let window { observer(role, convert(bounds, to: window)) }
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func workflowActionBounds(_ role: WorkflowActionRole, enabled: Bool = true) -> some View {
        if enabled {
            modifier(WorkflowActionBounds(role: role))
        } else {
            self
        }
    }
}
