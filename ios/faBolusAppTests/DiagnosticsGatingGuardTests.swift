import Testing
import Foundation
@testable import faBolus

/// Phase 09.6-01 (Task 2, Part A/D-01): pins the formalization that the app-side BLE pairing/
/// transaction diagnostics (`BLESessionLog.record` + `DebugMenuView`'s export-write path) are
/// PERMANENT first-class — never behind a debug-only compilation gate. 09.6-RESEARCH.md's Summary
/// found no such gate exists today; this guard makes that fact self-enforcing so a future edit can't
/// silently re-introduce one.
///
/// Mirrors `SettingsReachabilityGuardTests`' `#filePath`-rooted directory-walk technique, applied to
/// two specific files rather than a whole directory.
struct DiagnosticsGatingGuardTests {
    /// Resolve a repo-relative path by walking up from `#filePath`
    /// (`<root>/ios/faBolusAppTests/DiagnosticsGatingGuardTests.swift`) — same technique as
    /// `SettingsReachabilityGuardTests.viewsDirURL()`.
    private static func resolve(_ relativePath: String) -> URL? {
        let fm = FileManager.default
        var probe = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = probe.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            probe = probe.deletingLastPathComponent()
        }
        return nil
    }

    /// Whether `lines[targetLineIndex]` sits inside any currently-open `#if`/`#elseif` conditional-
    /// compilation branch whose condition text names a debug/temporary build flag (semantically —
    /// tracks the directive's OWN condition text rather than matching a hardcoded literal token, so a
    /// differently-spelled temporary flag, e.g. `#if DEBUG_DIAGNOSTICS` or `#if TEMP_...`, is still
    /// caught). A plain `#if RELEASE`-style block (no debug/temp semantics) is not flagged.
    private static func isInsideDebugOnlyDirective(lines: [String], targetLineIndex: Int) -> Bool {
        var stack: [String] = []
        for i in 0..<targetLineIndex {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                stack.append(String(trimmed.dropFirst("#if ".count)))
            } else if trimmed.hasPrefix("#elseif ") {
                if !stack.isEmpty { stack.removeLast() }
                stack.append(String(trimmed.dropFirst("#elseif ".count)))
            } else if trimmed.hasPrefix("#else") {
                if !stack.isEmpty { stack.removeLast() }
                stack.append("")   // else-branch condition is the negation — not itself a debug token
            } else if trimmed.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            }
        }
        let debugTokens = ["DEBUG", "TEMP", "TEMPORARY"]
        return stack.contains { cond in
            let upper = cond.uppercased()
            return debugTokens.contains { upper.contains($0) }
        }
    }

    private static func lineIndex(of needle: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.contains(needle) }
    }

    // MARK: - D-01: the record path is never debug-only gated

    @Test func bleSessionLogRecordPathIsNotDebugOnlyGated() throws {
        guard let url = Self.resolve("ios/faBolus/Data/BLESessionLog.swift") else {
            Issue.record("could not resolve ios/faBolus/Data/BLESessionLog.swift from #filePath=\(#filePath)")
            return
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")

        guard let recordLine = Self.lineIndex(of: "func record(_ kind: Entry.Kind", in: lines) else {
            Issue.record("could not locate BLESessionLog.record(_:detail:at:) — resolution/signature drift")
            return
        }
        #expect(!Self.isInsideDebugOnlyDirective(lines: lines, targetLineIndex: recordLine),
                "BLESessionLog.record is wrapped in a debug-only compilation gate — D-01 requires it permanent")
    }

    // MARK: - D-01: the export-write path is never debug-only gated

    @Test func debugMenuExportWritePathIsNotDebugOnlyGated() throws {
        guard let url = Self.resolve("ios/faBolus/Views/DebugMenuView.swift") else {
            Issue.record("could not resolve ios/faBolus/Views/DebugMenuView.swift from #filePath=\(#filePath)")
            return
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let lines = source.components(separatedBy: "\n")

        guard let writeLine = Self.lineIndex(of: "func writeDiagnosticsExportFile(_ text: String)", in: lines) else {
            Issue.record("could not locate DebugMenuView.writeDiagnosticsExportFile — resolution/signature drift")
            return
        }
        #expect(!Self.isInsideDebugOnlyDirective(lines: lines, targetLineIndex: writeLine),
                "writeDiagnosticsExportFile is wrapped in a debug-only compilation gate — D-01 requires it permanent")
    }

    // MARK: - A path-resolution bug must fail loudly, not pass vacuously

    @Test func fileResolutionActuallyFoundBothFiles() {
        #expect(Self.resolve("ios/faBolus/Data/BLESessionLog.swift") != nil)
        #expect(Self.resolve("ios/faBolus/Views/DebugMenuView.swift") != nil)
    }
}
