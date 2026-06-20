import CoreVideo
import Foundation

protocol PIIDetector {
    func detect(in pixelBuffer: CVPixelBuffer) -> [PIIBox]
}
