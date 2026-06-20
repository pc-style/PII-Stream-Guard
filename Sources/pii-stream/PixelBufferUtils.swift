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

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            nil,
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
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else {
                    continue
                }
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane)
                memcpy(dst, src, bytes)
            }
        } else {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(dest) else {
                return nil
            }
            let bytes = CVPixelBufferGetBytesPerRow(source) * height
            memcpy(dst, src, bytes)
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
