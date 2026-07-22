import SwiftUI
import AVFoundation

/// A minimal camera QR scanner. Calls `onScan` once with the first decoded string, then stops.
/// Requires `NSCameraUsageDescription`. Used by the remote to scan the host's pairing QR.
struct QRScannerView: UIViewControllerRepresentable {
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
