import SwiftUI
import AVFoundation
import faBolusDesign

/// A minimal camera QR scanner. Calls `onScan` once with the first decoded string, then stops.
/// Requires `NSCameraUsageDescription`. Used by the remote to scan the host's pairing QR.
///
/// Branches on this device's own camera authorization/availability (Phase 09.4, D-09) instead of
/// silently falling back to a black screen: `.denied`/`.restricted` and "no camera hardware" both
/// render the shared `CameraPermissionFallbackView`; `.authorized`/`.notDetermined` render the real
/// scanner (the `.notDetermined` case lets `QRScannerRepresentable`'s own AVFoundation session trigger
/// the system permission prompt exactly as before). Supplies no Cancel/dismiss chrome of its own — the
/// call site's `NavigationStack` toolbar Cancel (`RemoteControlView.swift`) still owns dismissal.
struct QRScannerView: View {
    let onScan: (String) -> Void

    var body: some View {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            CameraPermissionFallbackView(state: .denied) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        default:
            if AVCaptureDevice.default(for: .video) == nil {
                CameraPermissionFallbackView(state: .noCamera)
            } else {
                QRScannerRepresentable(onScan: onScan)
            }
        }
    }
}

/// The actual camera-capture representable — behavior byte-identical to the pre-09.4-03
/// `QRScannerView`, just renamed so the SwiftUI wrapper above can branch to either it or the shared
/// permission-fallback view.
struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onScan = onScan
        return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var didScan = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.addSublayer(preview)
            self.preview = preview
        }
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.layer.bounds
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() } }
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject],
                                        from connection: AVCaptureConnection) {
            guard let obj = objs.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            Task { @MainActor in
                guard !self.didScan else { return }
                self.didScan = true
                self.session.stopRunning()
                self.onScan?(value)
            }
        }
    }
}
