import Testing
import faBolusCore
@testable import faBolusDesign

/// In-package sanity pin: `AppTheme.glucoseColor` routes each `GlucoseRange` case to the matching
/// §13-locked token. Not a contrast/byte-identity gate (that's `WCAGContrastTests` in faBolusCore and
/// `AppThemeContrastAuditTests` in the app target) — just proves the classify→color wiring is
/// correct.
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
}
