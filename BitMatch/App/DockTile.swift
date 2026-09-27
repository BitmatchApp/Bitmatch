// DockTile.swift - Transfer progress and the verdict on the Mac Dock icon.
import AppKit
import Combine
import SwiftUI
import BitMatchEngine

/// What the Dock icon shows. While a transfer runs, a ring and a centered
/// percentage; when it ends, the verdict, kept until the next transfer so
/// it is still there when you come back to the Mac.
enum DockTileState: Equatable {
    /// The normal app icon.
    case appIcon
    /// `percent` is 0...100, whole numbers.
    case running(percent: Int)
    case paused(percent: Int)
    /// Every file on every destination verified: the card is safe to erase.
    case verified
    /// Finished, but something needs a look (not verified, or issues).
    case needsReview
    case failed

    static func make(state: OperationState, fraction: Double?) -> DockTileState {
        let percent = Int((min(max(fraction ?? 0, 0), 1) * 100).rounded(.down))
        switch state {
        case .idle, .notStarted:
            return .appIcon
        case .inProgress, .copying, .verifying, .resuming:
            return .running(percent: percent)
        case .paused:
            return .paused(percent: percent)
        case .completed(let info):
            let verdict: CompletionVerdict = info.success
                ? .success
                : info.copiedNotVerified ? .copiedNotVerified : .issues
            return CardSafetyState.make(state: state, verdict: verdict).isSafe ? .verified : .needsReview
        case .failed:
            return .failed
        case .cancelled:
            return .needsReview
        }
    }
}

/// Keeps `NSApp.dockTile` in step with the coordinator.
@MainActor
final class DockTileController {
    private let coordinator: SharedAppCoordinator
    private var cancellables: Set<AnyCancellable> = []
    private var shown: DockTileState = .appIcon

    init(coordinator: SharedAppCoordinator) {
        self.coordinator = coordinator
        coordinator.operationStatePublisher
            .combineLatest(coordinator.liveProgress.$progress)
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] state, progress in
                self?.show(DockTileState.make(state: state, fraction: progress?.overallProgress))
            }
            .store(in: &cancellables)
        coordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateAttentionBadge() }
            }
            .store(in: &cancellables)
    }

    private func show(_ state: DockTileState) {
        updateAttentionBadge()
        guard state != shown else { return }
        shown = state
        let tile = NSApp.dockTile
        if state == .appIcon {
            tile.contentView = nil
        } else {
            // A Dock tile draws a plain NSImageView, not a SwiftUI hosting
            // view, so the tile is rendered to an image first.
            let renderer = ImageRenderer(content: DockTileView(state: state)
                .frame(width: tile.size.width, height: tile.size.height))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            guard let image = renderer.nsImage else { return }
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        }
        tile.display()
    }

    private func updateAttentionBadge() {
        let presentation = coordinator.queuePresentation
        let count = QueueDockBadgePolicy.totalUnresolvedCount(
            rows: presentation.rows,
            reviewedIDs: coordinator.reviewedQueueAttentionIDs,
            standaloneAttentionCount: coordinator.standaloneAttentionRecordIDsSinceLaunch.count
        )
        let label = count == 0 ? nil : String(count)
        guard NSApp.dockTile.badgeLabel != label else { return }
        NSApp.dockTile.badgeLabel = label
        NSApp.dockTile.display()
    }
}

/// The BitMatch mark: twelve segments (bits) around a center. The app icon
/// is every segment lit, blue turning to green, around a check; the Dock
/// tile reuses it, lighting segments as a transfer runs.
struct SegmentRing: View {
    enum Style: Equatable { case progress, verified, warning, failure, paused }

    /// 0...12 segments lit.
    let lit: Int
    let style: Style
    /// Ring thickness as a share of its diameter.
    var thickness: CGFloat = 0.115

    static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let green = Color(red: 0.30, green: 0.88, blue: 0.56)
    static let amber = Color(red: 1.0, green: 0.68, blue: 0.25)
    static let red = Color(red: 1.0, green: 0.38, blue: 0.34)

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let width = side * thickness
            ZStack {
                ForEach(0..<12, id: \.self) { index in
                    Circle()
                        .trim(from: Double(index) / 12 + 0.013, to: Double(index + 1) / 12 - 0.013)
                        .stroke(color(for: index), style: StrokeStyle(lineWidth: width, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .shadow(color: index < lit ? color(for: index).opacity(0.5) : .clear, radius: width * 0.3)
                }
                .padding(width / 2)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func color(for index: Int) -> Color {
        guard index < lit else { return Color.white.opacity(0.09) }
        switch style {
        case .progress:
            return Self.blue
        case .verified: return Self.green
        case .warning: return Self.amber
        case .failure: return Self.red
        case .paused: return Color.white.opacity(0.42)
        }
    }
}

/// The dark rounded tile the icon and the Dock tile sit on.
struct IconTile: View {
    /// true: full bleed (iOS, where the system rounds the corners).
    var fullBleed = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let tile = fullBleed ? side : side * 0.805
            let shape = RoundedRectangle(cornerRadius: fullBleed ? 0 : tile * 0.225, style: .continuous)
            ZStack {
                shape
                    .fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.07)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(
                        // A soft sheen across the top half.
                        shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                                                  startPoint: .top, endPoint: .center))
                    )
                    .overlay(shape.strokeBorder(Color.white.opacity(fullBleed ? 0 : 0.10), lineWidth: side * 0.006))
                    .frame(width: tile, height: tile)
                    .shadow(color: .black.opacity(fullBleed ? 0 : 0.45), radius: side * 0.024, y: side * 0.014)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The app icon's artwork.
struct AppIconArt: View {
    var fullBleed = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let content = fullBleed ? side * 0.84 : side * 0.805
            ZStack {
                IconTile(fullBleed: fullBleed)
                SegmentRing(lit: 12, style: .progress)
                    .frame(width: content * 0.68, height: content * 0.68)
                Image(systemName: "checkmark")
                    .font(.system(size: content * 0.27, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: side * 0.01, y: side * 0.006)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The Dock tile: the app icon's tile and ring, with the percent in the
/// middle while a transfer runs and the verdict when it ends.
struct DockTileView: View {
    let state: DockTileState

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let content = side * 0.805
            ZStack {
                IconTile()
                SegmentRing(lit: lit, style: ringStyle)
                    .frame(width: content * 0.68, height: content * 0.68)
                center(size: content)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    @ViewBuilder
    private func center(size: CGFloat) -> some View {
        switch state {
        case .running(let percent), .paused(let percent):
            VStack(spacing: 0) {
                Text("\(percent)")
                    .font(.system(size: size * (percent == 100 ? 0.21 : 0.26), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(isPaused ? "PAUSED" : "%")
                    .font(.system(size: size * 0.075, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
        case .verified:
            symbol("checkmark", SegmentRing.green, size: size)
        case .needsReview:
            symbol("exclamationmark", SegmentRing.amber, size: size)
        case .failed:
            symbol("xmark", SegmentRing.red, size: size)
        case .appIcon:
            EmptyView()
        }
    }

    private func symbol(_ name: String, _ color: Color, size: CGFloat) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.26, weight: .heavy))
            .foregroundStyle(color)
    }

    private var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// Segments lit: the percent rounded down to twelfths, at least one
    /// once anything has copied.
    private var lit: Int {
        switch state {
        case .running(let percent), .paused(let percent):
            percent <= 0 ? 0 : max(1, percent * 12 / 100)
        case .verified, .needsReview, .failed: 12
        case .appIcon: 0
        }
    }

    private var ringStyle: SegmentRing.Style {
        switch state {
        case .running, .appIcon: .progress
        case .paused: .paused
        case .verified: .verified
        case .needsReview: .warning
        case .failed: .failure
        }
    }
}
