import SwiftUI

/// A shared, host-agnostic fallback for the QR scanners' camera-permission dead-end (Phase 09.4,
/// D-09/D-10). Both the iOS `QRScannerView` and macOS `MacQRScanner` used to silently `return` to a
/// `.black` view on any camera failure — this replaces that dead-end with an actionable message.
///
/// **Pure SwiftUI — imports ONLY SwiftUI.** No `AVFoundation`/`UIKit`/`AppKit` import, matching this
/// package's host-agnostic constraint (D-09). Each platform's scanner wrapper keeps its own
/// `AVCaptureDevice` authorization check and branches to this view from its SwiftUI body, supplying a
/// platform-correct `openSettings` closure — the shared view never touches a capture framework or a
/// platform UI framework directly.
///
/// This view supplies NO Cancel/dismiss chrome of its own — the host screen owns that (iOS's
/// `NavigationStack` toolbar Cancel, macOS's standalone Cancel button below the scanner slot). Only the
/// camera-preview area is ever replaced by this view.
public struct CameraPermissionFallbackView: View {
    /// Distinguishes "permission denied" (offer a Settings deep-link) from "no camera hardware present"
    /// (message only, per D-10 — never a dead/disabled button).
    public enum State: Equatable {
        case denied
        case noCamera
    }

    public let state: State
    public let openSettings: () -> Void

    public init(state: State, openSettings: @escaping () -> Void = {}) {
        self.state = state
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            // D2-08: decorative — the title/message text below already states the camera problem, so
            // hide the glyph from VoiceOver rather than announcing its raw symbol name.
            Image(systemName: "video.slash.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(.headline)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal)

            if state == .denied {
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch state {
        case .denied: return "Camera access needed"
        case .noCamera: return "No camera available"
        }
    }

    private var message: String {
        switch state {
        case .denied:
            return "faBolus needs camera access to scan a QR code. You can enable it in Settings."
        case .noCamera:
            return "This device doesn't have a camera. Enter the pairing code manually instead."
        }
    }
}
