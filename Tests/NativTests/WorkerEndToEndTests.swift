import XCTest
@testable import NativServerKit

@MainActor
final class WorkerEndToEndTests: XCTestCase {
    func testCodingSpawnRunsOnTheWorkerServer() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NATIV_WORKER_E2E"] == "1",
            "Set NATIV_WORKER_E2E=1 with mlx-community/Qwen3-0.6B-4bit and Qwen3-1.7B-4bit downloaded.")

        var settings = NativSettings(languageModelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit")
        settings.workerSubagentsEnabled = true
        let workers: Set<String> = ["mlx-community/Qwen3-0.6B-4bit", "mlx-community/Qwen3-1.7B-4bit"]
        let controller = WorkerServerController()
        defer { controller.stop() }
        let launchSettings = settings
        let routing = ChatWorkerRouting(
            workerContextTokens: 8192,
            environment: {
                WorkerPickEnvironment(
                    catalog: .bundled, downloadedRepoIDs: workers, budgetBytes: 6 * 1024 * 1024 * 1024,
                    contextTokens: 8192, bandwidthGBps: 120)
            },
            ensureEndpoint: {
                try await controller.ensureRunning(
                    settings: launchSettings,
                    environment: WorkerServerLaunchPlan.environment(
                        base: launchSettings.launchEnvironment,
                        analyticsDatabasePath: FileManager.default.temporaryDirectory
                            .appendingPathComponent("worker-e2e-analytics.sqlite").path,
                        memoryLimitBytes: 6 * 1024 * 1024 * 1024,
                        cacheLimitBytes: WorkerServerController.cacheLimitBytes))
            })

        var context = ChatToolExecutionContext(
            imageGenerationModelID: nil,
            baseURL: URL(string: "http://127.0.0.1:9")!,  // the manager isn't running; a worker spawn must not use it
            apiKey: nil,
            imageReferences: [],
            modelSearchPath: settings.expandedModelSearchPath,
            additionalModelSearchPaths: []
        )
        context.settings = settings
        context.agentRegistry = ChatAgentRegistry()
        context.workerRouting = routing
        context.subAgentToolDefinitions = []

        let executor = ChatSpawnAgentToolExecutor()
        let prepared = try await executor.prepare(
            call: MLXChatToolCall(id: "1", function: MLXChatFunctionCall(
                name: ChatSpawnAgentToolRegistry.toolName,
                arguments: #"{"task":"Reply with a one-line Python function that adds two numbers.","category":"coding"}"#)),
            context: context)
        let json = await executor.run(prepared)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertEqual(payload["ok"] as? Bool, true, json)
        XCTAssertEqual(payload["model"] as? String, "mlx-community/Qwen3-1.7B-4bit", json)
        XCTAssertEqual(payload["category"] as? String, "coding")
        XCTAssertFalse((payload["answer"] as? String ?? "").isEmpty, json)
        XCTAssertNotNil(payload["worker"] as? String)
        guard case .running(let port) = controller.state else { return XCTFail("worker server should be running") }
        XCTAssertTrue(WorkerServerController.preferredPorts.contains(port))
        print("E2E payload: \(json)")
    }
}
