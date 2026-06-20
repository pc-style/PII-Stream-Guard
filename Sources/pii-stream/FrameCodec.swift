import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

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
    private static let boxPaddingHorizontal: CGFloat = 12
    private static let boxPaddingVertical: CGFloat = 8

    static func jpegData(from buffer: CVPixelBuffer, quality: CGFloat = 0.72) throws -> Data {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            throw FrameCodecError.cannotCreateImage
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw FrameCodecError.cannotEncode
        }
        return data
    }

    static func pixelBuffer(from data: Data) throws -> CVPixelBuffer {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FrameCodecError.cannotDecode
        }
        return try pixelBuffer(from: cgImage)
    }

    static func protectedJPEGData(
        from buffer: CVPixelBuffer,
        snapshot: DetectionSnapshot,
        maskMode: MaskMode = .blackout,
        quality: CGFloat = 0.72
    ) throws -> Data {
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
        ) else {
            throw FrameCodecError.cannotCreateBitmap
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.black.cgColor)
        if snapshot.blackoutWholeFrame {
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else if maskMode == .blackout {
            for box in snapshot.boxes {
                context.fill(pixelRect(for: box.normalizedRect, width: width, height: height))
            }
        }

        guard let protectedImage = context.makeImage() else {
            throw FrameCodecError.cannotCreateImage
        }
        let bitmap = NSBitmapImageRep(cgImage: protectedImage)
        guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw FrameCodecError.cannotEncode
        }
        return data
    }

    private static func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            image.width,
            image.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else {
            throw FrameCodecError.cannotDecode
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw FrameCodecError.cannotCreateBitmap
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func pixelRect(for rect: CGRect, width: Int, height: Int) -> CGRect {
        let x = rect.origin.x * CGFloat(width)
        let y = rect.origin.y * CGFloat(height)
        let w = rect.width * CGFloat(width)
        let h = rect.height * CGFloat(height)
        return CGRect(x: x, y: y, width: w, height: h)
            .insetBy(dx: -boxPaddingHorizontal, dy: -boxPaddingVertical)
    }
}
