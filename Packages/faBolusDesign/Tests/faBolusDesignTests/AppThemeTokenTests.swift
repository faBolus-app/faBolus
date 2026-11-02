import Testing
import faBolusCore
@testable import faBolusDesign

/// In-package sanity pin: `AppTheme.glucoseColor` routes each `GlucoseRange` case to the matching
/// §13-locked token. Not a contrast gate (that's `WCAGContrastTests` in faBolusCore) — just proves the
/// classify→color wiring is correct.
struct AppThemeTokenTests {
    @Test func glucoseColorRoutesEachBandToItsToken() {
        // Values chosen well inside each band per GlucoseThresholds (70/180/250).
        #expect(AppTheme.glucoseColor(50) == AppTheme.low)
        #expect(AppTheme.glucoseColor(120) == AppTheme.inRange)
        #expect(AppTheme.glucoseColor(200) == AppTheme.high)
        #expect(AppTheme.glucoseColor(300) == AppTheme.urgentHigh)
    }

    @Test func staleReadingAlwaysGreysOutRegardlessOfBand() {
        for mgdl in [50, 120, 200, 300] {
            #expect(AppTheme.glucoseColor(mgdl, stale: true) == AppTheme.stale)
        }
    }

    /// A bolus colors the ring only on a connected link; it never stands in for a link state.
    @Test func ringColorKeepsTheLinkAndTheBolusApart() {
        #expect(AppTheme.ringColor(link: .connected, bolusInProgress: false) == AppTheme.inRange)
        #expect(AppTheme.ringColor(link: .connected, bolusInProgress: true) == AppTheme.insulin)
        for link in [PumpLinkState.scanning, .connecting, .authenticating] {
            #expect(AppTheme.ringColor(link: link, bolusInProgress: true) == AppTheme.high)
        }
        #expect(AppTheme.ringColor(link: .disconnected, bolusInProgress: true) == AppTheme.disconnected)
    }
}
