import Alerts
import DexcomG6
import Foundation
import GlucoseSources
import PumpSession
import RemoteHost
import WatchLink
import WidgetContent
import faBolusCore

// MARK: - Bolus

extension AppModel {
    /// The calculator's suggestion for the bolus screen, from what's shown now. A dose is composed again
    /// from fresh pump reads on confirm (`composePhoneDose`), and the composer asks if that moved it.
    public func recommendation(carbsGrams: Double, glucoseMgdl: Int?) -> DoseRecommendation {
        recommendation(.carbs(grams: carbsGrams), glucoseMgdl: glucoseMgdl)
    }

    public func recommendation(_ food: CalculatorFood, glucoseMgdl: Int?) -> DoseRecommendation {
        DoseComposer.recommend(food, glucoseMgdl: glucoseMgdl, context: screenContext)
    }

    /// Carbs are off on the pump, as last read: the bolus screen's food entry is insulin units.
    public var screenCarbsOff: Bool { display.bolusCalculator?.value.carbsOff == true }

    /// The bolus screen's stale reading may still be included: Confirm asks about it. Otherwise a carb dose
    /// without a current reading is carbs only, with nothing to ask.
    public var staleReadingIncludable: Bool { DoseComposer.mayIncludeStaleReading(screenContext) }

    /// Why the pump says its CGM reading shouldn't correct a dose, for the bolus screen: the dose is then
    /// carbs only, with nothing asked at Confirm (`.cgmStateNotRead` only until the state arrives).
    public var screenGlucoseCaution: PumpGlucoseCaution? { display.glucoseCaution() }

    private var screenContext: DoseContext {
        DoseContext(
            pump: display, access: access, bolusBlock: bolusBlock, inputsRequestedAt: .distantPast,
            lastDeliveryAt: nil, remoteSizeLimitUnits: nil, freshness: freshness, now: now)
    }

    /// Reads the dose inputs fresh from the pump and composes the phone's dose. The screen shows any prompt
    /// and composes again with the answer; `deliver` sends a `.deliver` dose.
    public func composePhoneDose(_ entry: PhoneDoseEntry) async -> PhoneDoseDecision {
        let preparation = await session.prepareDose()
        let (merged, _, _) = GlucoseArbiter.merge(
            pumpState: preparation.pump, pumpHistory: [], source: backup, thresholds: preparation.freshness,
            now: preparation.now)
        return DoseComposer.composePhone(
            entry,
            context: preparation.context(
                pump: merged, access: settings.access(capabilities: preparation.pump.capabilities),
                remoteSizeLimitUnits: nil))
    }

    public func deliver(_ dose: ComposedDose) async -> DeliveryResult {
        let result = await session.deliver(dose)
        bolusBlock = await ledger.block
        if case .started(let key, let outcome) = result {
            latestOutcome = BolusStatus(key: key, outcome: outcome, requestedUnits: dose.units, at: now)
        }
        return result
    }

    /// Never gated (R10).
    public func cancelBolus() async -> CancelResult { await session.cancelBolus() }

    /// The user checked the pump: every unknown outcome stops blocking. They stay unknown, and history can
    /// still settle them (R11).
    public func confirmUnknownOutcomesOnPump() async {
        do { try await ledger.confirmAllOnPump(now: now) } catch {
            appLog.error("confirm on pump not saved: \(error)")
        }
        bolusBlock = await ledger.block
        await alerts.ledgerChanged()
    }

    /// The ledger's unknown outcomes still blocking, for the banner that offers to confirm them.
    public func unresolvedOutcomes() async -> [RemoteBolusLedger.Entry] { await ledger.ledger.unresolved }
}

// MARK: - Alerts

extension AppModel {
    /// Clear a pump alert from the phone (or the "Try clearing from phone" trial).
    public func dismiss(_ alert: PumpAlert) async -> DismissOutcome { await session.dismiss(alert) }

    /// How long a notification's Clear waits for the pump: a background launch has about 30 s.
    static let notificationClearWait: TimeInterval = 20

    /// "Clear" on a pump alert's notification. The app may have just been launched for it, with no link
    /// yet, so the clear waits (bounded) for the pump, then goes the same way as the app's button. When it
    /// doesn't clear the alert, the user is told to clear it on the pump: the notification they acted on
    /// is gone.
    public func clearFromNotification(_ alert: PumpAlert) async -> DismissOutcome {
        let outcome = await session.dismiss(alert, waitingForLinkUpTo: Self.notificationClearWait)
        if outcome != .cleared { await alerts.pumpClearFailed(alert) }
        return outcome
    }

    public func alertPolicy() async -> AlertPolicy { await alerts.policy }

    /// The developer retest setting: the commands this pump is recorded not to answer or that are sitting
    /// out, and forgetting that so a command is tried again.
    public func retestableCommands() async -> [PumpSession.RetestableCommand] { await session.retestableCommands() }

    public func retest(_ command: PumpSession.RetestableCommand) async { await session.retest(command.key) }

    public func setAlertPolicy(_ policy: AlertPolicy) async { await alerts.setPolicy(policy) }
}

// MARK: - Pairing

extension AppModel {
    public func scanForPumps() async {
        pumpsFound = []
        linkFailure = nil
        await session.scanForPairing()
    }

    /// Pairing left without pairing (a pairing under way is abandoned): the paired pump reconnects.
    public func endPairingScan() async { await session.endPairingScan() }

    public func pair(_ pump: FoundPump, code: String) async throws(PumpSession.PairingRefusal) {
        linkFailure = nil
        try await session.pair(peripheralID: pump.peripheralID, advertisedName: pump.name, code: code)
        pairing = await session.pairing
    }

    /// Forgets the pump. The ledger is kept: an unknown outcome stays blocking until confirmed on the pump.
    public func forgetPump() async {
        await session.forgetPairing()
        await alerts.pairingForgotten()
        if let host { await host.forgetDismissResults() } else { try? dismissResultStore?.save([]) }
        pairing = nil
        logbook = []
        pumpsFound = []
        linkFailure = nil
        lastDisconnect = nil
        connectionUnstable = false
        pump = await session.state
        recompute()
        await settingsChanged()
    }

    public func syncHistory() async { await session.syncHistory() }
}

// MARK: - Backup CGM

extension AppModel {
    public var glucoseSources: GlucoseSourceRegistry { environment.glucoseSources }

    /// Starts the selected backup source, once per process. Built in launch so CoreBluetooth can hand back
    /// a Bluetooth source's central on a background relaunch.
    func startBackupSource() async {
        let registry = environment.glucoseSources
        guard registry.shouldStartSelected(now: now), let source = registry.makeSelected() else { return }
        await run(source)
    }

    private func run(_ source: any GlucoseSource) async {
        backupSource = source
        backupSourceID = source.id
        let updates = await source.updates()
        await source.start()
        await updatePrimaryHealth()
        await apply(await source.state)
        await applyTransmitterID()
        backupTask = Task { [weak self] in
            for await state in updates { await self?.apply(state) }
        }
    }

    func apply(_ state: GlucoseSourceState) async {
        let previous = backup?.latest
        backup = state
        if let latest = state.latest, latest != previous, let historyStore {
            historyStore.ingest([latest], priority: backupSource?.priority ?? DexcomShareSource.priority)
        }
        await alerts.backupGlucoseChanged(state)
        await host?.glucoseChanged()
        mergeChart()
        recompute()
        publishSurfaces()
    }

    /// Switches the backup source (`nil` for none). One runs at a time.
    public func selectBackupSource(_ id: String?) async {
        let previous = backupSwitch
        let change = Task { [weak self] in
            await previous?.value
            await self?.switchBackupSource(to: id)
        }
        backupSwitch = change
        await change.value
    }

    /// The process is ending in order: the backup source's recovery policy counts this launch as clean.
    public func willTerminate() {
        if backupSource != nil { environment.glucoseSources.markCleanShutdown() }
    }

    private func switchBackupSource(to id: String?) async {
        backupTask?.cancel()
        backupTask = nil
        if let old = backupSource {
            await old.stop()
            environment.glucoseSources.markCleanShutdown()
        }
        backupSource = nil
        backupSourceID = nil
        backup = nil
        environment.glucoseSources.select(id)
        if let id, let source = environment.glucoseSources.make(id: id) {
            await run(source)
        } else {
            await alerts.backupGlucoseChanged(nil)
            await host?.glucoseChanged()
        }
        mergeChart()
        recompute()
        publishSurfaces()
    }

    /// Saves the Dexcom Share account (a `nil` password keeps the saved one) and polls at once, so a
    /// mistake shows straight away.
    public func saveShareAccount(username: String, password: String?, region: ShareRegion) async throws {
        _ = try environment.glucoseSources.account.save(username: username, password: password, region: region)
        if let share = backupSource as? PollingGlucoseSource { await share.pollNow() }
    }

    /// The G6 transmitter ID typed in settings; an empty one falls back to the pump's.
    public func setG6TransmitterID(_ text: String?) async throws {
        _ = try environment.glucoseSources.setG6TransmitterID(text)
        await applyTransmitterID()
    }

    /// The G6 source follows the ID typed in settings, else the one the pump reports (its CGM hardware read).
    func applyTransmitterID() async {
        guard let g6 = backupSource as? DexcomBLESource<G6Observer> else { return }
        await g6.setTransmitterID(
            entered: environment.glucoseSources.settings.g6TransmitterID, fromPump: pump.cgmHardwareInfo?.value)
    }

    /// The running Bluetooth CGM's session recording, for the owner's checks; `nil` for any other source.
    public func bluetoothCGMRecording() async -> String? {
        guard let recorder = backupSource as? any RecordsBluetoothSession else { return nil }
        return await recorder.sessionRecording()
    }

    /// For the CGM test in settings.
    public func probeBackupSource() async -> CgmTestCoordinator.Probe? {
        guard let backupSource else { return nil }
        return await .of(backupSource)
    }
}

// MARK: - Watch

extension AppModel {
    /// The watch's dismiss results, kept beside the ledger; none without a data directory.
    var dismissResultStore: FileDismissResultStore? {
        environment.dataDirectory.map { FileDismissResultStore(url: FileDismissResultStore.url(in: $0)) }
    }

    func startWatch(appActive: Bool) {
        guard let transport = watchTransport else { return }
        let link = WatchLink(transport: transport, clock: environment.watchClock ?? SystemWatchLinkClock())
        link.onChange = { [weak self] state in self?.watch = state }
        let services = SessionRemoteServices(
            session: session, ledger: ledger, alerts: alerts,
            backupGlucose: { [weak self] in await MainActor.run { self?.backup } },
            history: { [weak self] since in
                await MainActor.run { self?.glucoseHistory.filter { $0.date >= since } ?? [] }
            },
            clock: environment.clock)
        let host = RemoteHost(
            link: link, services: services, settings: remoteSettings, dismissResults: dismissResultStore,
            clock: environment.clock)
        watchLink = link
        self.host = host
        link.start()
        link.submit(.appActive(appActive))
        watch = link.state
        Task { await host.start() }
    }
}

// MARK: - Display

extension AppModel {
    /// What the screens show for each pump value at `now`.
    public func pumpDisplay(now: Date) -> PumpDisplay {
        PumpDisplay(
            pump: display, freshness: freshness, unit: settings.glucoseUnit,
            showUnitLabels: settings.showGlucoseUnitLabels,
            lastAutoCorrection: lastAutoCorrection, now: now)
    }

    /// The name of the backup source supplying the glucose shown, while it does.
    public var failoverSourceName: String? {
        guard case .failover(let id, _) = glucoseProvenance else { return nil }
        return glucoseSources.descriptor(id: id)?.name
    }
}

// MARK: - Widgets and the Live Activity

extension AppModel {
    /// The snapshot the widgets and the Live Activity show, from what the app shows now.
    public var widgetSnapshot: WidgetSnapshot {
        WidgetPublisher.snapshot(
            display: display, provenance: glucoseProvenance,
            sourceName: backupSourceID.flatMap { glucoseSources.descriptor(id: $0)?.name },
            history: glucoseHistory, lastAutoCorrection: lastAutoCorrection, settings: settings,
            freshness: freshness, now: now)
    }

    /// Saves the snapshot for the widgets, reloading them when what they show changed, and updates the
    /// Live Activity.
    func publishSurfaces(appActive: Bool? = nil) {
        guard started else { return }
        let snapshot = widgetSnapshot
        environment.widgetStore.save(snapshot)
        if WidgetPublisher.needsReload(snapshot, last: lastWidgetReload, now: now) {
            lastWidgetReload = (snapshot, now)
            environment.reloadWidgets()
        }
        guard let liveActivity = environment.liveActivity else { return }
        if settings.liveActivityEnabled {
            let layout = settings.liveActivityLayout
            var plotted = snapshot
            plotted.recent = WidgetPublisher.points(glucoseHistory, hours: layout.plotRangeHours, now: now)
            let content = LiveActivityContent.make(from: plotted, layout: layout, now: now)
            // Started whenever none is showing (iOS allows it only in the foreground); otherwise updated
            // on the widgets' rule, so routine pump reads don't flood ActivityKit with identical updates.
            guard
                !liveActivity.isRunning
                    || WidgetPublisher.needsLiveActivityUpdate(content, last: lastLiveActivityUpdate, now: now)
            else { return }
            liveActivity.show(
                content, staleDate: content.staleDate(now: now), appActive: appActive ?? sceneActive ?? false)
            if liveActivity.isRunning { lastLiveActivityUpdate = (content, now) }
        } else if liveActivity.isRunning {
            liveActivity.end()
            lastLiveActivityUpdate = nil
        }
    }
}

// MARK: - Diagnostics

extension AppModel {
    /// A text export for debugging on-device problems: both links' telemetry and transition logs, the
    /// pump's identity, the alerts and the ledger. No pairing code, password or glucose history.
    public func diagnostics() async -> String {
        let link = await session.linkState()
        return await DiagnosticsBundle(
            generatedAt: now, appVersion: Self.appVersion, pairing: pairing, pump: pump, link: link,
            linkNow: connection.now, watch: watch, alerts: alertSnapshot, ledger: ledger.ledger,
            glucoseProvenance: glucoseProvenance, backupSourceID: backupSourceID, backup: backup,
            historySync: historySync, logbookCount: logbook.count
        ).text
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
