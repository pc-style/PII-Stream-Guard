import Foundation

public struct DetectionRecipe: Equatable {
    public let needles: [String]
    public let checkEmail: Bool
    public let checkPhone: Bool
    public let mode: GuardMode
    public let settings: DetectorSettings

    public init(
        needles: [String] = [],
        checkEmail: Bool = true,
        checkPhone: Bool = true,
        mode: GuardMode = .standard,
        settings: DetectorSettings? = nil
    ) {
        self.needles = needles
        self.checkEmail = checkEmail
        self.checkPhone = checkPhone
        self.mode = mode
        self.settings = settings ?? mode.detectorSettings
    }

    func makeDetector() -> VisionPIIDetector {
        VisionPIIDetector(
            needles: needles,
            checkEmail: checkEmail,
            checkPhone: checkPhone,
            accurate: settings.accurate,
            maxPixelSize: settings.maxPixelSize,
            minimumTextHeight: settings.minimumTextHeight,
            enhanceLowContrast: settings.enhanceLowContrast
        )
    }

    static func frameProcessor(_ options: FrameProcessingOptions) -> DetectionRecipe {
        DetectionRecipe(
            needles: options.needles,
            checkEmail: options.checkEmail,
            checkPhone: options.checkPhone,
            mode: options.mode,
            settings: options.settingsOverride
        )
    }

    static func imageDetection(_ options: DetectImageOptions) -> DetectionRecipe {
        DetectionRecipe(
            needles: options.needles,
            checkEmail: options.checkEmail,
            checkPhone: options.checkPhone,
            mode: options.mode,
            settings: options.settingsOverride
        )
    }

    static func benchmark(_ options: BenchmarkOptions, settings: DetectorSettings = DetectorSettings()) -> DetectionRecipe {
        DetectionRecipe(
            needles: options.needles,
            checkEmail: options.checkEmail,
            checkPhone: options.checkPhone,
            mode: .standard,
            settings: settings
        )
    }
}
