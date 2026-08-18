import Testing
import Foundation
@testable import faBolusDesign

/// **Host-agnostic drift-guard (Phase 09.4, D-09; T-09.4-07).** `CameraPermissionFallbackView` must stay
/// pure SwiftUI so `faBolusDesign` never gains a hard dependency on a capture framework or a
/// platform-UI framework — each host (iOS/macOS) keeps its own `AVCaptureDevice` auth check and only
/// hands this view an opaque `openSettings` closure. A source-scan of the actual `Sources` file (not
/// just a unit test of the type) is the only thing that catches a future "just add `import AVFoundation`
/// for one convenience call" regression, since Swift import statements aren't otherwise observable at
/// runtime.
struct CameraFallbackHostAgnosticTests {

    /// Locate `CameraPermissionFallbackView.swift` relative to this test file's own `#filePath`
    /// (`<pkg>/Tests/faBolusDesignTests/CameraFallbackHostAgnosticTests.swift` →
    /// `<pkg>/Sources/faBolusDesign/CameraPermissionFallbackView.swift`).
    private static func sourceFileURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // faBolusDesignTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // faBolusDesign/ (package root)
            .appendingPathComponent("Sources/faBolusDesign/CameraPermissionFallbackView.swift")
    }

    @Test func fileResolutionActuallyFoundTheSourceFile() {
        #expect(FileManager.default.fileExists(atPath: Self.sourceFileURL().path),
                "drift-guard could not locate CameraPermissionFallbackView.swift at \(Self.sourceFileURL().path) — path resolution broke")
    }

    @Test func importsOnlySwiftUINoCaptureOrPlatformUIFramework() throws {
        let url = Self.sourceFileURL()
        let source = try String(contentsOf: url, encoding: .utf8)
        let importLines = source
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("import ") }

        #expect(importLines.contains("import SwiftUI"),
                "expected CameraPermissionFallbackView.swift to import SwiftUI")

        let forbidden = ["AVFoundation", "UIKit", "AppKit"]
        for line in importLines {
            for name in forbidden {
                #expect(!line.contains(name),
                        "CameraPermissionFallbackView.swift must stay host-agnostic — found forbidden import '\(line)' (D-09)")
            }
        }
        #expect(!importLines.isEmpty, "expected at least one import line — scan broke (would otherwise pass vacuously)")
    }

    @MainActor
    @Test func bothStateCasesConstruct() {
        let denied = CameraPermissionFallbackView(state: .denied, openSettings: {})
        let noCamera = CameraPermissionFallbackView(state: .noCamera, openSettings: {})
        #expect(denied.state == .denied)
        #expect(noCamera.state == .noCamera)
    }
}
