import SwiftUI

/// The first-run notification disclosure. MANDATORY, and shown exactly once — at first launch, not
/// on the first pump alert — because the Urgent (break-through-Focus) rung should not be merely
/// theoretical by the time it might ever fire.
///
/// This is INFORMATIONAL, not a caution: it tells the user the rung exists. It does NOT warn that
/// they might miss an alarm, because the pump remains the primary, FDA-approved safety annunciator
/// on its own screen — faBolus is a convenience mirror, never the only line of defense. Breakthrough
/// copy is best-effort ("when allowed"), never a promise ("will"), because even a build carrying the
/// time-sensitive capability can have it disabled by the user in iOS Settings; and a build WITHOUT
/// the capability never offers the rung this copy describes at all — the Notification Settings
/// screen (`NotificationSettingsView`) hides it in that case, so this screen never promises something
/// the settings screen would then contradict.
struct NotificationDisclosureView: View {
    /// Called once, when the user dismisses the disclosure — the caller marks it shown.
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("About faBolus Notifications")
                .font(.title2).bold()
            Text(
                "Your pump alarms and alerts on its own screen — that's what keeps you safe, with or "
                    + "without a paired phone. faBolus mirrors some of those alerts here as a convenience, "
                    + "and its own alerts for a few things only faBolus can see (like an unresolved bolus)."
            )
            .multilineTextAlignment(.leading)
            .foregroundStyle(.secondary)
            Text(
                "One rung on faBolus's notification ladder can break through Focus and Do Not Disturb, "
                    + "when allowed by iOS. You choose whether any category uses it — and every other "
                    + "rung — in Notification Settings, anytime."
            )
            .multilineTextAlignment(.leading)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Got it") { onDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}

/// The one-shot "has this been shown" gate for `NotificationDisclosureView`. Scoped to this file
/// (mirrors the shape of `AppSettings`'s own one-time-ack shims — a nil/absent-until-shown marker —
/// without adding a new stored property to `AppSettings` itself).
enum NotificationDisclosureGate {
    private static let shownAtKey = "notificationDisclosureFirstRunShownAt"

    /// `true` once the disclosure has been shown at least once, on this install.
    static var hasShown: Bool {
        UserDefaults.standard.object(forKey: shownAtKey) != nil
    }

    /// Record that the disclosure has been shown. Idempotent — calling it again just refreshes the
    /// timestamp, never un-shows it.
    static func markShown() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: shownAtKey)
    }
}
