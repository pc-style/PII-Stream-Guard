import CoreGraphics
import Foundation

public struct WatchOptions {
    var needles: [String] = []
    var checkEmail: Bool = true
    var checkPhone: Bool = true
    var fps: Double?
    var mode: GuardMode = .standard
    var settingsOverride: DetectorSettings?
    var remote: String?
    var token: String?
    var placement: WindowPlacement = .center
    var previewPresentation: PreviewPresentation = .window

    var processingOptions: FrameProcessingOptions {
        FrameProcessingOptions(
            needles: needles,
            checkEmail: checkEmail,
            checkPhone: checkPhone,
            fps: fps,
            mode: mode,
            settingsOverride: settingsOverride
        )
    }
}

public struct ServeOptions {
    var host: String = "127.0.0.1"
    var port: UInt16 = 8765
    var token: String?
}

public enum CLI {
    public static func parse(_ args: [String]) throws -> Command {
        if args.contains(where: { $0 == "--help" || $0 == "-h" }) {
            throw CLIError.help
        }
        guard args.count >= 2 else {
            throw CLIError.usage
        }

        switch args[1] {
        case "watch":
            return .watch(try parseWatchOptions(Array(args.dropFirst(2))))
        case "serve":
            return .serve(try parseServeOptions(Array(args.dropFirst(2))))
        case "benchmark":
            return .benchmark(try parseBenchmarkOptions(Array(args.dropFirst(2))))
        case "detect-image":
            return .detectImage(try parseDetectImageOptions(Array(args.dropFirst(2))))
        default:
            throw CLIError.usage
        }
    }

    private struct DetectorOverrideFlags {
        var accurate: Bool?
        var minimumTextHeight: Float?
        var maxPixelSize: CGFloat?
        var enhanceLowContrast: Bool?

        var hasAny: Bool {
            accurate != nil || minimumTextHeight != nil || maxPixelSize != nil || enhanceLowContrast != nil
        }

        func applied(to base: DetectorSettings) -> DetectorSettings {
            var settings = base
            if let accurate { settings.accurate = accurate }
            if let minimumTextHeight { settings.minimumTextHeight = minimumTextHeight }
            if let maxPixelSize { settings.maxPixelSize = maxPixelSize }
            if let enhanceLowContrast { settings.enhanceLowContrast = enhanceLowContrast }
            return settings
        }
    }

    private static func parseWatchOptions(_ args: [String]) throws -> WatchOptions {
        var options = WatchOptions()
        var detectorOverrides = DetectorOverrideFlags()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                options.needles.append(args[i])
            case "--no-email":
                options.checkEmail = false
            case "--no-phone":
                options.checkPhone = false
            case "--fps":
                i += 1
                guard i < args.count, let fps = Double(args[i]), fps > 0 else {
                    throw CLIError.invalidValue("--fps")
                }
                options.fps = fps
            case "--mode":
                i += 1
                guard i < args.count, let mode = parseGuardMode(args[i]) else {
                    throw CLIError.invalidValue("--mode")
                }
                options.mode = mode
            case "--accurate":
                detectorOverrides.accurate = true
            case "--min-text-height":
                i += 1
                guard i < args.count, let value = Float(args[i]), value > 0, value < 1 else {
                    throw CLIError.invalidValue("--min-text-height")
                }
                detectorOverrides.minimumTextHeight = value
            case "--max-pixel-size":
                i += 1
                guard i < args.count, let value = Double(args[i]), value > 0 else {
                    throw CLIError.invalidValue("--max-pixel-size")
                }
                detectorOverrides.maxPixelSize = CGFloat(value)
            case "--enhance-low-contrast":
                detectorOverrides.enhanceLowContrast = true
            case "--position":
                i += 1
                guard i < args.count, let placement = WindowPlacement(rawValue: args[i]) else {
                    throw CLIError.invalidValue("--position")
                }
                options.placement = placement
            case "--preview":
                i += 1
                guard i < args.count, let presentation = PreviewPresentation(rawValue: args[i]) else {
                    throw CLIError.invalidValue("--preview")
                }
                options.previewPresentation = presentation
            case "--overlay":
                options.previewPresentation = .screenOverlay
            case "--remote":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--remote") }
                options.remote = args[i]
            case "--token":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--token") }
                options.token = args[i]
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }
        if detectorOverrides.hasAny {
            options.settingsOverride = detectorOverrides.applied(to: options.mode.detectorSettings)
        }
        return options
    }

    private static func parseServeOptions(_ args: [String]) throws -> ServeOptions {
        var options = ServeOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--host":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--host") }
                options.host = args[i]
            case "--port":
                i += 1
                guard i < args.count, let port = UInt16(args[i]), port > 0 else {
                    throw CLIError.invalidValue("--port")
                }
                options.port = port
            case "--token":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--token") }
                options.token = args[i]
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }
        return options
    }

    private static func parseDetectImageOptions(_ args: [String]) throws -> DetectImageOptions {
        var imagePath: String?
        var needles: [String] = []
        var checkEmail = true
        var checkPhone = true
        var mode: GuardMode = .standard
        var detectorOverrides = DetectorOverrideFlags()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--image":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--image") }
                imagePath = args[i]
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                needles.append(args[i])
            case "--json":
                break
            case "--no-email":
                checkEmail = false
            case "--no-phone":
                checkPhone = false
            case "--mode":
                i += 1
                guard i < args.count, let parsed = parseGuardMode(args[i]) else {
                    throw CLIError.invalidValue("--mode")
                }
                mode = parsed
            case "--accurate":
                detectorOverrides.accurate = true
            case "--min-text-height":
                i += 1
                guard i < args.count, let value = Float(args[i]), value > 0, value < 1 else {
                    throw CLIError.invalidValue("--min-text-height")
                }
                detectorOverrides.minimumTextHeight = value
            case "--max-pixel-size":
                i += 1
                guard i < args.count, let value = Double(args[i]), value > 0 else {
                    throw CLIError.invalidValue("--max-pixel-size")
                }
                detectorOverrides.maxPixelSize = CGFloat(value)
            case "--enhance-low-contrast":
                detectorOverrides.enhanceLowContrast = true
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }

        guard let imagePath else { throw CLIError.missingValue("--image") }
        return DetectImageOptions(
            imagePath: imagePath,
            needles: needles,
            checkEmail: checkEmail,
            checkPhone: checkPhone,
            mode: mode,
            settingsOverride: detectorOverrides.hasAny
                ? detectorOverrides.applied(to: mode.detectorSettings)
                : nil
        )
    }

    private static func parseBenchmarkOptions(_ args: [String]) throws -> BenchmarkOptions {
        var options = BenchmarkOptions()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                options.needles.append(args[i])
            case "--no-email":
                options.checkEmail = false
            case "--no-phone":
                options.checkPhone = false
            case "--duration":
                i += 1
                guard i < args.count, let duration = Double(args[i]), duration > 0 else {
                    throw CLIError.invalidValue("--duration")
                }
                options.duration = duration
            case "--output":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--output") }
                options.outputPath = args[i]
            case "--csv":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--csv") }
                options.csvPath = args[i]
            default:
                throw CLIError.unknownFlag(args[i])
            }
            i += 1
        }
        return options
    }

    private static func parseDetectorSettings(_ value: String) -> DetectorSettings? {
        var settings = DetectorSettings()
        for part in value.split(separator: ",") {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return nil }
            switch pieces[0] {
            case "accurate":
                if pieces[1] == "true" {
                    settings.accurate = true
                } else if pieces[1] == "false" {
                    settings.accurate = false
                } else {
                    return nil
                }
            case "maxPixelSize":
                guard let parsed = Double(pieces[1]), parsed > 0 else { return nil }
                settings.maxPixelSize = CGFloat(parsed)
            case "minimumTextHeight":
                guard let parsed = Float(pieces[1]), parsed > 0, parsed < 1 else { return nil }
                settings.minimumTextHeight = parsed
            case "enhanceLowContrast":
                if pieces[1] == "true" {
                    settings.enhanceLowContrast = true
                } else if pieces[1] == "false" {
                    settings.enhanceLowContrast = false
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        return settings
    }

    private static func parseGuardMode(_ value: String) -> GuardMode? {
        switch value.lowercased() {
        case "lockdown":
            return .lockdown
        case "standard":
            return .standard
        case "low-latency", "low_latency", "lowlatency":
            return .lowLatency
        default:
            return nil
        }
    }

    public static let helpText = """
    pii-stream — real-time PII detection on the main display

    Usage:
      pii-stream watch [options]
      pii-stream serve [options]
      pii-stream benchmark [options]
      pii-stream detect-image --image PATH [options] --json

    Watch options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --mode MODE     lockdown, standard, or low-latency (default: standard)
      --fps N         Override mode detection rate
      --accurate      Use accurate Vision OCR (slower)
      --min-text-height N
                     Override Vision minimum text height
      --max-pixel-size N
                     Override longest OCR side after downscale
      --enhance-low-contrast
                     Boost contrast/sharpness before OCR
      --position PLACEMENT
                     Preview window placement: center, left, or right
                     (default: center)
      --preview MODE Preview mode: window or overlay (default: window)
      --overlay      Alias for --preview overlay
      --remote HOST:PORT
                     Send captured frames to a remote processor
      --token TOKEN   Shared token for remote processing

    Serve options:
      --host HOST     Listen host (default: 127.0.0.1; use 0.0.0.0 for LAN)
      --port PORT     Listen port (default: 8765)
      --token TOKEN   Shared token; generated and printed when omitted

    Benchmark:
      Captures live frames once, then measures detection latency across a
      fixed matrix: 720p (1280x720) and 1080p (1920x1080), each reported
      against 10, 30, and 60 fps budgets. Each row lists min, p95, average
      frame time, required render delay, budget slack, and budget fit.

    Benchmark options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --duration N    Capture duration in seconds (default: 5)
      --output PATH   Write JSON summary to PATH instead of stdout
      --csv PATH      Write CSV summary to PATH

    Detect image options:
      --image PATH    Image to scan
      --needle TEXT   Additional PII needle to match (repeatable)
      --json          Emit detector JSON for benchmark adapters
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --mode MODE     lockdown, standard, or low-latency (default: standard)
      --accurate      Use accurate Vision OCR (slower)
      --min-text-height N
                     Override Vision minimum text height
      --max-pixel-size N
                     Override longest OCR side after downscale
      --enhance-low-contrast
                     Boost contrast/sharpness before OCR

    General:
      -h, --help      Show this help
    """
}

public enum Command {
    case watch(WatchOptions)
    case serve(ServeOptions)
    case benchmark(BenchmarkOptions)
    case detectImage(DetectImageOptions)
}

public enum CLIError: Error, LocalizedError {
    case usage
    case help
    case missingValue(String)
    case invalidValue(String)
    case unknownFlag(String)

    public var errorDescription: String? {
        switch self {
        case .usage:
            return "Invalid usage. Run `pii-stream --help`."
        case .help:
            return CLI.helpText
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .invalidValue(let flag):
            return "Invalid value for \(flag)."
        case .unknownFlag(let flag):
            return "Unknown flag: \(flag)."
        }
    }
}
