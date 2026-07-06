import CoreGraphics
import Foundation

/// How `detect-image` composes the saved PNG. Demo styling is opt-in via `--demo`.
public enum ImageOutputPresentation: Equatable {
    case standard
    case demo
}