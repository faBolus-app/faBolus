import Alerts
import DexcomG6
import Foundation
import GlucoseSources
import HistoryStore
import Observation
import PumpSession
import RemoteHost
import TandemBLE
import WatchLink
import WidgetContent
import faBolusCore

/// The app's state, which the views read. It holds no pump logic: the pump session, the ledger, the alert
/// pipeline, the backup CGM source and the watch host decide everything, and this mirrors what they report
/// and passes the user's actions on. It is built at launch, before any view, and runs the same whether or
/// not a view is on screen (a background relaunch has none).
@Observable @MainActor
public final class AppModel {
    /// The pump owns this restore identifier; any other central uses its own (one per central per process).
    public static let pumpRestoreIdentifier = "com.fabolus.app.pump"
    /// The app keeps a day of history, as before.
    public static let historyRetention: TimeInterval = 24 * 3600
    static let chartSpan: TimeInterval = 24 * 3600

    public let settings: AppSettings
    /// The first-launch wipe ran in this process.
    public let wipedOnLaunch: Bool
    public let isMock: Bool

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let session: PumpSession
    @ObservationIgnored let ledger: DurableBolusLedger
    @ObservationIgnored let alerts: AlertCoordinator
    @ObservationIgnored let historyStore: GlucoseHistoryStore?
    @ObservationIgnored let connection: PumpConnection
    @ObservationIgnored var backupSource: (any GlucoseSource)?
    @ObservationIgnored var backupTask: Task<Void, Never>?
    /// The backup-source switch under way, so switches run one at a time.
    @ObservationIgnored var backupSwitch: Task<Void, Never>?
    @ObservationIgnored var tasks: [Task<Void, Never>] = []
    @ObservationIgnored let watchTransport: (any WatchTransport)?
    @ObservationIgnored var watchLink: WatchLink?
    @ObservationIgnored var host: RemoteHost?
    @ObservationIgnored var lastAppliedFreshness: FreshnessThresholds?
    @ObservationIgnored var lastWidgetReload: (snapshot: WidgetSnapshot, at: Date)?
    @ObservationIgnored var lastLiveActivityUpdate: (content: LiveActivityContent, at: Date)?
    @ObservationIgnored var liveActivityFlowStorage: LiveActivityFlow?
    /// The freshness change being applied, so changes reach the session and the alerts in order.
    @ObservationIgnored var freshnessTask: Task<Void, Never>?
    @ObservationIgnored var liveGlucose: [GlucoseReading] = []
    /// Whether the app is in the foreground: launch's guess until the first scene change, which can arrive
    /// while launch is still running and wins over it.
    @ObservationIgnored var sceneActive: Bool?

    // MARK: What the views show

    /// The pump as the session reports it.
    public internal(set) var pump = PumpState()
    /// The pump with glucose from the backup source while the pump's own is stale or missing.
    public internal(set) var display = PumpState()
    public internal(set) var glucoseProvenance: GlucoseProvenance = .pump
    public internal(set) var backup: GlucoseSourceState?
    public internal(set) var backupSourceID: String?
    public internal(set) var pairing: StoredPairing?
    /// Why the link stopped trying by itself, until it connects again.
    public internal(set) var linkFailure: PumpLinkFailure?
    public internal(set) var lastDisconnect: PumpDisconnectReason?
    public internal(set) var connectionUnstable = false
    public internal(set) var alertSnapshot: AlertSnapshot?
    /// The logbook, newest first.
    public internal(set) var logbook: [HistoryEvent] = []
    public internal(set) var historySync: HistorySyncState = .idle(lastSynced: nil)
    /// The chart's glucose over the last day, oldest first: pump history, live readings and the backup's.
    public internal(set) var glucoseHistory: [GlucoseReading] = []
    public internal(set) var bolusMarkers: [BolusMarker] = []
    /// The pump's basal rate changes, suspends and resumes over the chart's day, for its basal line.
    public internal(set) var deliveryChanges: [DeliveryChange] = []
    public internal(set) var iobHistory: [IOBSample] = []
    public internal(set) var bolusBlock: BolusBlock?
    /// The newest bolus outcome this process saw, for the bolus banner.
    public internal(set) var latestOutcome: BolusStatus?
    public internal(set) var lastDismiss: (alert: PumpAlert, outcome: DismissOutcome)?
    /// The pumps a pairing scan found, strongest signal first (Mobi's order).
    public internal(set) var pumpsFound: [FoundPump] = []
    /// Each found pump's last reported signal, which orders `pumpsFound`.
    var pumpSignal: [UUID: Int] = [:]
    public internal(set) var watch: WatchLinkState?
    public internal(set) var freshness: FreshnessThresholds
    public internal(set) var started = false
    /// The launch has loaded what was saved (the pairing, the logbook): screens may judge from it.
    public internal(set) var launched = false
    public internal(set) var lowPowerMode = false
    public internal(set) var lowPowerDismissed = false
    /// Set by a widget or Live Activity link to the bolus screen; the tab view clears it.
    public var openBolusRequested = false

    public struct BolusStatus: Sendable, Equatable {
        public let key: RemoteBolusLedger.Key
        public let outcome: BolusOutcome
        public let requestedUnits: Double?
        public let at: Date
    }

    public struct FoundPump: Sendable, Hashable, Identifiable {
        public let peripheralID: UUID
        public let name: String?
        public let model: PumpModel
        public var id: UUID { peripheralID }
    }

    /// Builds everything in launch order, after the first-launch wipe. Nothing talks to the pump until
    /// `launch`.
    public init(environment: AppEnvironment) {
        self.environment = environment
        // Before anything reads a file or a setting, so nothing of the old app's is read.
        wipedOnLaunch = environment.wipe?.runIfNeeded() ?? false
        isMock = environment.isMock
        settings = AppSettings(defaults: environment.settingsDefaults)
        watchTransport = environment.makeWatchTransport()
        freshness = settings.freshness
        let clock = environment.clock
        let sessionClock = SessionClock(now: clock, uptime: environment.uptime)
        let directory = environment.dataDirectory
        ledger = Self.makeLedger(directory: directory, clock: sessionClock)
        do {
            historyStore =
                try environment.historyStoreURL.map { try GlucoseHistoryStore(url: $0) }
                ?? GlucoseHistoryStore(inMemory: environment.historyInMemory)
        } catch {
            appLog.error("history store unavailable: \(error)")
            historyStore = nil
        }
        connection = environment.makeConnection()
        let sessionStore: any PumpSessionPersisting =
            directory.map { FilePumpSessionStore(url: $0.appendingPathComponent("pump-session.json")) }
            ?? MemoryPumpSessionStore()
        session = PumpSession(
            connection: connection, ledger: ledger, store: sessionStore, secrets: environment.pairingSecrets,
            historySink: historyStore.map(HistoryStoreSink.init(store:)), freshness: settings.freshness,
            configuration: environment.sessionConfiguration, clock: sessionClock)
        let alertDirectory = directory ?? FileManager.default.temporaryDirectory
        alerts = AlertCoordinator(
            store: FileAlertStore(directory: alertDirectory), scheduler: environment.notifications, ledger: ledger,
            tickInterval: environment.runsTimers ? 30 : nil, clock: clock, uptime: environment.uptime)
    }

    /// No directory means no durable place to record a bolus, and the ledger blocks every one.
    private nonisolated static func makeLedger(directory: URL?, clock: SessionClock) -> DurableBolusLedger {
        guard let directory else { return DurableBolusLedger(store: nil, now: clock.now(), clock: clock) }
        return DurableBolusLedger(
            store: RemoteBolusLedgerStore(url: directory.appendingPathComponent("bolus-ledger.json")),
            now: clock.now(), clock: clock)
    }

    /// The launch sequence: the session, notifications, the backup source and the watch, before any view
    /// appears. Call once from the app delegate's launch, with whether the app is in the foreground.
    public func launch(appActive: Bool) async {
        guard !started else { return }
        started = true
        if sceneActive == nil { sceneActive = appActive }
        if wipedOnLaunch {
            historyStore?.clear()
            environment.glucoseSources.settings.removeAll()
            try? environment.glucoseSources.account.clear()
            await alerts.resetForFreshInstall()
        }
        historyStore?.deleteGlucose(olderThan: now.addingTimeInterval(-Self.historyRetention))
        // Every consumer subscribes before the session starts, so none misses an event.
        let alertEvents = await session.events()
        let appEvents = await session.events()
        let hostEvents = await session.events()
        await alerts.start(events: alertEvents, pumpPaired: await session.pairing != nil)
        await startBackupSource()
        if backupSource == nil { await alerts.backupGlucoseChanged(nil) }
        applyFreshness()
        await session.start(runTicker: environment.runsTimers)
        await session.setAppActive(sceneActive ?? appActive)
        pairing = await session.pairing
        // A pump paired already (by an earlier launch) means onboarding is behind the user.
        if pairing != nil { settings.hasCompletedOnboarding = true }
        pump = await session.state
        logbook = await session.historyEvents
        historySync = await session.historySync
        bolusBlock = await ledger.block
        reloadHistory()
        recompute()
        launched = true
        startWatch(appActive: sceneActive ?? appActive)
        let snapshots = await alerts.snapshots()
        tasks.append(Task { [weak self] in for await e in appEvents { await self?.handle(e) } })
        tasks.append(Task { [weak self] in for await s in snapshots { await self?.handle(s) } })
        tasks.append(Task { [weak self] in for await e in hostEvents { await self?.host?.pumpEvent(e) } })
        if environment.runsTimers {
            // Ages what the screens, widgets and Live Activity show even when nothing new arrives.
            tasks.append(
                Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        await self?.updatePrimaryHealth()
                        // The pump's reading may have aged past its window: the backup's takes over now.
                        self?.recompute()
                        self?.publishSurfaces()
                    }
                })
        }
        trackSettings()
        watchLowPowerMode()
        publishSurfaces(appActive: sceneActive ?? appActive)
    }

    /// Every scene change, including `true` at launch in the foreground.
    public func sceneChanged(active: Bool) async {
        sceneActive = active
        await session.setAppActive(active)
        watchLink?.submit(.appActive(active))
        if active {
            await alerts.tick()
            await updatePrimaryHealth()
            bolusBlock = await ledger.block
        }
        publishSurfaces(appActive: active)
    }

    /// An orderly stop (tests, and the debug mock's switch).
    public func shutdown() async {
        for t in tasks { t.cancel() }
        tasks = []
        backupTask?.cancel()
        if let backupSource {
            await backupSource.stop()
            environment.glucoseSources.markCleanShutdown()
        }
        await alerts.stop()
        await session.stop()
    }

    /// The app's clock: the wall clock, or the scripted pump's in the mock and tests. Views read time here.
    public var now: Date { environment.clock() }

    // MARK: Events

    func handle(_ event: PumpEvent) async {
        switch event {
        case .readingsChanged(let changed, let state):
            let previousIOB = pump.insulinOnBoard
            pump = state
            if changed.contains(.cgmHardwareInfo) { await applyTransmitterID() }
            if changed.contains(.insulinOnBoard), let iob = state.insulinOnBoard, iob != previousIOB {
                iobHistory.append(IOBSample(date: iob.measuredAt, iob: iob.value))
                iobHistory.removeAll { $0.date < now.addingTimeInterval(-Self.chartSpan) }
            }
            if changed.contains(.glucose), let g = state.glucose, g.source == .pump,
                liveGlucose.last.map({ $0.date < g.measuredAt }) ?? true
            {
                liveGlucose.append(GlucoseReading(date: g.measuredAt, mgdl: g.value.mgdl))
                liveGlucose.removeAll { $0.date < now.addingTimeInterval(-Self.chartSpan) }
                mergeChart()
            }
            if changed.contains(.lastBolus) { reloadHistory() }
        case .linkChanged(let link):
            pump.link = link
            if link == .connected {
                linkFailure = nil
                pairing = await session.pairing
            }
        case .disconnected(let reason):
            lastDisconnect = reason
        case .connectionUnstable:
            connectionUnstable = true
        case .connectionRestored:
            connectionUnstable = false
        case .identified:
            pairing = await session.pairing
            if pairing != nil { settings.hasCompletedOnboarding = true }
            // A new pairing starts with an empty logbook.
            logbook = await session.historyEvents
            // The pump's model decides what the watch may do: the session set it without a reading change.
            pump = await session.state
            recompute()
            await settingsChanged()
        case .alertsChanged:
            // Already in `state` from the `.readingsChanged` before it.
            break
        case .alertDismissed(let alert, let outcome):
            lastDismiss = (alert, outcome)
        case .bolusOutcome(let key, let outcome):
            let entry = await ledger.ledger.entry(key)
            latestOutcome = BolusStatus(key: key, outcome: outcome, requestedUnits: entry?.request.totalUnits, at: now)
            bolusBlock = await ledger.block
            liveActivityFlowStorage?.outcomeChanged(key, outcome)
        case .bolusOutcomesSaved:
            bolusBlock = await ledger.block
        case .pumpFound(let id, let name, let model, let rssi):
            // 127 is CoreBluetooth's "unknown": listed, after every pump with a reading.
            pumpSignal[id] = rssi == 127 ? Int.min : rssi
            if !pumpsFound.contains(where: { $0.peripheralID == id }) {
                pumpsFound.append(FoundPump(peripheralID: id, name: name, model: model))
            }
            // Equal signals keep the order they were found in.
            let signal = pumpSignal
            let ordered = pumpsFound.enumerated().sorted {
                let a = signal[$0.element.peripheralID, default: .min]
                let b = signal[$1.element.peripheralID, default: .min]
                return a != b ? a > b : $0.offset < $1.offset
            }.map(\.element)
            if ordered != pumpsFound { pumpsFound = ordered }
        case .linkFailed(let failure):
            linkFailure = failure
        case .historySync(let state):
            historySync = state
            // Pages saved before a sync ended in an error or a pause count too, not only a finished sync.
            if state != .syncing {
                logbook = await session.historyEvents
                reloadHistory()
            }
        }
        await updatePrimaryHealth()
        recompute()
        publishSurfaces()
    }

    /// Tells the backup source whether the pump's glucose is current, so a polling source speeds up as
    /// soon as it isn't. Checked on every pump event and every minute, because a reading goes stale with
    /// no event at all when the pump stops sending one.
    func updatePrimaryHealth() async {
        guard let backupSource else { return }
        await backupSource.setPrimaryHealthy(!pump.isGlucoseStale(thresholds: freshness, now: now))
    }

    func handle(_ snapshot: AlertSnapshot) async {
        alertSnapshot = snapshot
        await host?.alertsChanged(snapshot.active)
        publishSurfaces()
    }

    // MARK: Derived state

    /// The glucose the screens show, merged with the backup source, and everything that follows from it.
    func recompute() {
        let (merged, _, provenance) = GlucoseArbiter.merge(
            pumpState: pump, pumpHistory: [], source: backup, thresholds: freshness, now: now)
        display = merged
        glucoseProvenance = provenance
    }

    /// Glucose, boluses and basal changes from the history store for the chart's day, merged with what arrived live.
    func reloadHistory() {
        guard let historyStore else { return }
        let range =
            now.addingTimeInterval(-Self.chartSpan)...now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance)
        storedGlucose = historyStore.glucose(in: range)
        bolusMarkers = historyStore.boluses(in: range)
        deliveryChanges = historyStore.deliveryChanges(in: range)
        mergeChart()
    }

    @ObservationIgnored var storedGlucose: [GlucoseReading] = []

    func mergeChart() {
        let pumpSide = GlucoseArbiter.mergeHistory(pump: storedGlucose, source: liveGlucose)
        glucoseHistory = GlucoseArbiter.mergeHistory(pump: pumpSide, source: backup?.history ?? [])
    }

    /// The access the phone's own actions are judged by.
    public var access: AccessPolicy.AccessContext { settings.access(capabilities: display.capabilities) }

    /// Whether the phone's bolus button may be used now (the same checks the composer makes first).
    public var phoneBolusAvailability: DoseRefusal? {
        DoseComposer.availability(surface: .phoneUI, pump: display, access: access, bolusBlock: bolusBlock)
    }

    /// The last Control-IQ auto-correction the logbook knows of.
    public var lastAutoCorrection: Date? { logbook.first { $0.category == .autoCorrection }?.date }

    // MARK: Settings

    /// Applies every settings change to the parts that depend on it: the session's and the alerts'
    /// windows, the watch's config, the widgets and the Live Activity. Re-armed after each change.
    func trackSettings() {
        withObservationTracking {
            _ = settings.freshness
            _ = settings.watchPreferences
            _ = settings.access(capabilities: .unknown)
            _ = settings.remoteBolusLimitUnits
            _ = settings.liveActivityEnabled
            _ = settings.liveActivityBolusEnabled
            _ = settings.liveActivityLayout
            _ = settings.glucoseUnit
            _ = settings.showGlucoseUnitLabels
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Re-armed first, so a change made while this one is applied is seen too.
                self.trackSettings()
                self.applyFreshness()
                await self.settingsChanged()
            }
        }
    }

    func applyFreshness() {
        let next = settings.freshness
        guard next != lastAppliedFreshness else { return }
        lastAppliedFreshness = next
        freshness = next
        freshnessTask = Task { [previous = freshnessTask, session, alerts] in
            await previous?.value
            await session.setFreshness(next)
            await alerts.freshnessChanged(next)
        }
        recompute()
    }

    func settingsChanged() async {
        await host?.settingsChanged(settings.remoteSettings(capabilities: display.capabilities, freshness: freshness))
        publishSurfaces()
    }

    /// Settings the watch host reads, now.
    var remoteSettings: RemoteSettings {
        settings.remoteSettings(capabilities: display.capabilities, freshness: freshness)
    }
}
