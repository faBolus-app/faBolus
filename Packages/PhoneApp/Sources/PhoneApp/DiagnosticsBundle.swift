import Alerts
import Foundation
import PumpSession
import TandemLink
import WatchLink
import faBolusCore

/// The diagnostics export: what the pump link and the watch link did and why, the pump's identity, the
/// alerts showing and the ledger's outcomes. Times are the phone's; link times are seconds before export.
/// It holds no pairing code, password, Share account or glucose values.
struct DiagnosticsBundle {
    let generatedAt: Date
    let appVersion: String
    let pairing: StoredPairing?
    let pump: PumpState
    let link: LinkState
    let linkNow: LinkTime
    let watch: WatchLinkState?
    let alerts: AlertSnapshot?
    let ledger: RemoteBolusLedger
    let backupSourceID: String?
    let backup: GlucoseSourceState?
    let historySync: HistorySyncState
    let logbookCount: Int

    var text: String {
        var out: [String] = []
        func section(_ title: String) { out.append("\n## \(title)") }
        func ago(_ t: LinkTime) -> String { String(format: "%.0fs ago", linkNow - t) }
        let iso = ISO8601DateFormatter()

        out.append("faBolus diagnostics \(iso.string(from: generatedAt))")
        out.append("App: \(appVersion)")

        section("Pump")
        if let pairing {
            out.append("Model: \(pairing.model.rawValue), pairing: \(pairing.scheme.rawValue)")
            out.append("Advertised name: \(pairing.advertisedName ?? "-")")
            out.append("Trusted serial: \(pairing.trustedSerial.map(String.init) ?? "not yet")")
            out.append("Paired: \(iso.string(from: pairing.pairedAt))")
        } else {
            out.append("No pump paired")
        }
        out.append("Link: \(pump.link.rawValue)")
        if let api = pump.apiVersion?.value { out.append("API: \(api.major).\(api.minor)") }
        if let identity = link.connection?.identity ?? link.lastIdentity { out.append("Identity: \(identity)") }

        section("Pump link")
        out.append("Phase: \(link.phase)")
        out.append("Bluetooth: \(link.power)")
        out.append("App active (as the link knows it): \(link.appActive)")
        out.append("Reconnect ladder: flaps \(link.ladder.flaps), unstable reported \(link.ladder.reportedUnstable)")
        let t = link.telemetry
        out.append(
            "Connect attempts \(t.connectAttempts), connects \(t.connects), failed \(t.failedConnects), "
                + "disconnects \(t.disconnects)")
        out.append(String(format: "Uptime (closed spans): %.0fs", t.closedUptime))
        if let down = t.downSince { out.append("Down since: \(ago(down))") }
        if let r = t.lastReconnectDuration { out.append(String(format: "Last reconnect took %.1fs", r)) }
        out.append(
            "Sitting out (this connection, or after a drop until retested): \(link.sittingOut.map { "\($0)" }.sorted().joined(separator: ", "))"
        )
        out.append("Connections, newest last (up, held, reason, flaps after):")
        for span in t.spans.suffix(50) {
            out.append(
                String(
                    format: "  %@: %.0fs %@ %@ %@ flaps=%d", ago(span.closedAt), span.duration,
                    span.authenticated ? "auth" : "unauth", span.held ? "held" : "not-held",
                    String(describing: span.reason), span.flapsAfter))
        }
        out.append("Support matrix: \(link.support)")

        section("Watch link")
        if let watch {
            out.append("Phase: \(watch.phase.rawValue), device: \(watch.device.rawValue), paired: \(watch.paired)")
            out.append(
                "App installed: \(watch.appInstalled.map { "\($0)" } ?? "unknown"), legacy peer: \(watch.peerIsLegacy)")
            let w = watch.telemetry
            out.append(
                "Transmits \(w.transmits), delivered \(w.delivered), transient failures \(w.transientFailures), "
                    + "undeliverable \(w.undeliverable), app not found \(w.appNotFound), stalls \(w.stalls)")
            out.append(
                "Received \(w.received) (v1 \(w.receivedLegacy), other version \(w.receivedOtherVersion), "
                    + "malformed \(w.receivedMalformed), unexpected \(w.receivedUnexpected)), dropped \(w.dropped)")
            out.append(
                "Re-registrations \(w.reregistrations), probes \(w.probes), late completions \(w.lateCompletions)")
            if let f = w.lastFailure { out.append("Last failure: \(f)") }
            out.append("Transitions, newest last:")
            for tr in w.transitions {
                out.append("  \(Int(tr.at))s: \(tr.from.rawValue) → \(tr.to.rawValue) (\(tr.reason))")
            }
        } else {
            out.append("No watch transport in this build")
        }

        section("Alerts")
        if let alerts {
            out.append("Notifications off: \(alerts.permission.isOff)")
            out.append("Banners: \(alerts.banners.map { "\($0)" }.joined(separator: ", "))")
            for a in alerts.active { out.append("  \(a.category) \(a.severity): \(a.title)") }
        }
        if let pumpAlerts = pump.alerts {
            out.append("Pump alerts (read \(iso.string(from: pumpAlerts.measuredAt))):")
            for a in pumpAlerts.value {
                out.append("  \(a.kind) #\(a.id) \(a.title) clear=\(a.remoteClear.rawValue)")
            }
        }

        section("Bolus ledger")
        for e in ledger.allEntries.suffix(20) {
            out.append(
                "  \(e.key.peerId) \(iso.string(from: e.updatedAt)) \(e.outcome) pumpBolus=\(e.bolusId.map(String.init) ?? "-")"
                    + (e.confirmedOnPumpAt != nil ? " confirmed-on-pump" : ""))
        }

        section("Other")
        out.append("Backup CGM: \(backupSourceID ?? "none") \(backup.map { "\($0.status)" } ?? "")")
        out.append("History sync: \(historySync), logbook events: \(logbookCount)")
        return out.joined(separator: "\n")
    }
}
