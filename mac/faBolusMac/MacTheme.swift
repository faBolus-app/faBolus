import SwiftUI
import faBolusCore

/// Glucose banding → colors for the Mac views, matching the widgets (`WidgetUI.glucoseColor`) and
/// the phone HUD's low/in-range/high/urgent scheme.
enum MacTheme {
    static func glucoseColor(_ mgdl: Int?) -> Color {
        guard let g = mgdl else { return .gray }
        switch RemoteClientModel.band(g) {
        case 0: return .red        // low
        case 1: return .green      // in range
        case 2: return .yellow     // high
        default: return .orange    // urgent high
        }
    }
}
