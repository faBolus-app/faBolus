import Foundation
import WidgetContent
import faBolusCore

/// The widgets' snapshot from what the app shows, and when to ask WidgetKit to re-read it.
public enum WidgetPublisher {
    /// The most points a snapshot carries for a sparkline (two hours at five minutes).
    public static let maxPoints = 24

    @MainActor public static func snapshot(
        display: PumpState, provenance: GlucoseProvenance, sourceName: String?, history: [GlucoseReading],
        lastAutoCorrection: Date?, settings: AppSettings, freshness: FreshnessThresholds, now: Date
    ) -> WidgetSnapshot {
        let recent = points(history, hours: 2, now: now).suffix(maxPoints)
        return WidgetSnapshot(
            glucose: display.glucose, glucoseSourceName: provenance.isFailover ? sourceName : nil,
            insulinOnBoard: display.insulinOnBoard, reservoirUnits: display.reservoirUnits,
            battery: display.battery, basal: display.basalDeliveryState, controlIQ: display.controlIQ,
            lastBolus: display.lastBolus.map { $0.map { $0.deliveredUnits ?? $0.programmedUnits } },
            lastAutoCorrection: lastAutoCorrection,
            connected: display.link.isConnected, publishedAt: now, recent: Array(recent), freshness: freshness,
            unit: settings.glucoseUnit, showUnitLabel: settings.showGlucoseUnitLabels)
    }

    /// The readings of the last `hours`, oldest first.
    public static func points(_ history: [GlucoseReading], hours: Int, now: Date) -> [WidgetSnapshot.Point] {
        history.filter { $0.date <= now && $0.date >= now.addingTimeInterval(-Double(hours) * 3600) }
            .map { WidgetSnapshot.Point(t: $0.date, mgdl: $0.mgdl) }
    }

    /// The widgets re-read when what they show changed: a new glucose reading at once, another value at most
    /// once a minute, and otherwise every few minutes so the publish time stays recent. In between, each
    /// widget's timeline ages its values by itself. A re-read of an unchanged value (a new receive time) is
    /// not a change, so routine pump reads don't spend WidgetKit's reload budget.
    public static func needsReload(
        _ snapshot: WidgetSnapshot, last: (snapshot: WidgetSnapshot, at: Date)?, now: Date
    ) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last.at)
        if elapsed >= 5 * 60 { return true }
        if snapshot.glucose?.withoutReceiveTime != last.snapshot.glucose?.withoutReceiveTime { return true }
        return elapsed >= 60 && snapshot.drawn != last.snapshot.drawn
    }

    /// The Live Activity is updated on the same rule, and at once when its layout changes.
    public static func needsLiveActivityUpdate(
        _ content: LiveActivityContent, last: (content: LiveActivityContent, at: Date)?, now: Date
    ) -> Bool {
        guard let last, last.content.layout == content.layout else { return true }
        return needsReload(content.snapshot, last: (last.content.snapshot, last.at), now: now)
    }
}
