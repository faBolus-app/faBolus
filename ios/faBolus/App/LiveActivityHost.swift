import ActivityKit
import Foundation
import PhoneApp
import WidgetContent

/// The glucose Live Activity through ActivityKit. iOS lets an app start one only from the foreground, so a
/// background update without one running waits for the next foreground. `LiveActivityPlan` decides which
/// listed card to keep, so an ended card iOS still shows never sits beside a new one.
@MainActor
final class LiveActivityHost: LiveActivityHosting {
    private var lastContent: LiveActivityContent?
    private let starts = StartTimes()

    private static var listed: [Activity<GlucoseActivityAttributes>] { Activity<GlucoseActivityAttributes>.activities }

    private static func isLive(_ activity: Activity<GlucoseActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    var isRunning: Bool { Self.listed.contains(where: Self.isLive) }
    var anyListed: Bool { !Self.listed.isEmpty }

    func show(_ content: LiveActivityContent, staleDate: Date?, appActive: Bool) {
        let activities = Self.listed
        starts.keepOnly(activities.map(\.id))
        let plan = LiveActivityPlan.decide(
            activities.map { .init(id: $0.id, isLive: Self.isLive($0), startedAt: starts.startedAt($0.id)) },
            appActive: appActive, now: Date())
        // A replacement that can't be started mustn't take the card it replaces away.
        if plan.start, !ActivityAuthorizationInfo().areActivitiesEnabled { return }
        if !plan.end.isEmpty {
            NSLog("Live Activity: ending %@ of %@", plan.end, Self.describe(activities))
            endNow(plan.end)
        }
        let update = ActivityContent(state: content, staleDate: staleDate)
        if let id = plan.update {
            guard content != lastContent || !plan.end.isEmpty else { return }
            lastContent = content
            // Looked up again off the main actor: an `Activity` can't be handed across.
            Task.detached { await Self.find(id)?.update(update) }
            return
        }
        guard plan.start else { return }
        lastContent = nil
        do {
            let started = try Activity.request(attributes: GlucoseActivityAttributes(), content: update, pushType: nil)
            starts.record(started.id, at: Date())
            lastContent = content
            NSLog("Live Activity: started %@", started.id)
        } catch {
            NSLog("Live Activity not started: %@", String(describing: error))
        }
    }

    func end() {
        lastContent = nil
        let ids = Self.listed.map(\.id)
        guard !ids.isEmpty else { return }
        NSLog("Live Activity: ending %@", ids)
        endNow(ids)
    }

    /// Ends each one and takes it off the screen at once, an ended card still showing included.
    private func endNow(_ ids: [String]) {
        Task.detached {
            for id in ids { await Self.find(id)?.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func describe(_ activities: [Activity<GlucoseActivityAttributes>]) -> String {
        activities.map { "\($0.id) \($0.activityState)" }.joined(separator: ", ")
    }

    private nonisolated static func find(_ id: String) -> Activity<GlucoseActivityAttributes>? {
        Activity<GlucoseActivityAttributes>.activities.first { $0.id == id }
    }
}

/// When this app started each Live Activity, which ActivityKit doesn't say, kept across launches so a card
/// nearing iOS's 8-hour end can be replaced after a relaunch too.
@MainActor
private final class StartTimes {
    private static let key = "liveActivityStartTimes"
    private var times: [String: Double]

    init() {
        times = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
    }

    func startedAt(_ id: String) -> Date? { times[id].map(Date.init(timeIntervalSince1970:)) }

    func record(_ id: String, at date: Date) {
        times[id] = date.timeIntervalSince1970
        save()
    }

    /// Forgets the ones iOS no longer lists.
    func keepOnly(_ ids: [String]) {
        let kept = times.filter { ids.contains($0.key) }
        guard kept.count != times.count else { return }
        times = kept
        save()
    }

    private func save() { UserDefaults.standard.set(times, forKey: Self.key) }
}
