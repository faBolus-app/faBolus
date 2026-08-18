// Ported from LoopPowerPack/Loop @ ad4c4d4 (MIT)
//
// SiteAtlasBodyMapView — re-skinned body-map surface for the SiteAtlas tracker.
//
// LICENSE NOTE: this uses the VECTOR / SF-Symbol body-outline FALLBACK, NOT the mirror's
// `BodyMapFront.png`/`BodyMapBack.png` graphics. Those PNGs are graphics under the LoopPowerPack
// LICENSE's noted exceptions and were NOT bundled pending an owner license-verify of the graphics
// exception (blocking checkpoint resolved to the reversible fallback; see 09.18a-04-SUMMARY). The
// SF-Symbol outline adapts to Dynamic Type / dark mode and ships unconditionally.

import SwiftUI
import faBolusDesign

/// The front/back body outline with tappable, age-faded site markers. Tapping an empty spot reports a
/// normalized coordinate so the caller can open the log-entry sheet pre-located there.
struct SiteAtlasBodyMapView: View {
    let side: SiteAtlas_BodySide
    let sites: [SiteAtlasStore.Site]
    /// Called with a normalized (0–1) coordinate when the user taps the map to log a new site.
    var onTapLocation: (Double, Double) -> Void

    /// Fixed map height; the width is capped upstream at `iPadReadableContentMaxWidth`.
    private let mapHeight: CGFloat = 360

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Vector body outline (SF Symbol) — the license-safe fallback. Horizontally flipped on
                // the back side as a subtle orientation cue.
                Image(systemName: "figure.stand")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tertiary)
                    .scaleEffect(x: side == .back ? -1 : 1, y: 1)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .accessibilityHidden(true)

                ForEach(placedMarkers(in: geo.size)) { placed in
                    SiteMarker(site: placed.site)
                        .position(placed.point)
                        .accessibilityLabel(Self.accessibilityLabel(for: placed.site))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let x = min(max(Double(location.x / max(geo.size.width, 1)), 0), 1)
                let y = min(max(Double(location.y / max(geo.size.height, 1)), 0), 1)
                onTapLocation(x, y)
            }
        }
        .frame(height: mapHeight)
        .accessibilityElement(children: .contain)
        .accessibilityHint("Double-tap to log a site at the center; logged sites are listed below.")
    }

    // MARK: - Marker layout (overflow backstop)

    private struct PlacedMarker: Identifiable {
        let id: String
        let site: SiteAtlasStore.Site
        let point: CGPoint
    }

    /// Resolve each site's normalized coord to a point, then radially nudge any marker that would land
    /// on top of an already-placed one so dense clusters stay individually tappable (UI-SPEC overflow
    /// backstop). Deterministic: markers are laid out most-recent-first and pushed outward in a fixed
    /// spiral, so the same data always renders the same layout.
    private func placedMarkers(in size: CGSize) -> [PlacedMarker] {
        let minSeparation: CGFloat = 40   // ≥ the 44pt hit target's core, keeps taps disambiguated
        var placed: [PlacedMarker] = []
        for site in sites {
            let base = CGPoint(x: CGFloat(site.normalizedX) * size.width,
                               y: CGFloat(site.normalizedY) * size.height)
            var point = base
            var attempt = 0
            while placed.contains(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < minSeparation }),
                  attempt < 12 {
                attempt += 1
                let angle = CGFloat(attempt) * (.pi * 2 / 6)
                let radius = minSeparation * (1 + CGFloat(attempt) / 6)
                point = CGPoint(x: min(max(base.x + cos(angle) * radius, 0), size.width),
                                y: min(max(base.y + sin(angle) * radius, 0), size.height))
            }
            placed.append(PlacedMarker(id: site.id, site: site, point: point))
        }
        return placed
    }

    private static func accessibilityLabel(for site: SiteAtlasStore.Site) -> String {
        let age = site.daysSincePlaced
        let ageText = age == 0 ? "today" : "\(age) day\(age == 1 ? "" : "s") ago"
        let reuse = site.isPastReuseWindow ? ", past reuse window" : ""
        return "\(site.type.displayName), \(site.locationDescription), \(ageText)\(reuse)"
    }
}

/// A single body-map marker: distinct SF Symbol per kind, opacity faded by age, `AppTheme.stale` gray
/// with a warning glyph once past the safe-reuse window (advisory only).
struct SiteMarker: View {
    let site: SiteAtlasStore.Site

    private var symbol: String {
        site.type == .pump ? "bandage.fill" : "sensor.tag.radiowaves.forward.fill"
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(site.isPastReuseWindow ? AppTheme.stale : AppTheme.insulin)
                .opacity(site.isPastReuseWindow ? 0.45 : max(0.4, site.ageOpacity))
                .frame(width: 30, height: 30)
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.white)
            if site.isPastReuseWindow {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.high)
                    .offset(x: 13, y: -13)
            }
        }
        .frame(width: 44, height: 44)   // Apple HIG minimum tap target
        .contentShape(Circle())
    }
}
