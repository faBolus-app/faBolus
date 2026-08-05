import SwiftUI
import AVFoundation

/// A minimal macOS webcam QR scanner. Calls `onScan` once with the first decoded string. Requires the
/// camera entitlement + `NSCameraUsageDescription`. Used to scan the host iPhone's pairing QR.
struct MacQRScanner: NSViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeNSViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(); vc.onScan = onScan; return vc
    }
    func updateNSViewController(_ vc: ScannerVC, context: Context) {}

    final class ScannerVC: NSViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: ((String) -> Void)?
        private let session = AVCaptureSession()
        private let metadataOutput = AVCaptureMetadataOutput()
        private var preview: AVCaptureVideoPreviewLayer?
        private var didScan = false
        private var configured = false

        override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360)) }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.wantsLayer = true
            view.layer?.backgroundColor = .black
            session.beginConfiguration()
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input), session.canAddOutput(metadataOutput) else {
                session.commitConfiguration(); return
            }
            session.addInput(input)
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            session.commitConfiguration()
            configured = true
            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(preview)
            self.preview = preview
        }

        override func viewWillAppear() {
            super.viewWillAppear()
            guard configured, !session.isRunning else { return }
            // `startRunning()` blocks, so Apple recommends calling it off the main thread. `session` is a
            // main-actor-isolated property of this NSViewController, and `AVCaptureSession` is a
            // thread-safe reference type that is not formally `Sendable` — so capture it explicitly for
            // the background closure rather than reaching through `self`. Without this, Swift 6 strict
            // concurrency rejects the cross-actor reference; CI's Xcode 16.4 enforces it even though the
            // newer local toolchain did not, which is how this reached `main`.
            nonisolated(unsafe) let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                session.startRunning()
                // `availableMetadataObjectTypes` is only populated once the session is running with an
                // active connection (macOS differs from iOS). Setting `.qr` before that throws
                // NSInvalidArgumentException and hard-crashes — so set it here, guarded.
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                        self.metadataOutput.metadataObjectTypes = [.qr]
                    }
                }
            }
        }
        override func viewWillDisappear() {
            super.viewWillDisappear()
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
