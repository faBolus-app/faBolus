import ActivityKit
import Foundation
import PhoneApp
import WidgetContent

/// The glucose Live Activity through ActivityKit. iOS lets an app start one only from the foreground, so a
/// background update without one running waits for the next foreground.
@MainActor
final class LiveActivityHost: LiveActivityHosting {
    private var activity: Activity<GlucoseActivityAttributes>? {
        Activity<GlucoseActivityAttributes>.activities.first {
            $0.activityState == .active || $0.activityState == .stale
        }
    }
    private var lastContent: LiveActivityContent?

    var isRunning: Bool { activity != nil }

    func show(_ content: LiveActivityContent, staleDate: Date?, appActive: Bool) {
        let update = ActivityContent(state: content, staleDate: staleDate)
        if let activity {
            guard content != lastContent else { return }
            lastContent = content
            let id = activity.id
            // Looked up again off the main actor: an `Activity` can't be handed across.
            Task.detached { await Self.find(id)?.update(update) }
            return
        }
        guard appActive, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: GlucoseActivityAttributes(), content: update, pushType: nil)
            lastContent = content
        } catch {
            NSLog("Live Activity not started: %@", String(describing: error))
        }
    }

    func end() {
        lastContent = nil
        let ids = Activity<GlucoseActivityAttributes>.activities.map(\.id)
        Task.detached {
            for id in ids { await Self.find(id)?.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private nonisolated static func find(_ id: String) -> Activity<GlucoseActivityAttributes>? {
        Activity<GlucoseActivityAttributes>.activities.first { $0.id == id }
    }
}
