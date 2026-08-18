// Ported from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  FoodFinder_ScannerView.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  FoodFinder — Barcode scanner camera view using AVFoundation.
//
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//
//  faBolus adapter deltas (09.18c-02, D-13 / Pitfall 5):
//    • the AVFoundation `CameraPreviewView` + the `BarcodeScannerService` Vision pipeline are preserved;
//      this view only hands a decoded barcode STRING to `onBarcodeScanned` — it carries NO carb store,
//      carb entry, bolus calculator, or delivery symbol (the D-18.1 source-scan guard asserts this).
//    • camera-permission denial / no capture device NO LONGER shows a black capture view or a Loop
//      permission alert — it routes through `faBolusDesign.CameraPermissionFallbackView` (denied →
//      Open Settings; no-camera/Simulator → message only). Manual carb entry in FoodFinderView is
//      never blocked (Pitfall 5).
//    • the mirror's Loop-only `.supportedInterfaceOrientations(.all)` modifier, "Loop" copy, and the
//      simulated scan-stage theatrics are dropped; surfaces are re-skinned with system tokens.

import SwiftUI
import AVFoundation
import Combine
import UIKit
import faBolusDesign

/// SwiftUI view for barcode scanning with a live camera preview + a scanning reticle. On a successful
/// scan it hands the decoded barcode string to `onBarcodeScanned`, then dismisses itself. Camera denial
/// or a missing camera degrades to `CameraPermissionFallbackView` — never a silent black screen.
struct BarcodeScannerView: View {
    @ObservedObject private var scannerService = BarcodeScannerService.shared
    @Environment(\.dismiss) private var dismiss

    /// The ONLY output of this surface: the decoded barcode string, handed to the caller which resolves
    /// it via OpenFoodFacts into the shared carb-estimate card. No estimate/dose logic lives here.
    let onBarcodeScanned: (String) -> Void
    /// Called when the user cancels the scanner (optional).
    var onCancel: () -> Void = {}

    @State private var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var noCameraDevice = false
    @State private var cancellables = Set<AnyCancellable>()

    var body: some View {
        content
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        scannerService.stopScanning()
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if showsCameraSurface {
                        flashlightButton
                    }
                }
            }
            .onAppear { start() }
            .onDisappear { scannerService.stopScanning() }
    }

    // MARK: - Camera-state routing

    /// True when the live camera surface (not a fallback) is what the body is showing.
    private var showsCameraSurface: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return !noCameraDevice && (cameraStatus == .authorized || cameraStatus == .notDetermined)
        #endif
    }

    @ViewBuilder private var content: some View {
        #if targetEnvironment(simulator)
        // The Simulator has no camera — show the manual-entry fallback, never a black capture view.
        CameraPermissionFallbackView(state: .noCamera)
        #else
        if noCameraDevice {
            CameraPermissionFallbackView(state: .noCamera)
        } else {
            switch cameraStatus {
            case .denied, .restricted:
                CameraPermissionFallbackView(state: .denied, openSettings: openSettings)
            case .notDetermined, .authorized:
                scannerSurface
            @unknown default:
                CameraPermissionFallbackView(state: .noCamera)
            }
        }
        #endif
    }

    private var scannerSurface: some View {
        GeometryReader { geometry in
            ZStack {
                CameraPreviewView(scanner: scannerService)
                    .ignoresSafeArea()

                // Dimmed overlay with a clear reticle cut out of the center.
                Color.black.opacity(0.45)
                    .mask(
                        Rectangle()
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .frame(width: 260, height: 160)
                                    .blendMode(.destinationOut)
                            )
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white, lineWidth: 2)
                        .frame(width: 260, height: 160)
                    if scannerService.isScanning {
                        AnimatedScanLine()
                            .frame(width: 240)
                    }
                }

                VStack {
                    Spacer()
                    Text("Point the camera at a food barcode")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 32)
                }
            }
        }
    }

    private var flashlightButton: some View {
        Button {
            toggleFlashlight()
        } label: {
            Image(systemName: "flashlight.on.fill")
        }
        .accessibilityLabel("Toggle flashlight")
    }

    // MARK: - Lifecycle

    private func start() {
        cancellables.removeAll()

        // Publish decoded barcodes → caller (once per distinct code), then dismiss the scanner.
        scannerService.$lastScanResult
            .compactMap { $0 }
            .removeDuplicates { $0.barcodeString == $1.barcodeString }
            .throttle(for: .milliseconds(500), scheduler: DispatchQueue.main, latest: false)
            .sink { result in
                scannerService.stopScanning()
                onBarcodeScanned(result.barcodeString)
                dismiss()
            }
            .store(in: &cancellables)

        // A missing-camera hardware error → the no-camera fallback (never a black capture view).
        scannerService.$scanError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { error in
                if error == .cameraNotAvailable { noCameraDevice = true }
            }
            .store(in: &cancellables)

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraStatus = status
        switch status {
        case .authorized:
            scannerService.startScanning()
        case .notDetermined:
            scannerService.requestCameraPermission()
                .receive(on: DispatchQueue.main)
                .sink { granted in
                    cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    if granted { scannerService.startScanning() }
                }
                .store(in: &cancellables)
        default:
            break // denied/restricted → the fallback view handles it
        }
    }

    private func toggleFlashlight() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = device.torchMode == .on ? .off : .on
            device.unlockForConfiguration()
        } catch {
            // Torch unavailable — non-fatal, scanning continues without it.
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Camera Preview

/// UIViewRepresentable wrapper for AVCaptureVideoPreviewLayer (ported from the mirror).
struct CameraPreviewView: UIViewRepresentable {
    @ObservedObject var scanner: BarcodeScannerService

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Only proceed with valid bounds and an authorized camera.
        guard uiView.bounds.width > 0, uiView.bounds.height > 0,
              scanner.cameraAuthorizationStatus == .authorized else {
            return
        }

        let existingLayers = uiView.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer } ?? []

        // Reuse an existing preview layer if its bounds already match.
        if let existingLayer = existingLayers.first, existingLayer.frame == uiView.bounds {
            return
        }
        for layer in existingLayers {
            layer.removeFromSuperlayer()
        }

        if let previewLayer = scanner.getPreviewLayer() {
            previewLayer.frame = uiView.bounds
            previewLayer.videoGravity = .resizeAspectFill

            if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
                switch UIDevice.current.orientation {
                case .portrait: connection.videoOrientation = .portrait
                case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
                case .landscapeLeft: connection.videoOrientation = .landscapeRight
                case .landscapeRight: connection.videoOrientation = .landscapeLeft
                default: connection.videoOrientation = .portrait
                }
            }

            uiView.layer.insertSublayer(previewLayer, at: 0)
        }
    }
}

// MARK: - Animated Scan Line

/// Animated scanning line overlay (ported from the mirror).
struct AnimatedScanLine: View {
    @State private var animationOffset: CGFloat = -75

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .green, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 2)
            .offset(y: animationOffset)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    animationOffset = 75
                }
            }
    }
}
