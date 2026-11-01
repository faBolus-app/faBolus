import Foundation
import PhoneApp
import PumpScript
import SwiftUI
import UIKit
import faBolusCore

/// A phone over the scripted pump with fixed times: connected, readings in, a pump alert open and a
/// logbook, so every screen renders the same on every run.
@MainActor
enum SnapshotFixture {
    static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    static func model(paired: Bool = true, configure: (MockPump) -> Void = { _ in }) async -> AppModel {
        // Times and numbers render the same on any machine, CI's UTC included.
        NSTimeZone.default = timeZone
        let mock = MockPump(origin: origin)
        mock.pump.alertBitmap = 1 << 4
        configure(mock)
        let pump = mock.pump
        _ = pump.appendHistory(
            typeId: 280, at: pump.wallClockAtStart - 1800, body: [12, 0, 0, 0, 7, 0] + [UInt8](repeating: 0, count: 12))
        _ = pump.appendHistory(typeId: 288, at: pump.wallClockAtStart - 900, body: [])
        // Three hours of CGM records every 5 minutes, rising and falling.
        for i in 0..<36 {
            let mgdl = 120 + Int(55 * sin(Double(i) / 6))
            _ = pump.appendHistory(
                typeId: 256, at: pump.wallClockAtStart - 60 - UInt32((35 - i) * 300),
                body: [UInt8](repeating: 0, count: 6) + [UInt8(mgdl & 0xff), UInt8(mgdl >> 8)])
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "snap-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppSettings.Key.hasCompletedOnboarding.rawValue)
        defaults.set(true, forKey: AppSettings.Key.notificationDisclosureShown.rawValue)
        var env = mock.environment(directory: dir, settings: defaults, paired: paired)
        env.historyInMemory = true
        let model = AppModel(environment: env)
        await model.launch(appActive: true)
        await mock.run(model, for: paired ? 15 : 2)
        if paired { await mock.syncHistory(model) }
        await mock.run(model, for: 2)
        return model
    }
}

extension View {
    /// The view as the app shows it, on an iPhone-sized screen.
    @MainActor func hosted(dark: Bool) -> UIViewController {
        let host = UIHostingController(
            rootView: self.environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.timeZone, SnapshotFixture.timeZone)
                .environment(\.locale, Locale(identifier: "en_US")))
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        return host
    }
}
