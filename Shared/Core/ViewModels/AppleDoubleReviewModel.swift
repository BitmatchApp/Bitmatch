import Foundation
import Combine
import BitMatchEngine

/// Owns the preview scan. Source changes invalidate the old review at once;
/// Start independently re-proves these paths in the engine before any writes.
@MainActor
final class AppleDoubleReviewModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            if !replaying { defaults.set(enabled, forKey: "BitMatchExcludeAppleDouble") }
            if oldValue != enabled { refresh(source: source) }
        }
    }
    @Published private(set) var paths: [String]?
    @Published private(set) var error: String?
    var replaying = false
    private let defaults: UserDefaults
    private var source: URL?
    private var generation = 0
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "BitMatchExcludeAppleDouble")
    }
    deinit { task?.cancel() }

    var summaryLine: String? {
        guard enabled, let paths else { return nil }
        return paths.isEmpty ? "No AppleDouble companions will be excluded" : "\(paths.count) AppleDouble source \(paths.count == 1 ? "file" : "files") will be excluded. Keep the source."
    }

    var readinessIssue: String? {
        guard enabled, source != nil else { return nil }
        return error ?? (paths == nil ? "Reviewing AppleDouble exclusions…" : nil)
    }

    func refresh(source: URL?) {
        task?.cancel()
        generation += 1
        let token = generation
        self.source = source
        paths = nil
        error = nil
        guard enabled, let source else { return }
        task = Task { [weak self] in
            let scanner = Task.detached {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                return try AppleDoubleSelection.review(source: source)
            }
            do {
                let found = try await withTaskCancellationHandler {
                    try await scanner.value
                } onCancel: { scanner.cancel() }
                guard !Task.isCancelled, let self, self.generation == token else { return }
                paths = found
            } catch is CancellationError {
                // A superseded preview must not publish either paths or an error.
            } catch {
                guard !Task.isCancelled, let self, self.generation == token else { return }
                self.error = "Could not review AppleDouble exclusions: \(error.localizedDescription)"
            }
        }
    }
}
