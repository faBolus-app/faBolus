import Foundation
import HistoryStore

/// Thin faBolus adapter over the `StoredSite` CRUD (09.18a-01) for the SiteAtlas body-map UI.
///
/// Maps between the primitive `StoredSite` schema (`kind` "pump"|"sensor", `bodySide` "front"|"back",
/// normalized coords) and a display view model, and computes per-marker age state from the vendored
/// `SiteAtlas_Theme` helpers (`ageOpacity`/`safeReuseDays`/`shouldDisplayOnBodyMap`). Foundation +
/// HistoryStore only — deliberately NOT importing SwiftUI so it carries no `SiteAtlas_Theme` color
/// literal (§13/faBolusDesign color discipline lives in the views).
///
/// **DOSE-SAFE (T-09.18a-14):** advisory/display-only. Never originates, pre-fills, or gates a dose;
/// touches no `BolusMath`, `CarbStore`, or delivery seam. Input is validated at the trust boundary
/// (T-09.18a-12): normalized coords are clamped in-bounds and notes are length-bounded before persisting.
@Observable
@MainActor
final class SiteAtlasStore {
    /// Provenance tag written to every `StoredSite` row this adapter creates.
    static let sourceID = "app.siteAtlas"
    /// Max persisted note length (V5 input validation, T-09.18a-12).
    static let maxNoteLength = 500
    /// Normalized-coordinate proximity radius for the advisory reuse-window check.
    static let reuseProximityRadius = 0.08

    private let history: GlucoseHistoryStore?

    /// Display view model for one logged site, with derived age state.
    struct Site: Identifiable, Equatable {
        let id: String            // stable siteID
        let type: SiteAtlas_SiteType
        let bodySide: SiteAtlas_BodySide
        let normalizedX: Double
        let normalizedY: Double
        let note: String?
        let date: Date

        /// Days since placement (live).
        var daysSincePlaced: Int {
            Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        }
        /// Body-map marker opacity, faded by age over the type-specific safe-reuse window.
        var ageOpacity: Double {
            SiteAtlas_Theme.ageOpacity(daysSincePlaced: daysSincePlaced, type: type)
        }
        /// True once the site has aged past its type-specific safe-reuse window — the tissue is
        /// generally recovered (safe to reuse). The body-map pin is de-emphasized + warning-glyphed
        /// here rather than hidden, so the on-map history stays visible (UI-SPEC §2).
        var isPastReuseWindow: Bool {
            !SiteAtlas_Theme.shouldDisplayOnBodyMap(daysSincePlaced: daysSincePlaced, type: type)
        }
        /// Human-readable anatomical location, reusing the vendored zone resolver.
        var locationDescription: String {
            SiteAtlas_SiteEntry(type: type, date: date, bodySide: bodySide,
                                normalizedX: normalizedX, normalizedY: normalizedY,
                                notes: note).locationDescription
        }
    }

    /// Injected the app's SHARED `GlucoseHistoryStore` (WR-02) — this adapter must NOT open its own
    /// `ModelContainer`. A `nil` store means the on-disk store failed to open at app init; the UI reads
    /// `isAvailable` and surfaces that instead of silently dropping placements.
    init(history: GlucoseHistoryStore?) {
        self.history = history
    }

    /// False when the shared store failed to open — the UI disables logging + shows an error rather than
    /// no-op'ing an `add()` into the void (WR-02).
    var isAvailable: Bool { history != nil }

    /// All logged sites, most-recent placement first.
    func allSites() -> [Site] {
        (history?.allSites() ?? []).map(Self.viewModel(from:))
    }

    /// Sites on one body side, most-recent first.
    func sites(on side: SiteAtlas_BodySide) -> [Site] {
        allSites().filter { $0.bodySide == side }
    }

    /// Persist a new site placement. Clamps coords in-bounds and bounds the note (V5, T-09.18a-12).
    /// Returns the stable `siteID`.
    @discardableResult
    func add(type: SiteAtlas_SiteType, bodySide: SiteAtlas_BodySide,
             normalizedX: Double, normalizedY: Double, note: String? = nil, date: Date = Date()) -> String {
        let id = UUID().uuidString
        let x = min(max(normalizedX, 0), 1)
        let y = min(max(normalizedY, 0), 1)
        history?.ingestSite(siteID: id, kind: type.rawValue, bodySide: bodySide.rawValue,
                            normalizedX: x, normalizedY: y, note: Self.sanitizedNote(note),
                            date: date, sourceID: Self.sourceID)
        return id
    }

    /// Delete the site with the given stable `id`.
    func delete(id: String) {
        history?.deleteSite(id: id)
    }

    /// Advisory reuse-window proximity check (NON-BLOCKING — for display only, never gates logging).
    /// Returns the most-recent same-kind site still within its safe-reuse window whose marker sits
    /// within `reuseProximityRadius` of `(normalizedX, normalizedY)` on `bodySide`, or `nil`.
    func recentNearbySite(type: SiteAtlas_SiteType, bodySide: SiteAtlas_BodySide,
                          normalizedX: Double, normalizedY: Double) -> Site? {
        sites(on: bodySide).first { s in
            s.type == type
                && !s.isPastReuseWindow
                && (((s.normalizedX - normalizedX) * (s.normalizedX - normalizedX))
                    + ((s.normalizedY - normalizedY) * (s.normalizedY - normalizedY))).squareRoot()
                    <= Self.reuseProximityRadius
        }
    }

    // MARK: - Mapping

    private static func viewModel(from row: StoredSite) -> Site {
        Site(id: row.siteID,
             type: SiteAtlas_SiteType(rawValue: row.kind) ?? .pump,
             bodySide: SiteAtlas_BodySide(rawValue: row.bodySide) ?? .front,
             normalizedX: row.normalizedX, normalizedY: row.normalizedY,
             note: row.note, date: row.date)
    }

    /// Trim + bound a user-entered note; an empty/whitespace note collapses to `nil`.
    private static func sanitizedNote(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return String(trimmed.prefix(maxNoteLength))
    }
}
