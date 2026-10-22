import Foundation

/// What the bottom action bar shows on Copy, Compare and Master Report: one
/// sentence, one button title, one symbol and whether the button can be
/// pressed. Each tab keeps its own readiness model; this only maps them.
struct WorkflowActionBarPresentation: Equatable, Sendable {
    /// What is missing, or the ready line. Nil when there is nothing to say.
    let sentence: String?
    let buttonTitle: String
    let symbol: String
    let isEnabled: Bool
    /// The accessibility hint of the underlying Start button, when it has one.
    var hint: String?

    static func make(start: StartButtonPresentation) -> Self {
        // A step that is not done yet carries its instruction in the title
        // ("Choose a source to start"); the bar says it as a sentence and
        // keeps a steady "Start" ("Add to queue" while a transfer runs) button.
        if !start.canStart {
            return Self(
                sentence: start.blocker ?? stepSentence(start.nextStep)
                    ?? (start.title == "Start" ? nil : sentence(from: start.title)),
                buttonTitle: start.action == .addToQueue ? "Add to queue" : "Start",
                symbol: start.symbol,
                isEnabled: false,
                hint: start.accessibilityHint.isEmpty ? nil : start.accessibilityHint
            )
        }
        return Self(
            sentence: start.readyLine,
            buttonTitle: start.title,
            symbol: start.symbol,
            isEnabled: true,
            hint: start.accessibilityHint.isEmpty ? nil : start.accessibilityHint
        )
    }

    static func make(compare: ComparePresentation) -> Self {
        if compare.readiness.canStart {
            return Self(
                sentence: compare.blockMessage,
                buttonTitle: compare.actionTitle,
                symbol: "arrow.left.arrow.right",
                isEnabled: true
            )
        }
        return Self(
            sentence: compare.blockMessage ?? sentence(from: compare.actionTitle),
            buttonTitle: "Check",
            symbol: compare.nextStep == nil ? "arrow.left.arrow.right" : "arrow.up",
            isEnabled: false
        )
    }

    static func make(master: MasterReportPresentation) -> Self {
        if master.canGenerate {
            return Self(
                sentence: nil,
                buttonTitle: master.actionTitle,
                symbol: "doc.richtext",
                isEnabled: true
            )
        }
        return Self(
            sentence: sentence(from: master.actionTitle),
            buttonTitle: "Scan",
            symbol: master.nextStep == .chooseLocation ? "arrow.up" : "doc.richtext",
            isEnabled: false
        )
    }

    private static func stepSentence(_ step: StartButtonPresentation.NextStep?) -> String? {
        switch step {
        case .chooseSource: return "Choose a source to start."
        case .addBackup: return "Add a destination to start."
        // The button title already says it ("Set up the media to start").
        case .prepareCard, nil: return nil
        }
    }

    /// A button title read as a sentence: no period after "…" or another stop.
    private static func sentence(from title: String) -> String {
        guard let last = title.last, !"….!?".contains(last) else { return title }
        return title + "."
    }
}
