import AppKit
import Foundation

do {
    let command = try CLI.parse(CommandLine.arguments)
    switch command {
    case .watch(let options):
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let coordinator = AppCoordinator(options: options)
        app.delegate = coordinator
        app.run()
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
    }
} catch CLIError.help {
    print(CLI.helpText)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
