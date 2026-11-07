import Foundation
import NativServerKit

struct ChatWorkerRouting: Sendable {
    let workerContextTokens: Int
    let environment: @Sendable () async -> WorkerPickEnvironment
    let ensureEndpoint: @MainActor @Sendable () async throws -> URL
}

protocol WorkerServerLaunching: AnyObject {
    var isRunning: Bool { get }
    var recentOutput: String { get }
    func launch(arguments: [String], environment: [String: String]) throws
    func stopServer()
}

final class NativProcessWorkerLauncher: WorkerServerLaunching, @unchecked Sendable {
    private static let maximumLines = 20
    private let controller = NativProcessController()
    private let lock = NSLock()
    private var lines: [String] = []

    init() {
        controller.onOutput = { [weak self] text in self?.record(text) }
    }

    var isRunning: Bool { controller.isRunning }

    var recentOutput: String {
        lock.withLock { lines.joined(separator: "\n") }
    }

    func launch(arguments: [String], environment: [String: String]) throws {
        lock.withLock { lines.removeAll() }
        try controller.start(arguments: arguments, environment: environment)
    }

    func stopServer() {
        try? controller.stop(timeout: 2)
    }

    private func record(_ text: String) {
        let newLines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        lock.withLock {
            lines.append(contentsOf: newLines)
            if lines.count > Self.maximumLines { lines.removeFirst(lines.count - Self.maximumLines) }
        }
    }
}

enum WorkerServerLaunchPlan {
    static let host = "127.0.0.1"

    static func arguments(settings: NativSettings, port: Int) -> [String] {
        let settings = settings.normalized()
        return [
            "--host", host,
            "--port", "\(port)",
            "--max-tokens", "\(settings.maxTokens)",
            "--max-kv-size", "\(settings.workerContextTokens)",
        ]
    }

    static func environment(
        base: [String: String],
        analyticsDatabasePath: String,
        memoryLimitBytes: Int64,
        cacheLimitBytes: Int64,
        parentPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [String: String] {
        var environment = base
        // Loopback only, and its /health check would need the key; requests still send it harmlessly.
        environment.removeValue(forKey: "MLX_VLM_SERVER_API_KEY")
        // The overlay exits the worker if Nativ dies, so it can't linger holding memory.
        environment["NATIV_PARENT_PID"] = "\(parentPID)"
        environment["MLX_PLATFORM_ANALYTICS_DB_PATH"] = analyticsDatabasePath
        environment["NATIV_MLX_MEMORY_LIMIT_BYTES"] = "\(memoryLimitBytes)"
        environment["NATIV_MLX_CACHE_LIMIT_BYTES"] = "\(cacheLimitBytes)"
        return environment
    }
}

enum WorkerServerError: LocalizedError {
    case noFreePort
    case notReady
    case exitedDuringStartup(output: String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .noFreePort:
            "The worker server couldn't start: ports 8081 to 8090 are all in use."
        case .notReady:
            "The worker server started but didn't become ready in time."
        case .exitedDuringStartup(let output):
            output.isEmpty
                ? "The worker server exited while starting."
                : "The worker server exited while starting. Last output:\n\(output)"
        case .unavailable:
            "The worker server is unavailable."
        }
    }
}

@MainActor
@Observable
final class WorkerServerController {
    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    static let preferredPorts = 8081...8090
    static let cacheLimitBytes: Int64 = 268_435_456

    private(set) var state: State = .stopped
    @ObservationIgnored private var appliedContextTokens: Int?
    @ObservationIgnored private var startTask: Task<URL, Error>?
    @ObservationIgnored private let launcher: WorkerServerLaunching
    @ObservationIgnored private let isPortFree: (String, Int) -> Bool
    @ObservationIgnored private let probe: (URL) async -> Bool
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let maxAttempts: Int

    init(
        launcher: WorkerServerLaunching = NativProcessWorkerLauncher(),
        isPortFree: @escaping (String, Int) -> Bool = { host, port in
            ServerPortProbe.availability(host: host, port: port) != .addressInUse
        },
        probe: @escaping (URL) async -> Bool = WorkerServerController.isHealthy,
        pollInterval: Duration = .milliseconds(250),
        maxAttempts: Int = 240
    ) {
        self.launcher = launcher
        self.isPortFree = isPortFree
        self.probe = probe
        self.pollInterval = pollInterval
        self.maxAttempts = maxAttempts
    }

    var runningPort: Int? {
        if case .running(let port) = state, launcher.isRunning { return port }
        return nil
    }

    func ensureRunning(settings: NativSettings, environment: [String: String]) async throws -> URL {
        if let port = runningPort {
            return Self.url(port: port)
        }
        if let startTask {
            return try await startTask.value
        }
        let task = Task { try await self.start(settings: settings, environment: environment) }
        startTask = task
        defer { startTask = nil }
        return try await task.value
    }

    func apply(settings: NativSettings) {
        guard launcher.isRunning || state != .stopped else { return }
        let contextTokens = settings.normalized().workerContextTokens
        if !settings.workerSubagentsEnabled
            || (appliedContextTokens != nil && appliedContextTokens != contextTokens)
        {
            stop()
        }
    }

    func stop() {
        if launcher.isRunning {
            launcher.stopServer()
        }
        state = .stopped
        appliedContextTokens = nil
    }

    private func start(settings: NativSettings, environment: [String: String]) async throws -> URL {
        state = .starting
        if launcher.isRunning {
            launcher.stopServer()
        }
        guard let port = Self.preferredPorts.first(where: { isPortFree(WorkerServerLaunchPlan.host, $0) }) else {
            state = .failed(WorkerServerError.noFreePort.localizedDescription)
            throw WorkerServerError.noFreePort
        }
        do {
            try launcher.launch(
                arguments: WorkerServerLaunchPlan.arguments(settings: settings, port: port),
                environment: environment
            )
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
        let url = Self.url(port: port)
        do {
            try await waitUntilReady(url)
        } catch {
            launcher.stopServer()
            state = .failed(error.localizedDescription)
            throw error
        }
        state = .running(port: port)
        appliedContextTokens = settings.normalized().workerContextTokens
        return url
    }

    private static func url(port: Int) -> URL {
        URL(string: "http://\(WorkerServerLaunchPlan.host):\(port)")!
    }

    private func waitUntilReady(_ url: URL) async throws {
        for _ in 0..<maxAttempts {
            try Task.checkCancellation()
            guard launcher.isRunning else {
                throw WorkerServerError.exitedDuringStartup(output: launcher.recentOutput)
            }
            if await probe(url) { return }
            try await Task.sleep(for: pollInterval)
        }
        throw WorkerServerError.notReady
    }

    nonisolated static func isHealthy(_ baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
