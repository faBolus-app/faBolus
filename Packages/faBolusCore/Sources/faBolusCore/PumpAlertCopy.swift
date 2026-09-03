import Foundation

// MARK: - Pump-alert copy overlay

/// The existing pump-alert mirror (`TandemBackend.activeNotifications` → `AlertsView`) already
/// surfaces Control-IQ's own alerts — no new faBolus advisory is added. This is a client-side copy
/// overlay for specific pump alert ids whose decoded name the protocol layer doesn't yet carry, so
/// the mirror still surfaces them with clean, neutral, Tandem-sourced copy instead of a generic
/// `"Alert N"` fallback.
///
/// **Control-IQ High Alert (#50)** — Tandem's own "CIQ increased delivery but glucose is still high"
/// alert: "test your blood glucose and treat as necessary, and check your infusion site." Never
/// upgraded to "give a bolus" (neutral, non-directive copy). Compare **Control-IQ Low Alert (#51)**,
/// which the decode layer already names cleanly — this overlay leaves that one untouched (`resolve`
/// never overrides a real decoded name).
public enum PumpAlertCopyOverlay {
    /// id → (title, detail) for alerts this overlay improves. Pure data; applied only when the caller's
    /// own decoded copy looks like a generic placeholder (see `resolve`).
    static let overlays: [Int: (title: String, detail: String)] = [
        50: (
            "Control-IQ high",
            "Control-IQ increased insulin delivery, but glucose has stayed above 200 mg/dL for 30 "
                + "minutes. Test your blood glucose and treat as necessary, and check your infusion site."
        )
    ]

    /// Resolves the copy to show for a decoded pump alert: the overlay's clean copy when one is defined
    /// for `id` AND `decodedDetail == nil` (the pump-protocol layer's own signal for "this id has no
    /// named entry, rendered as a generic fallback" — see TandemKit's `NotificationBitmap.decode`, which
    /// leaves `detail` `nil` on an unnamed bit); otherwise the decoded copy passes through UNCHANGED, so
    /// a real Tandem-sourced name the decode layer already supplies (e.g. id 51 "Control-IQ low") is
    /// never overridden.
    public static func resolve(id: Int, decodedTitle: String, decodedDetail: String?) -> (title: String, detail: String)
    {
        if decodedDetail == nil, let overlay = overlays[id] {
            return overlay
        }
        return (decodedTitle, decodedDetail ?? "")
    }

    /// Namespace-guarded entry point: the overlay's id-keyed name table is scoped to alerts only, so a
    /// reminder, alarm, malfunction or CGM alert whose id happens to collide with an alert-overlay entry
    /// (e.g. a hardware malfunction at bit 50, the same id as "Control-IQ high") passes straight through
    /// on its own decoded copy instead of borrowing the alert's. `.alert`-kind notifications defer to the
    /// unguarded `resolve` above unchanged.
    public static func resolve(kind: PumpAlertKind, id: Int, decodedTitle: String, decodedDetail: String?)
        -> (title: String, detail: String)
    {
        guard kind == .alert else { return (decodedTitle, decodedDetail ?? "") }
        return resolve(id: id, decodedTitle: decodedTitle, decodedDetail: decodedDetail)
    }
}

/// Neutral, non-directive copy: true when `text` contains an imperative dosing verb that would
/// upgrade a Tandem-sourced alert into directive dosing advice (e.g. "give a bolus").
/// Case-insensitive substring check.
public enum AlertCopyAudit {
    public static let imperativeDosingVerbs = ["bolus", "give insulin", "deliver insulin", "inject", "dose now"]

    /// True when `text` contains any imperative dosing verb/phrase (case-insensitive).
    public static func hasImperativeDosingVerb(_ text: String) -> Bool {
        let lower = text.lowercased()
        return imperativeDosingVerbs.contains { lower.contains($0) }
    }
}
