import SwiftUI
import WidgetContent
import WidgetKit

@main
struct FaBolusWidgets: WidgetBundle {
    var body: some Widget {
        GlucoseWidget()
        StatusWidget()
        GlucoseLiveActivity()
    }
}

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// An entry now and one at each moment a value shown goes stale, so a widget greys on time though the app
/// can't wake it; a fallback reload a quarter hour on.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: Date(), snapshot: .placeholder()) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: WidgetStore().load() ?? .placeholder()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        guard let snapshot = WidgetStore().load() else {
            completion(
                Timeline(
                    entries: [SnapshotEntry(date: now, snapshot: WidgetSnapshot(publishedAt: .distantPast))],
                    policy: .after(now.addingTimeInterval(15 * 60))))
            return
        }
        let fallback = now.addingTimeInterval(15 * 60)
        let publisherStale = snapshot.publishedAt.addingTimeInterval(WidgetSnapshot.publisherStaleAfter)
        let dates = Set(
            [now, fallback] + snapshot.decayCrossings(asOf: now) + (publisherStale > now ? [publisherStale] : [])
        )
        .filter { $0 <= fallback }.sorted()
        completion(
            Timeline(entries: dates.map { SnapshotEntry(date: $0, snapshot: snapshot) }, policy: .after(fallback)))
    }
}
