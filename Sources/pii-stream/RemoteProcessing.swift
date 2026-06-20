import CoreGraphics
import CoreVideo
import Foundation
import Network

private struct RemoteEnvelope: Codable {
    var token: String
    var config: FrameProcessingOptions?
    var frame: RemoteFrame?
}

private struct RemoteFrame: Codable {
    var id: UInt64
    var capturedAt: TimeInterval
    var width: Int
    var height: Int
    var imageBase64: String
}

private struct RemoteResponse: Codable {
    var frameID: UInt64
    var capturedAt: TimeInterval
    var processedAt: TimeInterval
    var guardMode: GuardMode
    var armed: Bool
    var blackoutWholeFrame: Bool
    var detections: [RemoteDetection]
    var imageBase64: String?
    var error: String?
}

private struct RemoteDetection: Codable {
    var kind: PIIKind
    var confidence: Float
    var matchedLength: Int
    var rect: RemoteRect
    var detectedAt: TimeInterval

    init(box: PIIBox) {
        kind = box.kind
        confidence = box.confidence
        matchedLength = box.matched.count
        rect = RemoteRect(box.normalizedRect)
        detectedAt = box.detectedAt
    }

    var box: PIIBox {
        PIIBox(
            kind: kind,
            matched: String(repeating: "*", count: matchedLength),
            confidence: confidence,
            normalizedRect: rect.cgRect,
            detectedAt: detectedAt
        )
    }
}

private struct RemoteRect: Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

final class ProcessingServer {
    private let options: ServeOptions
    private let token: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pii-stream.remote.server")

    init(options: ServeOptions) {
        self.options = options
        token = options.token ?? UUID().uuidString
    }

    func start() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(options.host), port: NWEndpoint.Port(rawValue: options.port)!)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        fputs("pii-stream serve listening on \(options.host):\(options.port)\n", stderr)
        fputs("remote token: \(token)\n", stderr)
        dispatchMain()
    }

    private func handle(connection: NWConnection) {
        let session = ProcessingServerSession(connection: connection, token: token)
        session.start(queue: queue)
    }
}

private final class ProcessingServerSession {
    private let connection: NWConnection
    private let token: String
    private var processor: FrameProcessor?

    init(connection: NWConnection, token: String) {
        self.connection = connection
        self.token = token
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.handle(data)
            }
            self.receive()
        }
    }

    private func handle(_ data: Data) {
        do {
            let envelope = try JSONDecoder().decode(RemoteEnvelope.self, from: data)
            guard envelope.token == token else {
                try send(RemoteResponse(
                    frameID: envelope.frame?.id ?? 0,
                    capturedAt: envelope.frame?.capturedAt ?? 0,
                    processedAt: ProcessInfo.processInfo.systemUptime,
                    guardMode: envelope.config?.mode ?? .standard,
                    armed: false,
                    blackoutWholeFrame: true,
                    detections: [],
                    imageBase64: nil,
                    error: "unauthorized"
                ))
                connection.cancel()
                return
            }
            if let config = envelope.config {
                if let processor {
                    processor.updateOptions(config)
                } else {
                    processor = FrameProcessor(options: config)
                }
            }
            guard let frame = envelope.frame else { return }
            let processor = processor ?? FrameProcessor(options: FrameProcessingOptions())
            self.processor = processor
            let imageData = Data(base64Encoded: frame.imageBase64) ?? Data()
            let buffer = try FrameCodec.pixelBuffer(from: imageData)
            let sample = FrameSample(
                id: frame.id,
                pixelBuffer: buffer,
                capturedAt: frame.capturedAt,
                frameSize: CGSize(width: frame.width, height: frame.height)
            )
            guard let processed = processor.process(sample: sample) else { return }
            let protectedData = try FrameCodec.protectedJPEGData(from: buffer, snapshot: processed.snapshot)
            try send(RemoteResponse(
                frameID: processed.snapshot.frameID,
                capturedAt: processed.snapshot.capturedAt,
                processedAt: processed.processedAt,
                guardMode: processed.snapshot.guardMode,
                armed: processed.snapshot.armed,
                blackoutWholeFrame: processed.snapshot.blackoutWholeFrame,
                detections: processed.snapshot.boxes.map(RemoteDetection.init(box:)),
                imageBase64: protectedData.base64EncodedString(),
                error: nil
            ))
        } catch {
            try? send(RemoteResponse(
                frameID: 0,
                capturedAt: 0,
                processedAt: ProcessInfo.processInfo.systemUptime,
                guardMode: .standard,
                armed: false,
                blackoutWholeFrame: true,
                detections: [],
                imageBase64: nil,
                error: error.localizedDescription
            ))
        }
    }

    private func send(_ response: RemoteResponse) throws {
        let data = try JSONEncoder().encode(response)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "processed-frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}

final class RemoteFrameClient {
    private let endpoint: NWEndpoint
    private let token: String
    private var config: FrameProcessingOptions
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "pii-stream.remote.client")
    private let configLock = NSLock()
    private let onResponse: (RemoteProcessedFrame) -> Void
    private let onDisconnect: () -> Void
    private var newestResponseID: UInt64 = 0

    init(
        hostPort: String,
        token: String,
        config: FrameProcessingOptions,
        onResponse: @escaping (RemoteProcessedFrame) -> Void,
        onDisconnect: @escaping () -> Void
    ) throws {
        let pieces = hostPort.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let port = NWEndpoint.Port(pieces[1]) else {
            throw RemoteProcessingError.invalidRemote(hostPort)
        }
        endpoint = .hostPort(host: NWEndpoint.Host(pieces[0]), port: port)
        self.token = token
        self.config = config
        self.onResponse = onResponse
        self.onDisconnect = onDisconnect
    }

    func start() {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.onDisconnect()
            } else if case .cancelled = state {
                self?.onDisconnect()
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive()
        send(config: config, sample: nil)
    }

    func updateConfig(_ config: FrameProcessingOptions) {
        configLock.lock()
        self.config = config
        configLock.unlock()
        send(config: config, sample: nil)
    }

    func send(sample: FrameSample) {
        configLock.lock()
        let currentConfig = config
        configLock.unlock()
        send(config: currentConfig, sample: sample)
    }

    private func send(config: FrameProcessingOptions, sample: FrameSample?) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            do {
                let frame: RemoteFrame?
                if let sample {
                    let imageData = try FrameCodec.jpegData(from: sample.pixelBuffer)
                    frame = RemoteFrame(
                        id: sample.id,
                        capturedAt: sample.capturedAt,
                        width: Int(sample.frameSize.width),
                        height: Int(sample.frameSize.height),
                        imageBase64: imageData.base64EncodedString()
                    )
                } else {
                    frame = nil
                }
                let envelope = RemoteEnvelope(token: self.token, config: config, frame: frame)
                let data = try JSONEncoder().encode(envelope)
                let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
                connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { error in
                    if error != nil {
                        self.onDisconnect()
                    }
                })
            } catch {
                self.onDisconnect()
            }
        }
    }

    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if error != nil {
                self.onDisconnect()
                return
            }
            if let data,
               let response = try? JSONDecoder().decode(RemoteResponse.self, from: data),
               response.error == nil,
               response.frameID > self.newestResponseID,
               let encoded = response.imageBase64,
               let imageData = Data(base64Encoded: encoded),
               let buffer = try? FrameCodec.pixelBuffer(from: imageData) {
                self.newestResponseID = response.frameID
                let snapshot = DetectionSnapshot(
                    frameID: response.frameID,
                    boxes: response.detections.map(\.box),
                    frameSize: CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)),
                    capturedAt: response.capturedAt,
                    guardMode: response.guardMode,
                    armed: response.armed,
                    blackoutWholeFrame: response.blackoutWholeFrame
                )
                self.onResponse(RemoteProcessedFrame(buffer: buffer, snapshot: snapshot))
            } else if let data,
                      let response = try? JSONDecoder().decode(RemoteResponse.self, from: data),
                      response.error != nil {
                self.onDisconnect()
            }
            self.receive()
        }
    }
}

struct RemoteProcessedFrame {
    let buffer: CVPixelBuffer
    let snapshot: DetectionSnapshot
}

enum RemoteProcessingError: Error, LocalizedError {
    case invalidRemote(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemote(let value):
            return "Invalid remote address \(value). Use HOST:PORT."
        }
    }
}
