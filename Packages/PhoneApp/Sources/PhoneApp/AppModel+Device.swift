import Foundation
import GlucoseSources
import faBolusCore

// MARK: - Low Power Mode

extension AppModel {
    /// Low Power Mode may delay background pump and CGM updates: a notice while the pump is connected,
    /// until dismissed for this episode. Advisory only; it never changes what the app does.
    public var showsLowPowerAdvisory: Bool {
        LowPowerAdvisory.shouldWarn(
            lpmActive: lowPowerMode, sourceConnected: display.link.isConnected, dismissedEpisode: lowPowerDismissed)
    }

    public func dismissLowPowerAdvisory() { lowPowerDismissed = true }

    /// Follows the system's Low Power Mode; a new episode shows the notice again.
    func watchLowPowerMode() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        tasks.append(
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                    let on = ProcessInfo.processInfo.isLowPowerModeEnabled
                    await MainActor.run {
                        guard let self else { return }
                        if on && !self.lowPowerMode { self.lowPowerDismissed = false }
                        self.lowPowerMode = on
                    }
                }
            })
    }
}

// MARK: - Tabs

extension AppModel {
    /// The phone may bolus: not read-only, and a pump that takes a dose (or none paired yet, so the screen
    /// is there to learn). A screenless pump's own screens follow its capabilities the same way.
    public var showsBolusTab: Bool {
        !settings.phoneReadOnly && (pairing == nil || display.capabilities.canDeliverBolus)
    }
}

// MARK: - Erasing on-device data

extension AppModel {
    public enum EraseResult: Sendable, Equatable {
        case erased
        case refused(String)
    }

    static let eraseRefusal =
        "A bolus is in progress or its outcome is unknown. Resolve it (check the pump, then confirm in faBolus) before deleting data."

    /// While a bolus is in flight or unresolved, nothing is erased.
    private func eraseBlocked() async -> String? {
        if case .inProgress = display.bolusState?.value { return Self.eraseRefusal }
        switch await ledger.block {
        case .bolusInProgress, .unknownOutcome: return Self.eraseRefusal
        default: return nil
        }
    }

    /// Deletes the history on this phone: glucose, boluses, carbs and the logbook. The pump pairing and
    /// the CGM account are kept. The bolus ledger is never erased: it is what keeps an unknown outcome
    /// blocking (R2).
    public func eraseHistory() async -> EraseResult {
        if let refusal = await eraseBlocked() { return .refused(refusal) }
        // The session's logbook first, under its history lock, so a page being saved now can't bring it back.
        await session.clearLogbook()
        historyStore?.clear()
        logbook = []
        liveGlucose = []
        iobHistory = []
        reloadHistory()
        return .erased
    }

    /// Everything `eraseHistory` deletes, plus the pump's pairing and the Dexcom Share account.
    public func fullReset() async -> EraseResult {
        if let refusal = await eraseBlocked() { return .refused(refusal) }
        await selectBackupSource(nil)
        try? environment.glucoseSources.account.clear()
        await forgetPump()
        return await eraseHistory()
    }
}
