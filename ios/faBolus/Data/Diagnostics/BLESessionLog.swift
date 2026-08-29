import Foundation
import faBolusCore

/// The "verbose BLE session logging" half of the in-app debug console: a lightweight,
/// bounded, **in-memory** ring buffer of connection-layer events (connect / disconnect + reason /
/// reconnect). Local-only, opt-in, read-only diagnostics.
///
/// It records **nothing** unless the shared "share local diagnostics" opt-in is on (the SAME flag the
/// notification telemetry and `ConnectionTelemetryStore` gate on), keeps only the last
/// `capacity` entries (oldest dropped first), and is **forgotten on restart** — never persisted, never
/// uploaded. It is populated from the connection-state-transition edges `AppModel` already observes
/// (`SafetyEdge.connection` in `refresh()`), so there is **no new BLE poll / scan / timer and no cadence
/// change**. Like the sibling telemetry, it never touches any decision path.
@MainActor
final class BLESessionLog {
    struct Entry: Identifiable, Equatable, Sendable {
        let id = UUID()
        let at: Date
        let kind: Kind
        /// Free-text detail, e.g. the disconnect reason token (`ConnectionTelemetryStore.reasonToken`);
        /// empty for a plain (re)connect.
        let detail: String

        enum Kind: String, Sendable { case connect, disconnect, reconnect, restore }
    }

    private let store: UserDefaults
    /// Ring-buffer cap (~100 by default). Oldest entries are dropped first.
    let capacity: Int
    /// The last `capacity` events, oldest first. In-memory only — a process restart forgets them.
    private(set) var entries: [Entry] = []

    init(capacity: Int = 100, store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup)) {
        self.capacity = max(1, capacity)
        self.store = store ?? .standard
    }

    /// The shared opt-in — the same flag sibling telemetry uses (one diagnostics switch); default OFF.
    var enabled: Bool { store.bool(forKey: NotificationRuntime.telemetryEnabledKey) }

    /// Record a connection-layer event. A **no-op unless opted in**. Appends and trims to `capacity`.
    func record(_ kind: Entry.Kind, detail: String = "", at now: Date = Date()) {
        guard enabled else { return }
        entries.append(Entry(at: now, kind: kind, detail: detail))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Discard the in-memory log (offered in the console; also called by "Delete all on-device data").
    func clear() { entries.removeAll() }

    /// Pairs each `.connect`/`.reconnect`/`.restore` edge with the NEXT `.disconnect` edge, using
    /// only the existing `Entry.at` timestamps already recorded. A pure function of the input array: no
    /// new `Kind` case, no new stored field, no dependence on `enabled`/UserDefaults. A trailing open span
    /// (a connect/reconnect/restore with no following disconnect yet) is dropped — it's still connected,
    /// just not yet a closed span. A disconnect with no preceding open span is ignored.
    nonisolated static func connectDurations(from entries: [Entry]) -> [(start: Date, end: Date)] {
        var spans: [(start: Date, end: Date)] = []
        var openAt: Date?
        for e in entries {
            switch e.kind {
            case .connect, .reconnect, .restore:
                openAt = e.at
            case .disconnect:
                if let start = openAt {
                    spans.append((start: start, end: e.at))
                    openAt = nil
                }
            }
        }
        return spans
    }
}
