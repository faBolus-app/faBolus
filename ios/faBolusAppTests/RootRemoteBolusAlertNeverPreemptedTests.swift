import Testing
import Foundation
@testable import faBolus

/// The root alert-priority ladder collapsed to its one surviving tier: `RootTabView` no longer
/// picks among competing alerts, it presents the remote-bolus confirm directly off
/// `model.pendingRemoteBolus != nil`. The one dose-safety property the deleted priority ladder
/// existed to guarantee — a staged remote-bolus confirm is never pre-empted by anything else the
/// root can present — now holds structurally as long as `RootTabView` presents exactly one
/// `.alert(...)`. Source-text pin because there is no runtime seam left to assert this
/// behaviorally: the priority function it used to exercise is gone. Modeled on
/// `BolusSuccessBannerDriftGuardTests`'s repo-root-walk + source-scan idiom.
struct RootRemoteBolusAlertNeverPreemptedTests {

    /// Resolve the repo root by walking up from `#filePath` until `project.yml` is found.
    private static func repoRootURL() -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent("project.yml")
            if fm.fileExists(atPath: candidate.path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    private static func rootTabViewSource() throws -> String {
        let repoRoot = try #require(
            Self.repoRootURL(),
            "could not resolve repo root from #filePath=\(#filePath)")
        let url = repoRoot.appendingPathComponent("ios/faBolus/Views/RootTabView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func rootTabViewPresentsExactlyOneAlert() throws {
        let source = try Self.rootTabViewSource()
        let count = source.components(separatedBy: ".alert(").count - 1
        #expect(
            count == 1,
            "RootTabView must present exactly one .alert(...) — a second would risk pre-empting the remote-bolus confirm")
    }

    @Test func rootTabViewGatesThatAlertOnPendingRemoteBolus() throws {
        let source = try Self.rootTabViewSource()
        #expect(
            source.contains("isPresented: .constant(model.pendingRemoteBolus != nil)"),
            "the remote-bolus confirm must be gated directly on model.pendingRemoteBolus, with nothing else able to suppress it")
    }

    @Test func fileResolutionActuallyFoundTheRepoRoot() {
        #expect(
            Self.repoRootURL() != nil,
            "drift-guard could not locate the repo root — path resolution broke (#filePath=\(#filePath))")
    }
}
