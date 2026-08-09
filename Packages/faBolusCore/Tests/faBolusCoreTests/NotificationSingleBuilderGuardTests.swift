import Testing
import Foundation

/// P9 / §6 exit criterion (owner-Q #5): the notification broker must be the **single builder** of
/// `UNNotificationRequest`. `NotificationPoster.post` (in `NotificationCoordinator.swift`) is the only
/// place allowed to construct one, so every notification necessarily passes through the broker's
/// suppression / dedupe / episode governance. This source-scan guard fails the always-run `swift test`
/// suite the moment a second builder appears anywhere in the shipping app targets (e.g. a pre-P9 poster
/// resurfacing on a merge) — the kind of regression manual inspection alone would miss. Mirrors
/// `RescueCarbGuardTests`' `#filePath`-rooted walk. Scans production source only (skips *Tests* paths;
/// a test legitimately building a request for its own assertions is not a violation).
struct NotificationSingleBuilderGuardTests {

    /// The ONE production file permitted to construct a `UNNotificationRequest` (it hosts `NotificationPoster`).
    private static let allowedFile = "NotificationCoordinator.swift"
    private static let marker = "UNNotificationRequest("

    /// Resolve the shipping-app source roots (`ios`, `Shared`) by walking up from `#filePath`
    /// (`<root>/Packages/faBolusCore/Tests/faBolusCoreTests/…`) to the repo root (the ancestor with `ios/`).
    private func appRoots() -> (dirs: [URL], foundApp: Bool) {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let ios = probe.appendingPathComponent("ios")
            if fm.fileExists(atPath: ios.path) {
                var dirs = [ios]
                let shared = probe.appendingPathComponent("Shared")
                if fm.fileExists(atPath: shared.path) { dirs.append(shared) }
                return (dirs, true)
            }
            probe = probe.deletingLastPathComponent()
        }
        return ([], false)
    }

    @Test func onlyNotificationPosterBuildsNotificationRequests() throws {
        let fm = FileManager.default
        let (dirs, foundApp) = appRoots()
        #expect(foundApp, "single-builder guard could not locate the app source root (#filePath=\(#filePath))")

        var scanned = 0
        var sawAllowedBuilder = false
        var violations: [String] = []
        for base in dirs {
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if url.path.contains("Tests") { continue }   // production source only
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                guard text.contains(Self.marker) else { continue }
                if url.lastPathComponent == Self.allowedFile { sawAllowedBuilder = true }
                else { violations.append(url.lastPathComponent) }
            }
        }
        // A path-resolution break (0 files) or a moved builder must fail loudly, not pass vacuously.
        #expect(scanned > 0, "single-builder guard scanned no files — path resolution broke")
        #expect(sawAllowedBuilder,
                "\(Self.allowedFile) no longer builds a UNNotificationRequest — did NotificationPoster move? Update this guard so it can't pass vacuously.")
        #expect(violations.isEmpty,
                "§6 single-builder invariant: UNNotificationRequest is constructed outside NotificationPoster in: \(violations.joined(separator: ", "))")
    }
}
