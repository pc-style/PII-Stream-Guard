import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO

enum FrameCodecError: Error, LocalizedError {
    case cannotCreateImage
    case cannotEncode
    case cannotDecode
    case cannotCreateBitmap

    var errorDescription: String? {
        switch self {
        case .cannotCreateImage:
            return "Could not create image from pixel buffer."
        case .cannotEncode:
            return "Could not encode frame."
        case .cannotDecode:
            return "Could not decode frame."
        case .cannotCreateBitmap:
            return "Could not create bitmap context."
        }
    }
}

enum FrameCodec {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    static func jpegData(
        from buffer: CVPixelBuffer,
        quality: CGFloat = 0.72,
        maxPixelSize: CGFloat? = nil
    ) throws -> Data {
        var image = CIImage(cvPixelBuffer: buffer)
        if let maxPixelSize, maxPixelSize > 0 {
            let longest = max(image.extent.width, image.extent.height)
            if longest > maxPixelSize {
                let scale = maxPixelSize / longest
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality,
        ]
        guard let data = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: options
        ) else {
            throw FrameCodecError.cannotEncode
        }
        return data
    }

    static func pixelBuffer(from data: Data) throws -> CVPixelBuffer {
        guard let image = CIImage(data: data),
              image.extent.width.isFinite,
              image.extent.height.isFinite else {
            throw FrameCodecError.cannotDecode
        }
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        guard width > 0, height > 0,
              let buffer = PixelBufferUtils.makeBuffer(
                  width: width,
                  height: height,
                  pixelFormat: kCVPixelFormatType_32BGRA
              ) else {
            throw FrameCodecError.cannotDecode
        }
        ciContext.render(
            image,
            to: buffer,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
        return buffer
    }

    static func protectedCGImage(
        from buffer: CVPixelBuffer,
        boxes: [PIIBox],
        guardMode: GuardMode,
        maskMode: MaskMode = .blackout,
        blackoutWholeFrame: Bool = false,
        attribution: ImageAttributionStyle = .none,
        presentation: ImageOutputPresentation = .standard
    ) throws -> CGImage {
        let source = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(source, from: source.extent) else {
            throw FrameCodecError.cannotCreateImage
        }
        let width = cgImage.width
        let height = cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FrameCodecError.cannotCreateBitmap
        }

        let frameSize = CGSize(width: width, height: height)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        if blackoutWholeFrame || !boxes.isEmpty {
            FrameMasker.drawMasks(
                in: context,
                frameSize: frameSize,
                boxes: boxes,
                maskMode: maskMode,
                guardMode: guardMode,
                blackoutWholeFrame: blackoutWholeFrame,
                rectMapping: .topLeftToBottomLeft,
                presentation: presentation
            )
        }
        if presentation == .demo {
            ImageDemoFrame.draw(in: context, imageSize: frameSize)
        } else {
            ImageAttribution.draw(in: context, imageSize: frameSize, style: attribution)
        }

        guard let protectedImage = context.makeImage() else {
            throw FrameCodecError.cannotCreateImage
        }
        return protectedImage
    }

    static func protectedJPEGData(
        from buffer: CVPixelBuffer,
        snapshot: DetectionSnapshot,
        maskMode: MaskMode = .blackout,
        quality: CGFloat = 0.72
    ) throws -> Data {
        let protectedImage = try protectedCGImage(
            from: buffer,
            boxes: snapshot.boxes,
            guardMode: snapshot.guardMode,
            maskMode: maskMode,
            blackoutWholeFrame: snapshot.blackoutWholeFrame,
            attribution: .none
        )
        let bitmap = NSBitmapImageRep(cgImage: protectedImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw FrameCodecError.cannotEncode
        }
        return data
    }

}
