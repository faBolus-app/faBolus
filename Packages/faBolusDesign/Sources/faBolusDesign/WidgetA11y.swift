import CoreGraphics

/// Shared accessibility/hit-target constants + VoiceOver label builders for the interactive
/// Quick-Bolus widget's dose ± steppers and 1-2-3 in-place confirm circles.
///
/// Lives here — not inside `faBolusWidgets` — because `faBolusAppTests` depends on `target: faBolus`
/// + `package: faBolusCore`/`faBolusDesign` (project.yml) but does NOT link the `faBolusWidgets`
/// app-extension target, so the widget's SwiftUI views are not directly reachable/behaviorally
/// testable from that suite. `faBolusWidgets` already links `faBolusDesign` directly, so putting the
/// size constant + label copy here lets `QuickBolusWidgetA11yTests` assert against the EXACT values
/// the widget renders, instead of a duplicated test-only constant that could silently drift from
/// the real UI.
public enum WidgetA11y {
    /// Apple's documented minimum tappable control size (Human Interface Guidelines) — the dose ±
    /// steppers and 1-2-3 confirm circles must each be at least this size on a side.
    public static let minHitTarget: CGFloat = 44

    /// VoiceOver label for a −/+ amount stepper. `unitLabel` is the mode's unit word ("units"/"grams");
    /// `step` is the increment for that mode (`WidgetBolusStore.increment`/`carbIncrement`).
    public static func stepperLabel(increasing: Bool, step: Double, unitLabel: String) -> String {
        "\(increasing ? "Increase" : "Decrease") bolus by \(formattedStep(step)) \(unitLabel)"
    }

    /// VoiceOver hint for a −/+ amount stepper — names the control's role, not just repeats the label.
    public static let stepperHint = "Adjusts the bolus amount before confirming"

    /// VoiceOver label for one of the 1-2-3 in-place confirm circles. `step` is 1, 2, or 3; `done`
    /// mirrors the circle's filled/unfilled visual state (progress already reached this step).
    public static func confirmStepLabel(step: Int, done: Bool) -> String {
        let ordinal = ["one", "two", "three"][max(0, min(2, step - 1))]
        return done ? "Confirm step \(ordinal), completed" : "Confirm step \(ordinal) of 3"
    }

    /// VoiceOver hint for a 1-2-3 confirm circle — step 3 delivers, 1/2 only advance the sequence.
    public static func confirmStepHint(step: Int) -> String {
        step == 3 ? "Delivers the bolus" : "Advances the confirm sequence; a wrong tap resets it"
    }

    private static func formattedStep(_ step: Double) -> String {
        step.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(step))
            : String(format: "%.2f", step)
    }
}
