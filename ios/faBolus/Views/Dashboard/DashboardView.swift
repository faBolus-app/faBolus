import Alerts
import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// The dashboard: the glucose ring, the status pills, the chart and the details, with the banners that need
/// the user above them.
struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var windowHours = 3
    private let windows = [3, 6, 12, 24]
    /// What the cancel line says at first (the snapshot of a cancel waiting).
    private let initialCancelMessage: String?

    init(model: AppModel, cancelMessage: String? = nil) {
        _model = Bindable(wrappedValue: model)
        initialCancelMessage = cancelMessage
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 20)) { _ in
                let now = model.now
                let display = model.pumpDisplay(now: now)
                ScrollView {
                    VStack(spacing: 14) {
                        StatusRingView(
                            display: display, failoverSource: model.failoverSourceName,
                            bolusInProgress: bolusInProgress)
                        DashboardBanners(model: model, cancelMessage: initialCancelMessage)
                        StatusPillsView(display: display, order: model.settings.pillsOrder).padding(.horizontal)
                        chart(now: now).padding(.horizontal)
                        if model.settings.showStats {
                            StatsCardView(
                                history: model.glucoseHistory, unit: model.settings.glucoseUnit,
                                showUnitLabels: model.settings.showGlucoseUnitLabels
                            )
                            .padding(.horizontal)
                        }
                        PumpDetailsCard(display: display, order: model.settings.detailsOrder).padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("faBolus")
            .navigationBarTitleDisplayMode(.inline)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility5)
    }

    private var bolusInProgress: Bool {
        if case .inProgress = model.display.bolusState?.value { return true }
        return false
    }

    @ViewBuilder private func chart(now: Date) -> some View {
        @Bindable var settings = model.settings
        VStack(spacing: 6) {
            GlucoseChartView(
                readings: model.glucoseHistory, iob: model.iobHistory, boluses: model.bolusMarkers,
                deliveryChanges: model.deliveryChanges, windowHours: windowHours,
                showGlucose: settings.showGlucoseAxis, showIOB: settings.showIOBAxis,
                showBolusBars: settings.showBolusBars, showBasal: settings.showBasal,
                floor: settings.glucosePlotFloor, ceiling: settings.glucosePlotCeiling, unit: settings.glucoseUnit,
                showUnitLabel: settings.showGlucoseUnitLabels, now: now)
            Picker("Window", selection: $windowHours) {
                ForEach(windows, id: \.self) { Text("\($0)h").tag($0) }
            }
            .pickerStyle(.segmented)
            // One row when the four fit, two at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Toggle("Glucose", isOn: $settings.showGlucoseAxis)
                    Toggle("IOB", isOn: $settings.showIOBAxis)
                    Toggle("Bolus", isOn: $settings.showBolusBars)
                    Toggle("Basal", isOn: $settings.showBasal)
                }
                VStack(spacing: 8) {
                    HStack(spacing: 16) {
                        Toggle("Glucose", isOn: $settings.showGlucoseAxis)
                        Toggle("IOB", isOn: $settings.showIOBAxis)
                    }
                    HStack(spacing: 16) {
                        Toggle("Bolus", isOn: $settings.showBolusBars)
                        Toggle("Basal", isOn: $settings.showBasal)
                    }
                }
            }
            .font(.caption).toggleStyle(.button).controlSize(.small)
        }
    }
}

/// The banners above the dashboard's pills, most important first: no pump, why the link stopped, an
/// unknown bolus outcome to confirm on the pump, notifications off, a bolus in progress or just finished,
/// and the pump's own alerts.
struct DashboardBanners: View {
    @Bindable var model: AppModel
    @State private var showPairing = false
    @State private var cancelMessage: String?
    /// Counts cancel taps, so only the latest tap's answer and timer change the message.
    @State private var cancelTaps = 0
    @State private var confirmingOnPump = false

    /// - Parameter cancelMessage: what the cancel line says at first (the snapshot of a cancel waiting).
    init(model: AppModel, cancelMessage: String? = nil) {
        _model = Bindable(wrappedValue: model)
        _cancelMessage = State(initialValue: cancelMessage)
    }

    var body: some View {
        VStack(spacing: 10) {
            if model.pairing == nil {
                Card(icon: "antenna.radiowaves.left.and.right", tint: .secondary, title: "No pump connected") {
                    Text("Connect your pump to see glucose and give a bolus.").font(.subheadline).foregroundStyle(
                        .secondary)
                    Button("Connect a pump") { showPairing = true }.buttonStyle(.borderedProminent)
                }
            } else if let failure = model.linkFailure {
                Card(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Pump not connected") {
                    Text(PumpMessages.text(failure)).font(.subheadline)
                }
            } else if model.connectionUnstable {
                Card(icon: "antenna.radiowaves.left.and.right.slash", tint: .orange, title: "Connection unstable") {
                    Text("The pump keeps dropping the link. Keep the phone close to the pump.").font(.subheadline)
                }
            }
            if model.showsLowPowerAdvisory {
                Card(icon: "bolt.slash", tint: .orange, title: "Low Power Mode") {
                    Text(LowPowerAdvisory.message).font(.footnote)
                    Button("Dismiss") { model.dismissLowPowerAdvisory() }.buttonStyle(.bordered)
                }
            }
            ForEach(model.alertSnapshot?.banners ?? [], id: \.self) { banner in
                Card(icon: "exclamationmark.circle.fill", tint: .orange, title: banner.title) {
                    Text(banner.body).font(.subheadline)
                    if banner.opensSettings {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    if banner == .unknownBolusOutcome {
                        Button("I checked the pump") { confirmingOnPump = true }.buttonStyle(.bordered)
                    }
                }
            }
            if let status = model.latestOutcome, shows(status) {
                BolusBannerView(banner: BolusBanner.make(status.outcome, requestedUnits: status.requestedUnits))
            }
            if bolusInProgress {
                Button(role: .destructive) {
                    cancelTaps += 1
                    let tap = cancelTaps
                    cancelMessage = PumpMessages.cancelSent
                    Task {
                        let text = PumpMessages.text(await model.cancelBolus())
                        if tap == cancelTaps { cancelMessage = text }
                    }
                    Task {
                        try? await Task.sleep(for: PumpMessages.cancelSlowAfter)
                        if tap == cancelTaps, cancelMessage == PumpMessages.cancelSent {
                            cancelMessage = PumpMessages.cancelSlow
                        }
                    }
                } label: {
                    // While the cancel waits for the pump's answer the button says so; pressing it sends again.
                    Label(cancelInHand ? "Cancelling…" : "Cancel bolus", systemImage: "stop.fill").font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
            if let cancelMessage { Text(cancelMessage).font(.footnote).foregroundStyle(.secondary) }
            PumpAlertsList(model: model)
        }
        .padding(.horizontal)
        .sheet(isPresented: $showPairing) { PairingSheet(model: model) { showPairing = false } }
        .confirmationDialog(
            "Did you check the pump's history for this bolus?", isPresented: $confirmingOnPump,
            titleVisibility: .visible
        ) {
            Button("Yes, I checked the pump") { Task { await model.confirmUnknownOutcomesOnPump() } }
            Button("Not yet", role: .cancel) {}
        } message: {
            Text(
                "faBolus doesn't know how much of the last bolus went in. Confirming lets you bolus again; the "
                    + "outcome stays unknown until the pump's history settles it.")
        }
    }

    private var bolusInProgress: Bool {
        if case .inProgress = model.display.bolusState?.value { return true }
        if let o = model.latestOutcome?.outcome, o.isInFlight { return true }
        return false
    }

    /// A cancel was tapped and the pump hasn't answered it yet.
    private var cancelInHand: Bool {
        cancelMessage == PumpMessages.cancelSent || cancelMessage == PumpMessages.cancelSlow
    }

    /// An outcome stays up while it's in flight and for two minutes after it settles; an unknown one
    /// shows as the banner above instead.
    private func shows(_ status: AppModel.BolusStatus) -> Bool {
        if status.outcome.isUnknown { return false }
        return status.outcome.isInFlight || model.now.timeIntervalSince(status.at) < 120
    }
}

struct Card<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).font(.headline).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content
            }
            Spacer(minLength: 0)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }
}

struct BolusBannerView: View {
    let banner: BolusBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch banner.kind {
            case .inProgress: ProgressView()
            case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.inRange)
            case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.headline)
                if !banner.message.isEmpty { Text(banner.message).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding().frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
