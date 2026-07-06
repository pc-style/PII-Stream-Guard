import AppKit
import Foundation
import pii_stream

do {
    let command = try CLI.parse(CommandLine.arguments)
    switch command {
    case .watch(let options):
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let coordinator = AppCoordinator(options: options)
        app.delegate = coordinator
        app.run()
    case .targets(let options):
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                let targets = try await CaptureTargetCatalog.list()
                if options.json {
                    let payload = targets.map { target in
                        [
                            "kind": target.kind,
                            "id": target.id,
                            "name": target.name,
                            "width": target.width,
                            "height": target.height,
                        ] as [String: Any]
                    }
                    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                    print(String(data: data, encoding: .utf8) ?? "[]")
                } else {
                    for target in targets {
                        print("\(target.kind)\t\(target.id)\t\(target.width)×\(target.height)\t\(target.name)")
                    }
                }
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 {
            exit(exitCode)
        }
    case .serve(let options):
        let server = ProcessingServer(options: options)
        try server.start()
    case .benchmark(let options):
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0
        Task {
            do {
                let runner = BenchmarkRunner(options: options)
                let summary = try await runner.run()
                try runner.write(summary)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }
        semaphore.wait()
        if exitCode != 0 {
            exit(exitCode)
        }
    case .detectImage(let options):
        let runner = ImageDetectionRunner(options: options)
        try runner.run()
    }
} catch CLIError.help {
    print(CLI.helpText)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
