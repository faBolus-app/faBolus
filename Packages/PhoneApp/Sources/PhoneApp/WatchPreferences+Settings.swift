import RemoteHost
import faBolusCore

extension AppSettings {
    /// The watch's preferences, built from the same stored settings the phone's own screens read: the
    /// glucose unit, the bolus and carb steps and the chart bounds are one setting each, on both.
    public var watchPreferences: WatchPreferences {
        var p = WatchPreferences()
        p.bolusMode = watchDefaultBolusMode.rawValue
        p.bolusIncrementUnits = bolusIncrement
        p.carbIncrementGrams = carbIncrement
        p.screenOrder = watchScreenOrder
        p.defaultScreen = watchDefaultScreen
        p.detailsOrder = watchDetailsOrder
        p.watchChartRanges = watchChartRanges
        p.complicationSlots = complicationSlots
        p.complicationLabels = complicationNames
        p.glucoseDisplayUnit = glucoseUnit.wireToken
        p.glucosePlotFloor = glucosePlotFloor
        p.glucosePlotCeiling = glucosePlotCeiling
        p.glucosePlotFloorSmall = watchPlotFloor
        p.glucosePlotCeilingSmall = watchPlotCeiling
        return p
    }

    /// The access context every dose and the watch's config are judged by, for a pump with `capabilities`.
    public func access(capabilities: PumpCapabilities) -> AccessPolicy.AccessContext {
        AccessPolicy.AccessContext(
            phoneReadOnly: phoneReadOnly, remotesReadOnly: remotesReadOnly, capabilities: capabilities,
            garminBolusEnabled: garminBolusEnabled)
    }

    /// What the watch host needs from the settings.
    public func remoteSettings(capabilities: PumpCapabilities, freshness: FreshnessThresholds) -> RemoteSettings {
        RemoteSettings(
            access: access(capabilities: capabilities), remoteSizeLimitUnits: remoteBolusLimitUnits,
            preferences: watchPreferences, freshness: freshness)
    }
}
