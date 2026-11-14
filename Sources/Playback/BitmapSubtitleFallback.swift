import CoreImage
import SwiftUI

/// Keep a bitmap cue readable if it cannot be converted into text. Use its bright
/// glyphs as a mask so the source's colors and dark outline do not carry through.
struct BitmapSubtitleFallback: View {
    let image: CGImage

    @State private var whiteGlyphs: (source: ObjectIdentifier, image: CGImage)?

    var body: some View {
        Group {
            if let whiteGlyphs, whiteGlyphs.source == ObjectIdentifier(image) {
                Image(decorative: whiteGlyphs.image, scale: 1, orientation: .up)
                    .resizable()
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.black.opacity(0.55))
                            .padding(.horizontal, -12)
                            .padding(.vertical, -6)
                    }
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
        let white = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0.6, y: 0.6, z: 0.6, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: -0.1)
        ])
        let clipped = white.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: source
        ])
        return renderContext.createCGImage(clipped, from: source.extent)
    }
}
