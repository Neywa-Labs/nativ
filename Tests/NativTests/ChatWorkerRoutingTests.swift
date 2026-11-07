import XCTest
@testable import NativServerKit

private let workerRepo = "mlx-community/Worker-1.7B-4bit"
private let betterRepo = "mlx-community/Better-4B-4bit"
private let workerEndpoint = URL(string: "http://127.0.0.1:8081")!

private func workerCatalog() -> WorkerModelCatalog {
    func base(_ repo: String, params: Double, scores: [String: Double]) -> WorkerBaseModel {
        WorkerBaseModel(
            baseID: repo, totalParams: params, activeParams: params, kvBytesPerToken: 100_000,
            modality: "text", scores: scores.mapValues { WorkerCategoryScore(score: $0, sources: []) },
            variants: [WorkerVariant(
                repoID: repo, bits: 4, sizeBytes: Int64(params * 500_000_000), downloads: 1,
                supportsTools: true)])
    }
    return WorkerModelCatalog(
        version: 1, generated: "test", categories: ["coding", "writing", "general"], attribution: [],
        estimates: .default,
        models: [
            base(workerRepo, params: 1.7, scores: ["coding": 60, "general": 50]),
            base(betterRepo, params: 4, scores: ["coding": 90, "general": 80]),
        ])
}

@MainActor
private final class EndpointRecorder {
    var calls = 0
}

private func routing(
    downloaded: Set<String> = [workerRepo],
    contextTokens: Int = 8192,
    budget: Int64 = 100_000_000_000,
    recorder: EndpointRecorder? = nil,
    endpointError: Error? = nil,
    endpoint: URL = workerEndpoint
) -> ChatWorkerRouting {
    let catalog = workerCatalog()
    return ChatWorkerRouting(
        workerContextTokens: contextTokens,
        environment: {
            WorkerPickEnvironment(
                catalog: catalog, downloadedRepoIDs: downloaded, budgetBytes: budget,
                contextTokens: contextTokens, bandwidthGBps: 120)
        },
        ensureEndpoint: {
            recorder?.calls += 1
            if let endpointError { throw endpointError }
            return endpoint
        })
}

private func candidate(_ repo: String, quality: Double, speed: WorkerSpeedBucket, downloaded: Bool) -> WorkerCandidate {
    WorkerCandidate(
        repoID: repo, baseID: repo, category: "coding", estimatedQuality: quality, estimatedTokensPerSecond: 50,
        speed: speed, sizeBytes: 1_800_000_000, downloads: 1, isDownloaded: downloaded, sources: [])
}

private func context(routing: ChatWorkerRouting?) -> ChatToolExecutionContext {
    var context = ChatToolExecutionContext(
        imageGenerationModelID: nil,
        baseURL: URL(string: "http://127.0.0.1:8080")!,
        apiKey: nil,
        imageReferences: [],
        modelSearchPath: "",
        additionalModelSearchPaths: []
    )
    context.settings = NativSettings(languageModelID: "org/manager")
    context.agentRegistry = ChatAgentRegistry()
    context.workerRouting = routing
    return context
}

private func call(_ arguments: String) -> MLXChatToolCall {
    MLXChatToolCall(id: "1", function: MLXChatFunctionCall(name: ChatSpawnAgentToolRegistry.toolName, arguments: arguments))
}

private func decode(_ json: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private func schemaJSON(_ definition: MLXChatToolDefinition) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(definition), as: UTF8.self)
}

@MainActor
final class ChatWorkerRoutingTests: XCTestCase {
    func testDefinitionsWithoutCategoriesAreUnchanged() throws {
        let plain = try schemaJSON(ChatSpawnAgentToolRegistry.definitions()[0])
        XCTAssertEqual(plain, try schemaJSON(ChatSpawnAgentToolRegistry.definitions(workerCategories: nil)[0]))
        XCTAssertFalse(plain.contains("\"category\""))
    }

    func testDefinitionsWithCategoriesAddEnum() throws {
        let json = try schemaJSON(ChatSpawnAgentToolRegistry.definitions(workerCategories: ["coding", "general"])[0])
        XCTAssertTrue(json.contains("\"category\""))
        XCTAssertTrue(json.contains("\"enum\":[\"coding\",\"general\"]"))
    }

    func testModelBeatsCategory() {
        XCTAssertEqual(
            ChatSpawnAgentRouting.decide(
                modelID: "x", modelIsDownloaded: true, category: "coding", pick: nil,
                estimatedPromptTokens: 10, workerContextTokens: 8192),
            .parent)
        XCTAssertEqual(
            ChatSpawnAgentRouting.decide(
                modelID: nil, modelIsDownloaded: false, category: nil, pick: nil,
                estimatedPromptTokens: 10, workerContextTokens: 8192),
            .parent)
    }

    func testMissingModelWithCategoryUsesCategoryPick() throws {
        let pick = WorkerModelPicker.pick(
            category: "coding",
            environment: WorkerPickEnvironment(
                catalog: workerCatalog(), downloadedRepoIDs: [workerRepo], budgetBytes: 100_000_000_000,
                contextTokens: 8192, bandwidthGBps: 120))
        let runnable = try XCTUnwrap(pick.runnable)
        XCTAssertEqual(
            ChatSpawnAgentRouting.decide(
                modelID: betterRepo, modelIsDownloaded: false, category: "coding", pick: pick,
                estimatedPromptTokens: 10, workerContextTokens: 8192),
            .worker(runnable, isFallback: false))
        XCTAssertEqual(
            ChatSpawnAgentRouting.decide(
                modelID: betterRepo, modelIsDownloaded: false, category: nil, pick: pick,
                estimatedPromptTokens: 10, workerContextTokens: 8192),
            .parent)
    }

    func testSuggestedModelPassedToSpawnRunsOnDownloadedWorker() async throws {
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding","model":"\#(betterRepo)"}"#),
            context: context(routing: routing()))
        XCTAssertEqual(prepared.modelID, workerRepo)
        XCTAssertNotNil(prepared.workerRoute)
        XCTAssertEqual(prepared.category, "coding")
        XCTAssertEqual(prepared.routeNote, "\(betterRepo) isn't downloaded; used the coding pick instead")
        let payload = try decode(await ChatSpawnAgentToolExecutor().run(prepared))
        XCTAssertEqual(payload["note"] as? String, prepared.routeNote)
    }

    func testSuggestedModelWithNothingDownloadedRunsOnManager() async throws {
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding","model":"\#(betterRepo)"}"#),
            context: context(routing: routing(downloaded: [])))
        XCTAssertNil(prepared.workerRoute)
        XCTAssertEqual(prepared.modelID, "org/manager")
        XCTAssertEqual(
            prepared.routeNote,
            "\(betterRepo) isn't downloaded; used the coding pick instead; no fast worker downloaded for coding; ran on the manager model")
    }

    func testNoRoutingMeansParentPath() async throws {
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding"}"#), context: context(routing: nil))
        XCTAssertEqual(prepared.modelID, "org/manager")
        XCTAssertNil(prepared.workerRoute)
        XCTAssertEqual(prepared.subAgentContext.baseURL.absoluteString, "http://127.0.0.1:8080")
    }

    func testCategorySpawnUsesWorkerEndpointAndModel() async throws {
        let recorder = EndpointRecorder()
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding"}"#), context: context(routing: routing(recorder: recorder)))
        XCTAssertEqual(prepared.modelID, workerRepo)
        let route = try XCTUnwrap(prepared.workerRoute)
        let endpoint = try await route.ensureEndpoint()
        XCTAssertEqual(endpoint, workerEndpoint)
        XCTAssertEqual(recorder.calls, 1)
        XCTAssertTrue(route.summary.hasPrefix("ran on \(workerRepo) (coding, est. speed "), route.summary)
        XCTAssertEqual(
            prepared.suggestion,
            "better: \(betterRepo) (2.0 GB, not downloaded); suggest the user downloads it")
    }

    func testBackgroundWorkerSpawnIsAllowed() async throws {
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding","run_in_background":true}"#),
            context: context(routing: routing()))
        XCTAssertEqual(prepared.modelID, workerRepo)
    }

    func testNothingDownloadedRunsOnManagerWithSuggestion() async throws {
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding"}"#), context: context(routing: routing(downloaded: [])))
        XCTAssertNil(prepared.workerRoute)
        XCTAssertEqual(prepared.modelID, "org/manager")
        XCTAssertEqual(prepared.routeNote, "no fast worker downloaded for coding; ran on the manager model")
        XCTAssertNotNil(prepared.suggestion)
    }

    func testBranchTooLongForWorkerRunsOnManager() {
        let pick = WorkerModelPicker.pick(
            category: "coding",
            environment: WorkerPickEnvironment(
                catalog: workerCatalog(), downloadedRepoIDs: [workerRepo], budgetBytes: 100_000_000_000,
                contextTokens: 8192, bandwidthGBps: 120))
        XCTAssertEqual(
            ChatSpawnAgentRouting.decide(
                modelID: nil, modelIsDownloaded: false, category: "coding", pick: pick,
                estimatedPromptTokens: 9000, workerContextTokens: 8192),
            .manager(note: "conversation is too long for the worker context (9000 tokens); ran on the manager model"))
        XCTAssertEqual(
            ChatSpawnAgentRouting.estimatedTokens([MLXChatMessage(role: "user", content: String(repeating: "a", count: 400))]),
            100)
    }

    func testWorkerEndpointFailureFailsOnlyThisSpawn() async throws {
        let failing = routing(endpointError: WorkerServerError.notReady)
        let executor = ChatSpawnAgentToolExecutor()
        let prepared = try await executor.prepare(
            call: call(#"{"task":"t","category":"coding"}"#), context: context(routing: failing))
        let payload = try decode(await executor.run(prepared))
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["model"] as? String, workerRepo)
        XCTAssertEqual(prepared.registry?.record(for: prepared.agentID)?.status, .error)
    }

    func testNothingFitsSaysSoInsteadOfNothingDownloaded() async throws {
        let prepared = try await ChatSpawnAgentToolExecutor().prepare(
            call: call(#"{"task":"t","category":"coding"}"#), context: context(routing: routing(budget: 1)))
        XCTAssertEqual(prepared.modelID, "org/manager")
        XCTAssertEqual(
            prepared.routeNote,
            "no downloaded worker fits in memory next to the manager; lower the manager's Context window in Model Configuration or Worker context in Settings; ran on the manager model")
        XCTAssertNil(prepared.suggestion)
    }

    func testSuggestionRules() {
        let ran = candidate("ran", quality: 70, speed: .fast, downloaded: true)
        func suggest(_ recommended: WorkerCandidate, isFallback: Bool = false) -> String? {
            ChatSpawnAgentRouting.suggestion(recommended: recommended, ran: ran, isFallback: isFallback)
        }
        XCTAssertEqual(
            suggest(candidate("better", quality: 72, speed: .fast, downloaded: false)),
            "better: better (1.8 GB, not downloaded); suggest the user downloads it")
        XCTAssertNil(suggest(candidate("worse", quality: 65, speed: .superFast, downloaded: false)))
        XCTAssertNil(suggest(candidate("equal", quality: 70, speed: .superFast, downloaded: false)))
        XCTAssertNotNil(suggest(candidate("cat", quality: 60, speed: .fast, downloaded: false), isFallback: true))
        XCTAssertNil(suggest(candidate("have", quality: 90, speed: .fast, downloaded: true)))
        XCTAssertNotNil(ChatSpawnAgentRouting.suggestion(
            recommended: candidate("any", quality: 50, speed: .fast, downloaded: false), ran: nil, isFallback: false))
    }

    func testWorkerTransportErrorSaysWorkerStopped() async throws {
        let executor = ChatSpawnAgentToolExecutor()
        let prepared = try await executor.prepare(
            call: call(#"{"task":"t","category":"coding"}"#),
            context: context(routing: routing(endpoint: URL(string: "http://127.0.0.1:9")!)))
        let payload = try decode(await executor.run(prepared))
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertTrue((payload["error"] as? String ?? "").hasPrefix("The worker server stopped responding"), "\(payload)")
    }

    func testWorkerSettingsTurnThinkingOffWithoutProfile() {
        var manager = NativSettings(languageModelID: "org/manager")
        manager.thinkingEnabled = true
        manager.speculativeDecodingEnabled = true
        let worker = ChatSpawnAgentRouting.workerSettings(manager, workerModelID: workerRepo)
        XCTAssertFalse(worker.thinkingEnabled)
        XCTAssertFalse(worker.speculativeDecodingEnabled)
    }

    func testPayloadOmitsWorkerFieldsWhenOff() throws {
        let json = ChatSpawnAgentToolExecutor().handlePayload(agentID: "a")
        XCTAssertEqual(Set(try decode(json).keys), ["ok", "agent_id", "status"])
        let encoder = JSONEncoder()
        let payload = ChatSpawnAgentToolResultPayload(
            ok: true, agentID: "a", status: "completed", stopReason: nil, answer: "x", error: nil)
        let keys = Set(try decode(String(decoding: try encoder.encode(payload), as: UTF8.self)).keys)
        XCTAssertEqual(keys, ["ok", "agent_id", "status", "answer"])
    }
}

@MainActor
final class ChatSuggestWorkersToolTests: XCTestCase {
    private let categories = ["coding", "writing", "general"]

    private func spawnAndList() -> [MLXChatToolDefinition] {
        ChatSpawnAgentToolRegistry.definitions() + ChatListAgentsToolRegistry.definitions()
    }

    func testSchemaUnchangedWhenOff() {
        XCTAssertEqual(ChatWorkerToolSchema.apply(to: spawnAndList(), enabled: false, categories: categories), spawnAndList())
    }

    func testSchemaAddsCategoryAndSuggestWhenOn() throws {
        let result = ChatWorkerToolSchema.apply(to: spawnAndList(), enabled: true, categories: categories)
        XCTAssertEqual(
            result.map(\.function.name),
            [ChatSpawnAgentToolRegistry.toolName, ChatListAgentsToolRegistry.toolName, ChatSuggestWorkersToolRegistry.toolName])
        XCTAssertEqual(result[0], ChatSpawnAgentToolRegistry.definitions(workerCategories: categories)[0])
    }

    func testSchemaUntouchedWhenSpawnDisabled() {
        let listOnly = ChatListAgentsToolRegistry.definitions()
        XCTAssertEqual(ChatWorkerToolSchema.apply(to: listOnly, enabled: true, categories: categories), listOnly)
    }

    func testSuggestWorkersReturnsSharedSet() async throws {
        let toolCall = MLXChatToolCall(id: "1", function: MLXChatFunctionCall(
            name: ChatSuggestWorkersToolRegistry.toolName,
            arguments: #"{"subtasks":[{"id":"a","category":"coding"},{"id":"b","category":"general"}]}"#))
        let json = try await ChatSuggestWorkersToolExecutor().execute(call: toolCall, context: context(routing: routing()))
        let payload = try decode(json)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let models = try XCTUnwrap(payload["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0]["model"] as? String, betterRepo)
        XCTAssertEqual(models[0]["downloaded"] as? Bool, false)
        XCTAssertNotNil(models[0]["est_speed"] as? String)
        XCTAssertEqual((models[0]["subtasks"] as? [String])?.sorted(), ["a", "b"])
        XCTAssertEqual(payload["uncovered"] as? [String], [])
    }

    func testSuggestWorkersFailsWhenOff() async {
        let toolCall = MLXChatToolCall(id: "1", function: MLXChatFunctionCall(
            name: ChatSuggestWorkersToolRegistry.toolName, arguments: #"{"subtasks":[]}"#))
        do {
            _ = try await ChatSuggestWorkersToolExecutor().execute(call: toolCall, context: context(routing: nil))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Worker sub-agents are turned off in Settings.")
        }
    }

    func testSubAgentsNeverSeeSuggestWorkers() {
        var subContext = context(routing: nil)
        subContext.subAgentToolDefinitions = [ChatSuggestWorkersToolRegistry.definition(categories: categories)]
        let definitions = ChatAgentLoop.subAgentToolDefinitions(
            settings: NativSettings(), canEditImage: false, context: subContext)
        XCTAssertFalse(definitions.contains { $0.function.name == ChatSuggestWorkersToolRegistry.toolName })
    }

    func testListAgentsAddsModelOnlyForWorkerAgents() throws {
        let registry = ChatAgentRegistry()
        let plain = registry.register(task: "a", modelID: "org/manager")
        let worker = registry.register(task: "b", modelID: workerRepo, category: "coding")
        let agents = try XCTUnwrap(try decode(ChatListAgentsToolExecutor().execute(registry: registry))["agents"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0["agent_id"] as! String, $0) })
        XCTAssertNil(byID[plain]?["model"])
        XCTAssertEqual(byID[worker]?["model"] as? String, workerRepo)
        XCTAssertEqual(byID[worker]?["category"] as? String, "coding")
    }
}
