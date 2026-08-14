import SwiftUI
import faBolusCore

/// The redundant non-color band-encoding channel (WCAG 1.4.1 "use of color") — icon + word so a band
/// reads without relying on color. Promoted from `ios/faBolus/Views/StatusRingView.swift` (D-04);
/// the visual standard is the EXISTING ring encoding, not a new design.
public struct BandIndicator: View {
    public let band: GlucoseRange
    /// Compact surfaces (watch complications, small widgets) may hide the word and show only the
    /// icon — the icon must still render.
    public var showWord: Bool = true
    /// Whether this view speaks its own VoiceOver label. Callers that already compose a full
    /// sentence label (e.g. `StatusRingView.a11yLabel`) pass `false` and hide this from the
    /// accessibility tree so the band word isn't announced twice.
    public var announcesOwnLabel: Bool = true

    public init(band: GlucoseRange, showWord: Bool = true, announcesOwnLabel: Bool = true) {
        self.band = band
        self.showWord = showWord
        self.announcesOwnLabel = announcesOwnLabel
    }

    public var body: some View {
        Group {
            if showWord {
                Label(band.shortLabel, systemImage: band.symbolName)
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: band.symbolName)
            }
        }
        .accessibilityHidden(!announcesOwnLabel)
        .accessibilityLabel(announcesOwnLabel ? band.shortLabel : "")
    }
}
