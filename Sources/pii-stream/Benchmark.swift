import CoreGraphics
import CoreVideo
import Foundation

struct DetectorSettings: Codable {
    var accurate: Bool = false
    var maxPixelSize: CGFloat = 1440
    var minimumTextHeight: Float = 0.012
    var enhanceLowContrast: Bool = false
}

struct BenchmarkOptions {
    var needles: [String] = []
    var checkEmail: Bool = true
    var fps: Double = 8
    var duration: Double = 5
    var settings: [DetectorSettings] = [
        DetectorSettings(accurate: false, maxPixelSize: 1440, minimumTextHeight: 0.012, enhanceLowContrast: false),
        DetectorSettings(accurate: false, maxPixelSize: 1920, minimumTextHeight: 0.006, enhanceLowContrast: true),
        DetectorSettings(accurate: true, maxPixelSize: 2560, minimumTextHeight: 0.004, enhanceLowContrast: true),
    ]
    var outputPath: String?
    var csvPath: String?
}

struct BenchmarkSummary: Codable {
    let capturedFrames: Int
    let sampledFrames: Int
    let duration: Double
    let fps: Double
    let results: [BenchmarkResult]
}

struct BenchmarkResult: Codable {
    let accurate: Bool
    let maxPixelSize: CGFloat
    let minimumTextHeight: Float
    let enhanceLowContrast: Bool
    let frames: Int
    let latencyP50MS: Double?
    let latencyP95MS: Double?
    let latencyAverageMS: Double?
    let hitCount: Int
    let matchedKinds: [String]
}

final class BenchmarkRunner {
    private let options: BenchmarkOptions
    private let frameStore = FrameStore()
    private var capturedFrames = 0

    init(options: BenchmarkOptions) {
        self.options = options
    }

    func run() async throws -> BenchmarkSummary {
        let capture = ScreenCaptureManager(frameStore: frameStore) { [weak self] _ in
            self?.capturedFrames += 1
        }
        try await capture.start()
        defer {
            Task {
                await capture.stop()
            }
        }

        try await waitForFirstFrame()
        let frames = await sampleFrames()
        let results = options.settings.map { benchmark(settings: $0, frames: frames) }
        return BenchmarkSummary(
            capturedFrames: capturedFrames,
            sampledFrames: frames.count,
            duration: options.duration,
            fps: options.fps,
            results: results
        )
    }

    func write(_ summary: BenchmarkSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)

        if let outputPath = options.outputPath {
            try data.write(to: URL(fileURLWithPath: outputPath))
        } else if let json = String(data: data, encoding: .utf8) {
            print(json)
        }

        if let csvPath = options.csvPath {
            try csv(summary).write(toFile: csvPath, atomically: true, encoding: .utf8)
        }
    }

    private func waitForFirstFrame() async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if frameStore.current().buffer != nil {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw BenchmarkError.noFrames
    }

    private func sampleFrames() async -> [CVPixelBuffer] {
        let end = ProcessInfo.processInfo.systemUptime + options.duration
        let interval = 1.0 / options.fps
        var nextSampleAt = ProcessInfo.processInfo.systemUptime
        var lastCapturedAt: TimeInterval = 0
        var frames: [CVPixelBuffer] = []

        while ProcessInfo.processInfo.systemUptime < end {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextSampleAt {
                let current = frameStore.current()
                if let buffer = current.buffer, current.capturedAt != lastCapturedAt {
                    frames.append(buffer)
                    lastCapturedAt = current.capturedAt
                }
                nextSampleAt = now + interval
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        return frames
    }

    private func benchmark(settings: DetectorSettings, frames: [CVPixelBuffer]) -> BenchmarkResult {
        let detector = VisionPIIDetector(
            needles: options.needles,
            checkEmail: options.checkEmail,
            accurate: settings.accurate,
            maxPixelSize: settings.maxPixelSize,
            minimumTextHeight: settings.minimumTextHeight,
            enhanceLowContrast: settings.enhanceLowContrast
        )

        var latencies: [Double] = []
        var hitCount = 0
        var matchedKinds = Set<String>()

        for frame in frames {
            let start = DispatchTime.now().uptimeNanoseconds
            let boxes = detector.detect(in: frame)
            let end = DispatchTime.now().uptimeNanoseconds
            latencies.append(Double(end - start) / 1_000_000)
            hitCount += boxes.count
            for box in boxes {
                matchedKinds.insert(box.kind.rawValue)
            }
        }

        return BenchmarkResult(
            accurate: settings.accurate,
            maxPixelSize: settings.maxPixelSize,
            minimumTextHeight: settings.minimumTextHeight,
            enhanceLowContrast: settings.enhanceLowContrast,
            frames: frames.count,
            latencyP50MS: percentile(latencies, 0.50),
            latencyP95MS: percentile(latencies, 0.95),
            latencyAverageMS: average(latencies),
            hitCount: hitCount,
            matchedKinds: matchedKinds.sorted()
        )
    }

    private func csv(_ summary: BenchmarkSummary) -> String {
        var lines = ["accurate,maxPixelSize,minimumTextHeight,enhanceLowContrast,frames,latencyP50MS,latencyP95MS,latencyAverageMS,hitCount,matchedKinds"]
        for result in summary.results {
            lines.append([
                result.accurate ? "true" : "false",
                String(format: "%.0f", result.maxPixelSize),
                String(result.minimumTextHeight),
                result.enhanceLowContrast ? "true" : "false",
                String(result.frames),
                formatNumber(result.latencyP50MS),
                formatNumber(result.latencyP95MS),
                formatNumber(result.latencyAverageMS),
                String(result.hitCount),
                csvEscape(result.matchedKinds.joined(separator: "|")),
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum BenchmarkError: Error, LocalizedError {
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noFrames:
            return "No screen frames captured within 10 seconds. Check Screen Recording permission."
        }
    }
}

private func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[max(0, min(sorted.count - 1, index))]
}

private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}

private func formatNumber(_ value: Double?) -> String {
    guard let value else { return "" }
    return String(format: "%.3f", value)
}

private func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}
