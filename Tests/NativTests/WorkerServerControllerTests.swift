import XCTest

private final class FakeWorkerLauncher: WorkerServerLaunching {
    var isRunning = false
    var launches: [(arguments: [String], environment: [String: String])] = []
    var stops = 0
    var failuresRemaining = 0
    var exitsImmediately = false
    var recentOutput = ""

    func launch(arguments: [String], environment: [String: String]) throws {
        launches.append((arguments, environment))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        isRunning = !exitsImmediately
    }

    func stopServer() {
        stops += 1
        isRunning = false
    }
}

@MainActor
final class WorkerServerControllerTests: XCTestCase {
    private var launcher: FakeWorkerLauncher!

    override func setUp() {
        super.setUp()
        launcher = FakeWorkerLauncher()
    }

    private var probes = 0

    private func controller(busyPorts: Set<Int> = [], ready: Bool = true) -> WorkerServerController {
        WorkerServerController(
            launcher: launcher,
            isPortFree: { _, port in !busyPorts.contains(port) },
            probe: { [unowned self] _ in
                self.probes += 1
                return ready
            },
            pollInterval: .milliseconds(1),
            maxAttempts: 5
        )
    }

    private var enabled: NativSettings {
        var settings = NativSettings()
        settings.workerSubagentsEnabled = true
        return settings
    }

    func testArgumentsAreTextOnlyWithWorkerKVCap() {
        let settings = NativSettings(languageModelID: "org/manager", imageGenerationModelID: "org/image")
        XCTAssertEqual(
            WorkerServerLaunchPlan.arguments(settings: settings, port: 8081),
            ["--host", "127.0.0.1", "--port", "8081", "--max-tokens", "\(settings.normalized().maxTokens)",
             "--max-kv-size", "8192"])
    }

    func testEnvironmentCarriesLimitsAndSeparateAnalyticsDB() {
        let environment = WorkerServerLaunchPlan.environment(
            base: ["HF_HUB_CACHE": "/cache", "MLX_PLATFORM_ANALYTICS_DB_PATH": "/main.sqlite",
                   "MLX_VLM_SERVER_API_KEY": "secret"],
            analyticsDatabasePath: "/worker-analytics.sqlite",
            memoryLimitBytes: 4_000_000_000,
            cacheLimitBytes: 268_435_456,
            parentPID: 4242)
        XCTAssertNil(environment["MLX_VLM_SERVER_API_KEY"])
        XCTAssertEqual(environment["NATIV_PARENT_PID"], "4242")
        XCTAssertEqual(environment["HF_HUB_CACHE"], "/cache")
        XCTAssertEqual(environment["MLX_PLATFORM_ANALYTICS_DB_PATH"], "/worker-analytics.sqlite")
        XCTAssertEqual(environment["NATIV_MLX_MEMORY_LIMIT_BYTES"], "4000000000")
        XCTAssertEqual(environment["NATIV_MLX_CACHE_LIMIT_BYTES"], "268435456")
    }

    func testEnsureRunningStartsOnceAndReturnsURL() async throws {
        let controller = controller()
        let first = try await controller.ensureRunning(settings: enabled, environment: [:])
        let second = try await controller.ensureRunning(settings: enabled, environment: [:])
        XCTAssertEqual(first.absoluteString, "http://127.0.0.1:8081")
        XCTAssertEqual(second, first)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(controller.state, .running(port: 8081))
    }

    func testSkipsBusyPort() async throws {
        let url = try await controller(busyPorts: [8081]).ensureRunning(settings: enabled, environment: [:])
        XCTAssertEqual(url.port, 8082)
    }

    func testLaunchFailureThrowsAndNextCallRetries() async throws {
        launcher.failuresRemaining = 1
        let controller = controller()
        do {
            _ = try await controller.ensureRunning(settings: enabled, environment: [:])
            XCTFail("expected the first launch to fail")
        } catch {}
        guard case .failed = controller.state else { return XCTFail("state should be failed") }
        _ = try await controller.ensureRunning(settings: enabled, environment: [:])
        XCTAssertEqual(launcher.launches.count, 2)
        XCTAssertEqual(controller.state, .running(port: 8081))
    }

    func testNotReadyStopsTheProcessAndThrows() async {
        let controller = controller(ready: false)
        do {
            _ = try await controller.ensureRunning(settings: enabled, environment: [:])
            XCTFail("expected readiness failure")
        } catch {}
        XCTAssertFalse(launcher.isRunning)
    }

    func testExitDuringStartupFailsFastWithOutput() async {
        launcher.exitsImmediately = true
        launcher.recentOutput = "ImportError: boom"
        let controller = controller(ready: false)
        do {
            _ = try await controller.ensureRunning(settings: enabled, environment: [:])
            XCTFail("expected a startup failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ImportError: boom"), error.localizedDescription)
        }
        XCTAssertLessThanOrEqual(probes, 1)
    }

    func testRestartsWhenTheProcessDied() async throws {
        let controller = controller()
        _ = try await controller.ensureRunning(settings: enabled, environment: [:])
        launcher.isRunning = false
        _ = try await controller.ensureRunning(settings: enabled, environment: [:])
        XCTAssertEqual(launcher.launches.count, 2)
    }

    func testApplyDisabledStops() async throws {
        let controller = controller()
        _ = try await controller.ensureRunning(settings: enabled, environment: [:])
        controller.apply(settings: NativSettings())
        XCTAssertFalse(launcher.isRunning)
        XCTAssertEqual(controller.state, .stopped)
    }

    func testApplyCapChangeStops() async throws {
        let controller = controller()
        _ = try await controller.ensureRunning(settings: enabled, environment: [:])
        var changed = enabled
        changed.workerContextTokens = 16_384
        controller.apply(settings: changed)
        XCTAssertFalse(launcher.isRunning)
        controller.apply(settings: enabled)
        XCTAssertEqual(launcher.stops, 1)
    }
}
