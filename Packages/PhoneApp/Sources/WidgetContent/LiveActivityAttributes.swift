#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// The glucose Live Activity, shared by the app (which starts and updates it) and the widget extension
/// (which draws it). Each update's content is a `LiveActivityContent`.
public struct GlucoseActivityAttributes: ActivityAttributes {
    public typealias ContentState = LiveActivityContent
    public init() {}
}
#endif
