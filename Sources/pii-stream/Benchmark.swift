import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct DetectorSettings: Codable, Equatable {
    var accurate: Bool = false
    var maxPixelSize: CGFloat = 1440
    var minimumTextHeight: Float = 0.012
    var enhanceLowContrast: Bool = false
}

struct BenchmarkOptions {
    var needles: [String] = []
    var checkEmail: Bool = true
    var checkPhone: Bool = true
    var duration: Double = 5
    var outputPath: String?
    var csvPath: String?
}

struct BenchmarkSummary: Codable {
    let capturedFrames: Int
    let sampledFrames: Int
    let duration: Double
    let results: [BenchmarkResult]
}

struct BenchmarkResult: Codable {
    let resolution: String
    let width: Int
    let height: Int
    let targetFps: Double
    let frameBudgetMS: Double
    let frames: Int
    let latencyMinMS: Double
    let latencyP95MS: Double
    let latencyAverageMS: Double
    let requiredRenderDelayMS: Double
    let budgetSlackMS: Double
    let meetsBudget: Bool
    let hitCount: Int
    let matchedKinds: [String]
}

final class BenchmarkRunner {
    private struct ResolutionCase {
        let width: Int
        let height: Int

        var label: String {
            "\(width)x\(height)"
        }
    }

    private struct ResolutionMetrics {
        let resolution: ResolutionCase
        let frames: Int
        let latencyMinMS: Double
        let latencyP95MS: Double
        let latencyAverageMS: Double
        let hitCount: Int
        let matchedKinds: [String]
    }

    private let options: BenchmarkOptions
    private let frameStore = FrameStore()
    private var capturedFrames = 0

    private let resolutions: [ResolutionCase] = [
        ResolutionCase(width: 1280, height: 720),
        ResolutionCase(width: 1920, height: 1080),
    ]

    private let targetFpsValues: [Double] = [10, 30, 60]
    private let detectorSettings = DetectorSettings()

    init(options: BenchmarkOptions) {
        self.options = options
    }

    func run() async throws -> BenchmarkSummary {
        let capture = ScreenCaptureManager(frameStore: frameStore) { [weak self] _ in
            self?.capturedFrames += 1
        }

        try await capture.start()
        defer { Task { await capture.stop() } }

        try await waitForFirstFrame()
        let frames = await sampleFrames()
        let metrics = try resolutions.map { try benchmark(resolution: $0, frames: frames) }
        let results = metrics.flatMap { metrics in
            targetFpsValues.map { targetFps in
                toResult(metrics: metrics, targetFps: targetFps)
            }
        }

        return BenchmarkSummary(
            capturedFrames: capturedFrames,
            sampledFrames: frames.count,
            duration: options.duration,
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
        var lastCapturedAt: TimeInterval = 0
        var frames: [CVPixelBuffer] = []

        while ProcessInfo.processInfo.systemUptime < end {
            let current = frameStore.current()
            if let buffer = current.buffer, current.capturedAt != lastCapturedAt {
                frames.append(buffer)
                lastCapturedAt = current.capturedAt
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        return frames
    }

    private func benchmark(resolution: ResolutionCase, frames: [CVPixelBuffer]) throws -> ResolutionMetrics {
        let detector = VisionPIIDetector(
            needles: options.needles,
            checkEmail: options.checkEmail,
            checkPhone: options.checkPhone,
            accurate: detectorSettings.accurate,
            maxPixelSize: detectorSettings.maxPixelSize,
            minimumTextHeight: detectorSettings.minimumTextHeight,
            enhanceLowContrast: detectorSettings.enhanceLowContrast
        )

        var latencies: [Double] = []
        var hitCount = 0
        var matchedKinds = Set<String>()

        for frame in frames {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let resized = PixelBufferUtils.resized(frame, width: resolution.width, height: resolution.height) else {
                continue
            }
            let boxes = detector.detect(in: resized)
            let end = DispatchTime.now().uptimeNanoseconds

            latencies.append(Double(end - start) / 1_000_000)
            hitCount += boxes.count
            for box in boxes {
                matchedKinds.insert(box.kind.rawValue)
            }
        }

        guard !latencies.isEmpty else {
            throw BenchmarkError.noFrames
        }

        return ResolutionMetrics(
            resolution: resolution,
            frames: latencies.count,
            latencyMinMS: latencies.min() ?? 0,
            latencyP95MS: percentile(latencies, 0.95) ?? 0,
            latencyAverageMS: average(latencies) ?? 0,
            hitCount: hitCount,
            matchedKinds: matchedKinds.sorted()
        )
    }

    private func toResult(metrics: ResolutionMetrics, targetFps: Double) -> BenchmarkResult {
        let frameBudgetMS = 1000.0 / targetFps
        let budgetSlackMS = frameBudgetMS - metrics.latencyP95MS

        return BenchmarkResult(
            resolution: metrics.resolution.label,
            width: metrics.resolution.width,
            height: metrics.resolution.height,
            targetFps: targetFps,
            frameBudgetMS: frameBudgetMS,
            frames: metrics.frames,
            latencyMinMS: metrics.latencyMinMS,
            latencyP95MS: metrics.latencyP95MS,
            latencyAverageMS: metrics.latencyAverageMS,
            requiredRenderDelayMS: metrics.latencyP95MS,
            budgetSlackMS: budgetSlackMS,
            meetsBudget: budgetSlackMS >= 0,
            hitCount: metrics.hitCount,
            matchedKinds: metrics.matchedKinds
        )
    }

    private func csv(_ summary: BenchmarkSummary) -> String {
        var lines = [
            "resolution,width,height,targetFps,frameBudgetMS,frames,latencyMinMS,latencyP95MS,latencyAverageMS,requiredRenderDelayMS,budgetSlackMS,meetsBudget,hitCount,matchedKinds"
        ]

        for result in summary.results {
            lines.append([
                csvEscape(result.resolution),
                String(result.width),
                String(result.height),
                String(format: "%.0f", result.targetFps),
                formatNumber(result.frameBudgetMS),
                String(result.frames),
                formatNumber(result.latencyMinMS),
                formatNumber(result.latencyP95MS),
                formatNumber(result.latencyAverageMS),
                formatNumber(result.requiredRenderDelayMS),
                formatNumber(result.budgetSlackMS),
                result.meetsBudget ? "true" : "false",
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

private func formatNumber(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func csvEscape(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}
