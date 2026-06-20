import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

enum PixelBufferUtils {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var destination: CVPixelBuffer?

        // Keep the destination layout compatible with the source. We still copy
        // row-by-row below, because CoreVideo may give the destination a
        // different bytesPerRow (row padding/alignment) than the source — a
        // single memcpy sized by the source stride would then overrun the
        // destination and crash (EXC_BAD_ACCESS).
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attributes as CFDictionary,
            &destination
        )

        guard status == kCVReturnSuccess, let dest = destination else {
            return nil
        }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }

        if CVPixelBufferIsPlanar(source) {
            let planeCount = CVPixelBufferGetPlaneCount(source)
            guard CVPixelBufferGetPlaneCount(dest) == planeCount else { return nil }
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else {
                    return nil
                }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let rowBytes = min(srcStride, dstStride)
                for row in 0..<planeHeight {
                    memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
                }
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(dest) else {
                return nil
            }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(dest)
            let rowBytes = min(srcStride, dstStride)
            for row in 0..<height {
                memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
            }
        }

        return dest
    }

    static func resized(_ source: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height {
            return copy(source)
        }

        var destination: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &destination
        )

        guard status == kCVReturnSuccess, let dest = destination else {
            return nil
        }

        let scaleX = CGFloat(width) / CGFloat(CVPixelBufferGetWidth(source))
        let scaleY = CGFloat(height) / CGFloat(CVPixelBufferGetHeight(source))
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        ciContext.render(image, to: dest, bounds: bounds, colorSpace: rgbColorSpace)
        return dest
    }
}
