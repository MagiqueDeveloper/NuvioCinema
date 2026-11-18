import CoreImage
import SwiftUI

/// Keep a bitmap cue readable if it cannot be converted into text. Use its bright
/// glyphs as a mask so the source's colors and dark outline do not carry through.
struct BitmapSubtitleFallback: View {
    let image: CGImage

    @State private var whiteGlyphs: (source: ObjectIdentifier, image: CGImage)?

    var body: some View {
        let styled = whiteGlyphs?.source == ObjectIdentifier(image) ? whiteGlyphs?.image : nil
        Image(decorative: styled ?? image, scale: 1, orientation: .up)
            .resizable()
            .background {
                if styled != nil {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.black.opacity(0.55))
                        .padding(.horizontal, -12)
                        .padding(.vertical, -6)
                }
            }
            .task(id: ObjectIdentifier(image)) {
                let image = image
                let rendered = await Task.detached(priority: .userInitiated) {
                    Self.makeWhiteGlyphs(from: image)
                }.value
                if !Task.isCancelled, let rendered {
                    whiteGlyphs = (ObjectIdentifier(image), rendered)
                }
            }
    }

    nonisolated private static let renderContext = CIContext(options: [.cacheIntermediates: false])

    nonisolated static func makeWhiteGlyphs(from image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        return renderContext.createCGImage(whiteGlyphs(of: source), from: source.extent)
    }

    /// Dark glyphs on a padded, opaque white canvas, scaled up when small, which is what
    /// text recognition reads best. The padding keeps edge characters such as `[` and `♪`
    /// inside the image, as bitmap cues are cropped tight to the glyphs.
    nonisolated static func makeRecognitionImage(from image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let height = source.extent.height
        guard height > 0, source.extent.width > 0 else { return nil }

        let black = whiteGlyphs(of: source).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
        let padding = max(16, height * 0.15)
        let canvas = source.extent.insetBy(dx: -padding, dy: -padding)
        var prepared = black.composited(over: CIImage(color: .white).cropped(to: canvas))
            .transformed(by: CGAffineTransform(translationX: -canvas.minX, y: -canvas.minY))

        let scale = min(3, max(1, 120 / height))
        if scale > 1 {
            prepared = prepared.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ])
        }
        let extent = CGRect(x: 0, y: 0, width: canvas.width * scale, height: canvas.height * scale).integral
        return renderContext.createCGImage(prepared.cropped(to: extent), from: extent)
    }

    /// White where the source has bright glyph fill, so the dark outline and any fill
    /// color drop out.
    nonisolated private static func whiteGlyphs(of source: CIImage) -> CIImage {
        let white = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.6, y: 0.6, z: 0.6, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: -0.1)
        ])
        return white.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: source
        ])
    }
}
