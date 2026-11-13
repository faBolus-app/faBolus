import GlucoseSources
import PhoneApp
import PumpSession
import SwiftUI

struct AboutSettingsView: View {
    @Bindable var model: AppModel
    /// The version and build shown; the snapshot test sets them, so its image doesn't change with each build.
    var version = AppModel.appVersion
    var build = AppRevision.commit
    @State private var export: DiagnosticsExport?

    var body: some View {
        Form {
            Section {
                Link(destination: URL(string: "https://fabolus.org")!) {
                    Label("Help & documentation", systemImage: "questionmark.circle")
                }
                LabeledContent("Version", value: version)
                LabeledContent("Build", value: build)
            }
            Section {
                Button {
                    Task { export = DiagnosticsExport(text: await model.diagnostics(), revision: AppRevision.commit) }
                } label: {
                    Label("Export diagnostics", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text(
                    "A text file for debugging: the pump and watch connection history, the pump's identity, alerts and bolus outcomes. It has no pairing code, password or glucose readings. Share it only with people you trust."
                )
            }
            if let id = model.backupSourceID, [GlucoseSourceRegistry.g6ID, GlucoseSourceRegistry.g7ID].contains(id) {
                Section {
                    Button {
                        Task {
                            let text = await model.bluetoothCGMRecording() ?? ""
                            export = DiagnosticsExport(text: text, revision: AppRevision.commit, name: "dexcom-session")
                        }
                    } label: {
                        Label("Export Dexcom Bluetooth log", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(
                        "Everything the Dexcom transmitter sent since faBolus started, for checking the direct G6 or G7 link. It includes glucose readings and the transmitter's identity."
                    )
                }
            }
            #if DEBUG
            Section {
                NavigationLink {
                    DebugMenuView(model: model)
                } label: {
                    Label("Debug", systemImage: "ladybug.fill")
                }
            }
            #endif
            Section {
            } footer: {
                Text(RegulatoryCopy.about)
            }
        }
        .navigationTitle("About & help")
        .sheet(item: $export) { e in ShareSheet(items: [e.fileURL]) }
    }
}

struct DiagnosticsExport: Identifiable {
    let id = UUID()
    let fileURL: URL

    init(text: String, revision: String, name: String = "diagnostics") {
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("faBolus-\(name)-\(stamp).txt")
        // A comment line, so a Dexcom session export still parses as a `DexcomSessionLog`.
        try? ("# Build \(revision)\n" + text).write(to: fileURL, atomically: true, encoding: .utf8)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#if DEBUG
/// Debug builds only: the scripted pump instead of a real one, and retesting a command the pump rejected.
struct DebugMenuView: View {
    @Bindable var model: AppModel
    @AppStorage(DebugMock.key) private var mockPump = false
    @State private var retestable: [PumpSession.RetestableCommand] = []

    var body: some View {
        Form {
            Section {
                Toggle("Use the scripted pump", isOn: $mockPump)
            } footer: {
                Text(
                    "Runs the real session against a scripted t:slim instead of Bluetooth. Takes effect when the app is reopened."
                )
            }
            Section("Now") {
                LabeledContent("Mock pump", value: model.isMock ? "on" : "off")
                LabeledContent("Logbook events", value: "\(model.logbook.count)")
            }
            Section {
                if retestable.isEmpty { Text("None") }
                ForEach(retestable) { command in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(command.name)
                            Text(Self.label(command.reason)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Retest") {
                            Task {
                                await model.retest(command)
                                retestable = await model.retestableCommands()
                            }
                        }
                    }
                }
            } header: {
                Text("Commands not sent to this pump")
            } footer: {
                Text(
                    "Retest forgets what this pump did with a command, so it's sent again. A command the pump doesn't have can make it drop the link once more."
                )
            }
        }
        .navigationTitle("Debug")
        .task { retestable = await model.retestableCommands() }
    }

    private static func label(_ reason: PumpSession.RetestableCommand.Reason) -> String {
        switch reason {
        case .unsupported: return "The pump doesn't answer it"
        case .suspected: return "The link dropped after it once"
        case .sittingOut: return "Errored on this connection"
        }
    }
}
#endif
