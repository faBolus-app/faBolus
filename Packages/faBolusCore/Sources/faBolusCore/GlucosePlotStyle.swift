import Foundation

/// How every glucose plot draws its readings: a dot each, or a line through them. One setting for the chart,
/// the widgets, the Live Activity and the watch. Either way a reading past the plot's edge is drawn at the
/// edge, marked as capped (`GlucosePlotScale.placement`): a hollow ring among dots, a dotted run in a line.
public enum GlucosePlotStyle: String, Codable, Sendable, CaseIterable {
    case dots, line

    public static let `default` = GlucosePlotStyle.dots

    public var title: String {
        switch self {
        case .dots: return "Dots"
        case .line: return "Line"
        }
    }
}
