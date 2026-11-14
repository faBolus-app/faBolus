import WatchLink

extension WatchLinkState {
    /// The link's state in the words Settings shows.
    public var settingsText: String {
        switch phase {
        case .notPaired: return "No watch chosen"
        case .appNotInstalled: return "faBolus not installed on the watch"
        // iOS doesn't know the watch saved here: it was paired again, Garmin Connect was reinstalled, or the
        // phone was restored. Nothing reaches it until it's chosen again, so Settings says so rather than
        // "Not connected", which waiting would fix.
        case .unreachable where device == .notFound: return "Watch not found. Choose it again in Garmin Connect."
        case .unreachable: return "Not connected"
        case .reachable: return "Connected"
        case .awaitingReply: return "Sending"
        case .backingOff: return "Retrying"
        }
    }
}
