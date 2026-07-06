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
    /// nil disables the preview entirely (headless protected recording).
    var previewPresentation: PreviewPresentation? = .window
    var capture = CaptureOptions()
    /// Non-nil starts a protected recording on launch.
    var recording: RecordingOptions?
    var maskMode: MaskMode = .boundingBox
    var accessibilityEnabled: Bool = true
    var accessibilityFPS: Double = 5
    var jsonEvents: Bool = false
    var shareablePreview: Bool = true

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

public struct TargetsOptions {
    public var json: Bool = false
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
        case "targets":
            return .targets(try parseTargetsOptions(Array(args.dropFirst(2))))
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
                guard i < args.count else { throw CLIError.missingValue("--preview") }
                if args[i] == "none" {
                    options.previewPresentation = nil
                } else if let presentation = PreviewPresentation(rawValue: args[i]) {
                    options.previewPresentation = presentation
                } else {
                    throw CLIError.invalidValue("--preview")
                }
            case "--overlay":
                options.previewPresentation = .screenOverlay
            case "--private-window":
                options.shareablePreview = false
            case "--display":
                i += 1
                guard i < args.count, let id = UInt32(args[i]) else {
                    throw CLIError.invalidValue("--display")
                }
                options.capture.target = .display(id)
            case "--window":
                i += 1
                guard i < args.count, let id = UInt32(args[i]) else {
                    throw CLIError.invalidValue("--window")
                }
                options.capture.target = .window(id)
            case "--capture-fps":
                i += 1
                guard i < args.count, let fps = Int(args[i]), fps > 0, fps <= 120 else {
                    throw CLIError.invalidValue("--capture-fps")
                }
                options.capture.captureFPS = fps
            case "--resolution":
                i += 1
                guard i < args.count, let resolution = CaptureResolution(rawValue: args[i]) else {
                    throw CLIError.invalidValue("--resolution")
                }
                options.capture.resolution = resolution
            case "--no-cursor":
                options.capture.showsCursor = false
            case "--audio":
                options.capture.capturesAudio = true
                options.recording = options.recording ?? RecordingOptions()
                options.recording?.includeAudio = true
            case "--no-hide-self":
                options.capture.hideOwnApp = false
            case "--record":
                options.recording = options.recording ?? RecordingOptions()
            case "--output":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--output") }
                options.recording = options.recording ?? RecordingOptions()
                options.recording?.outputPath = args[i]
            case "--codec":
                i += 1
                guard i < args.count, let codec = RecordingCodec(rawValue: args[i]) else {
                    throw CLIError.invalidValue("--codec")
                }
                options.recording = options.recording ?? RecordingOptions()
                options.recording?.codec = codec
            case "--quality":
                i += 1
                guard i < args.count, let quality = RecordingQuality(rawValue: args[i]) else {
                    throw CLIError.invalidValue("--quality")
                }
                options.recording = options.recording ?? RecordingOptions()
                options.recording?.quality = quality
            case "--record-fps":
                i += 1
                guard i < args.count, let fps = Int(args[i]), fps > 0, fps <= 60 else {
                    throw CLIError.invalidValue("--record-fps")
                }
                options.recording = options.recording ?? RecordingOptions()
                options.recording?.fps = fps
            case "--duration":
                i += 1
                guard i < args.count, let duration = Double(args[i]), duration > 0 else {
                    throw CLIError.invalidValue("--duration")
                }
                options.recording = options.recording ?? RecordingOptions()
                options.recording?.duration = duration
            case "--mask":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--mask") }
                switch args[i] {
                case "boxes", "boundingBox":
                    options.maskMode = .boundingBox
                case "blackout":
                    options.maskMode = .blackout
                default:
                    throw CLIError.invalidValue("--mask")
                }
            case "--no-ax":
                options.accessibilityEnabled = false
            case "--ax-fps":
                i += 1
                guard i < args.count, let fps = Double(args[i]), fps > 0, fps <= 30 else {
                    throw CLIError.invalidValue("--ax-fps")
                }
                options.accessibilityFPS = fps
            case "--json-events":
                options.jsonEvents = true
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
        if options.previewPresentation == nil, options.recording == nil {
            throw CLIError.invalidValue("--preview none requires --record (nothing to output otherwise)")
        }
        return options
    }

    private static func parseTargetsOptions(_ args: [String]) throws -> TargetsOptions {
        var options = TargetsOptions()
        for arg in args {
            switch arg {
            case "--json":
                options.json = true
            default:
                throw CLIError.unknownFlag(arg)
            }
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
        var outputPath: String?
        var needles: [String] = []
        var checkEmail = true
        var checkPhone = true
        var mode: GuardMode = .standard
        var attribution: ImageAttributionStyle = .badge
        var presentation: ImageOutputPresentation = .standard
        var detectorOverrides = DetectorOverrideFlags()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--image":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--image") }
                imagePath = args[i]
            case "--output":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--output") }
                outputPath = args[i]
            case "--needle":
                i += 1
                guard i < args.count else { throw CLIError.missingValue("--needle") }
                needles.append(args[i])
            case "--json":
                break
            case "--no-badge":
                if attribution == .watermark {
                    throw CLIError.invalidValue("--no-badge (incompatible with --watermark)")
                }
                attribution = .none
            case "--watermark":
                if attribution == .none {
                    throw CLIError.invalidValue("--watermark (incompatible with --no-badge)")
                }
                attribution = .watermark
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
            case "--demo":
                presentation = .demo
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
                : nil,
            outputPath: outputPath,
            attribution: attribution,
            presentation: presentation
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
    pii-stream — real-time protected screen capture, streaming, and recording

    Usage:
      pii-stream watch [options]
      pii-stream targets [--json]
      pii-stream serve [options]
      pii-stream benchmark [options]
      pii-stream detect-image --image PATH [options] --json

    Watch options:
      --needle TEXT   Additional PII needle to match (repeatable)
      --no-email      Disable email regex detection
      --no-phone      Disable phone number detection
      --mode MODE     lockdown, standard, or low-latency (default: standard)
      --fps N         Override mode OCR detection rate
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
      --preview MODE Preview mode: window, overlay, or none (default: window)
                     "none" requires --record
      --overlay      Alias for --preview overlay
      --private-window
                     Hide the protected window from other capture tools
                     (by default it is shareable so OBS/Discord/Zoom can
                     capture the protected output)
      --mask MODE     boxes or blackout (default: boxes)
      --remote HOST:PORT
                     Send captured frames to a remote processor
      --token TOKEN   Shared token for remote processing
      --json-events   Emit JSON lifecycle events on stdout

    Capture options (watch):
      --display ID    Capture a specific display (see `pii-stream targets`)
      --window ID     Capture a single window (see `pii-stream targets`)
      --capture-fps N Capture frame rate, 1-120 (default: 60)
      --resolution R  native, 720p, 1080p, 2k, or 4k cap (default: native)
      --no-cursor     Exclude the cursor from capture
      --audio         Capture system audio into the recording (implies --record)
      --no-hide-self  Do not exclude pii-stream's own windows from capture

    Recording options (watch):
      --record        Record protected output to a .mov (+ metadata .jsonl)
      --output PATH   Recording output path (implies --record)
      --codec C       h264 or hevc (default: hevc; implies --record)
      --quality Q     efficient, balanced, or high (default: balanced)
      --record-fps N  Recording frame rate, 1-60 (default: 30)
      --duration N    Stop recording after N seconds (implies --record)

    Detection sources (watch):
      --no-ax         Disable accessibility-tree text detection
      --ax-fps N      Accessibility scan rate (default: 5)
                     Accessibility detection requires the Accessibility
                     permission and is best-effort; Vision OCR always runs.

    Runtime control (watch):
      stdin accepts one command per line:
        pause | resume        pause/resume the active recording
        record start [PATH]   start a protected recording
        record stop           stop and finalize the recording
        mode MODE             switch guard mode
        mask boxes|blackout   switch mask rendering
        status                print a JSON status line
        stop                  finalize any recording and quit

    Targets options:
      --json          Emit targets as JSON

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
      --image PATH    Image to scan (required)
      --output PATH   Protected PNG path (default: <image>-protected.png)
      --needle TEXT   Additional PII needle to match (repeatable)
      --json          Emit detector JSON for benchmark adapters
      --no-badge      Omit the default corner badge on saved image
      --watermark     Use a diagonal watermark instead of the badge
      --demo          Shareable export: site-style frame + visible redaction bars
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

    detect-image always writes a protected PNG and prints JSON including
    savedImagePath. Badge attribution is on by default for detect-image only.

    General:
      -h, --help      Show this help
    """
}

public enum Command {
    case watch(WatchOptions)
    case targets(TargetsOptions)
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
