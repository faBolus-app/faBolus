import SwiftUI
import CoreImage.CIFilterBuiltins

/// Renders a string as a QR code. Used by the host phone to show a pairing QR a remote can scan.
struct QRCodeView: View {
    let string: String
    var size: CGFloat = 220

    var body: some View {
        if let img = Self.image(from: string) {
            Image(uiImage: img)
                .interpolation(.none)          // keep the modules crisp
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("Pairing QR code")
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    static func image(from string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
