import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

public struct BenchmarkOptions {
    public var needles: [String]
    public var checkEmail: Bool
    public var checkPhone: Bool
    public var duration: Double
    public var outputPath: String?
    public var csvPath: String?

    public init(
        needles: [String] = [],
        checkEmail: Bool = true,
        checkPhone: Bool = true,
        duration: Double = 5,
        outputPath: String? = nil,
        csvPath: String? = nil
    ) {
        self.needles = needles
        self.checkEmail = checkEmail
        self.checkPhone = checkPhone
        self.duration = duration
        self.outputPath = outputPath
        self.csvPath = csvPath
    }
}

public struct BenchmarkSummary: Codable {
    public let capturedFrames: Int
    public let sampledFrames: Int
    public let duration: Double
    public let results: [BenchmarkResult]

    public init(
        capturedFrames: Int,
        sampledFrames: Int,
        duration: Double,
        results: [BenchmarkResult]
    ) {
        self.capturedFrames = capturedFrames
        self.sampledFrames = sampledFrames
        self.duration = duration
        self.results = results
    }
}

public struct BenchmarkResult: Codable {
    public let resolution: String
    public let width: Int
    public let height: Int
    public let targetFps: Double
    public let frameBudgetMS: Double
    public let frames: Int
    public let latencyMinMS: Double
    public let latencyP95MS: Double
    public let latencyAverageMS: Double
    public let requiredRenderDelayMS: Double
    public let budgetSlackMS: Double
    public let meetsBudget: Bool
    public let hitCount: Int
    public let matchedKinds: [String]

    public init(
        resolution: String,
        width: Int,
        height: Int,
        targetFps: Double,
        frameBudgetMS: Double,
        frames: Int,
        latencyMinMS: Double,
        latencyP95MS: Double,
        latencyAverageMS: Double,
        requiredRenderDelayMS: Double,
        budgetSlackMS: Double,
        meetsBudget: Bool,
        hitCount: Int,
        matchedKinds: [String]
    ) {
        self.resolution = resolution
        self.width = width
        self.height = height
        self.targetFps = targetFps
        self.frameBudgetMS = frameBudgetMS
        self.frames = frames
        self.latencyMinMS = latencyMinMS
        self.latencyP95MS = latencyP95MS
        self.latencyAverageMS = latencyAverageMS
        self.requiredRenderDelayMS = requiredRenderDelayMS
        self.budgetSlackMS = budgetSlackMS
        self.meetsBudget = meetsBudget
        self.hitCount = hitCount
        self.matchedKinds = matchedKinds
    }
}

public final class BenchmarkRunner {
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

    public init(options: BenchmarkOptions) {
        self.options = options
    }

    public func run() async throws -> BenchmarkSummary {
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

    public func write(_ summary: BenchmarkSummary) throws {
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
        let detector = DetectionRecipe.benchmark(options, settings: detectorSettings).makeDetector()

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

public enum BenchmarkError: Error, LocalizedError {
    case noFrames

    public var errorDescription: String? {
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
