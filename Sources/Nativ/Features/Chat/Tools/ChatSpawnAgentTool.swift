import Foundation
import NativServerKit

enum ChatSpawnAgentToolRegistry {
    static let toolName = "spawn_agent"

    static func definitions(workerCategories: [String]? = nil) -> [MLXChatToolDefinition] {
        var properties: [String: MLXJSONValue] = [
                    "task": .object([
                        "type": .string("string"),
                        "description": .string("The sub-agent's instruction.")
                    ]),
                    "mode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("fresh"), .string("branch")]),
                        "description": .string(
                            "'fresh' (default): starts with just the task. 'branch': clones this conversation's history first, then adds the task."
                        )
                    ]),
                    "context": .object([
                        "type": .string("string"),
                        "description": .string("Facts the sub-agent needs, without full history. Ignored in 'branch' mode.")
                    ]),
                    "model": .object([
                        "type": .string("string"),
                        "description": .string("A downloaded model ID, e.g. 'mlx-community/Qwen3-4B-4bit'. Omit to use the current model.")
                    ]),
                    "run_in_background": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "If true, returns an agent_id immediately instead of waiting, using the parent's model. Check via check_agent/list_agents. Different-model workers must run in the foreground; they are serialized with other workers to avoid unloading an active model. Defaults to false."
                        )
                    ])
        ]
        if let workerCategories {
            properties["category"] = .object([
                "type": .string("string"),
                "enum": .array(workerCategories.map { .string($0) }),
                "description": .string(
                    "Label this sub-task so it runs on a fast worker model picked for that kind of work."
                )
            ])
        }
        return [MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "Delegate a sub-task to a separate, independent agent.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object(properties),
                "required": .array([.string("task")])
            ])
        ))]
    }
}

enum ChatConcurrentSpawnGate {
    static let maximumConcurrent = 5
}

enum ChatSpawnAgentMode: String, Decodable {
    case fresh
    case branch
}

struct ChatSpawnAgentResourceLimits: Equatable {
    static let `default` = ChatSpawnAgentResourceLimits(maxTurns: 50, maxTokens: 8_000, maxWallTimeSeconds: 600)

    let maxTurns: Int
    let maxTokens: Int
    let maxWallTimeSeconds: TimeInterval

    init(maxTurns: Int, maxTokens: Int, maxWallTimeSeconds: TimeInterval) {
        self.maxTurns = max(1, maxTurns)
        self.maxTokens = max(1, maxTokens)
        self.maxWallTimeSeconds = max(1, maxWallTimeSeconds)
    }
}

struct ChatSpawnAgentToolArguments: Decodable {
    let task: String
    let mode: ChatSpawnAgentMode
    let context: String?
    let modelID: String?
    let runInBackground: Bool
    let category: String?
    let resourceLimits = ChatSpawnAgentResourceLimits.default

    enum CodingKeys: String, CodingKey {
        case task
        case mode
        case context
        case modelID = "model"
        case runInBackground = "run_in_background"
        case category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        task = try container.decode(String.self, forKey: .task)
        mode = try container.decodeIfPresent(ChatSpawnAgentMode.self, forKey: .mode) ?? .fresh
        context = try container.decodeIfPresent(String.self, forKey: .context)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        runInBackground = try container.decodeIfPresent(Bool.self, forKey: .runInBackground) ?? false
        category = try container.decodeIfPresent(String.self, forKey: .category)
    }

    static func runsInBackground(_ argumentsJSON: String?) -> Bool {
        guard let data = argumentsJSON?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return (object["run_in_background"] as? Bool) ?? false
    }
}

struct ChatSpawnAgentToolResultPayload: Encodable {
    let ok: Bool
    let agentID: String?
    let status: String?
    let stopReason: String?
    let answer: String?
    let error: String?
    var model: String? = nil
    var category: String? = nil
    var worker: String? = nil
    var note: String? = nil
    var suggestion: String? = nil

    enum CodingKeys: String, CodingKey {
        case ok
        case agentID = "agent_id"
        case status
        case stopReason = "stop_reason"
        case answer
        case error
        case model
        case category
        case worker
        case note
        case suggestion
    }
}

enum ChatSpawnAgentToolError: LocalizedError {
    case invalidArguments
    case emptyTask
    case backgroundModelSwitch
    case modelUnavailable(modelID: String?)
    case modelKindNotSupported(modelID: String)
    case noParentHistory

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "The spawn_agent arguments were not valid JSON."
        case .backgroundModelSwitch:
            return "Background agents must use the parent's model because the server has one text-model slot. Use run_in_background:false to delegate to a different model."
        case .emptyTask:
            return "spawn_agent requires a non-empty task."
        case .modelUnavailable(let modelID):
            if let modelID {
                return "\(modelID) isn't a downloaded model."
            }
            return "No language model is available to run the sub-agent."
        case .modelKindNotSupported(let modelID):
            return "\(modelID) doesn't support text generation, so it can't run as a spawn_agent sub-agent yet."
        case .noParentHistory:
            return "No conversation history is available to branch from."
        }
    }
}

enum ChatSpawnAgentModelKind: Equatable {
    case textGeneration
    case unsupported

    static func resolve(_ model: LocalModel) -> ChatSpawnAgentModelKind {
        model.isEligibleForLanguageModelPicker ? .textGeneration : .unsupported
    }
}

enum ChatSpawnAgentModelResolver {
    static func resolve(
        requestedModelID: String?,
        fallbackModelID: String?,
        searchPaths: LocalModelSearchPaths
    ) async throws -> String {
        guard let requestedModelID, !requestedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let fallbackModelID else {
                throw ChatSpawnAgentToolError.modelUnavailable(modelID: nil)
            }
            return fallbackModelID
        }

        let models = try await LocalModelDiscovery.scan(searchPaths: searchPaths)
        guard let model = models.first(where: { $0.repoID == requestedModelID }) else {
            throw ChatSpawnAgentToolError.modelUnavailable(modelID: requestedModelID)
        }
        guard ChatSpawnAgentModelKind.resolve(model) == .textGeneration else {
            throw ChatSpawnAgentToolError.modelKindNotSupported(modelID: requestedModelID)
        }
        return requestedModelID
    }
}

enum ChatSpawnAgentTranscriptBuilder {
    static func initialMessages(
        arguments: ChatSpawnAgentToolArguments,
        parentMessages: [ChatTranscriptMessage]
    ) throws -> [MLXChatMessage] {
        switch arguments.mode {
        case .fresh:
            let content = arguments.context.map { "Context:\n\($0)\n\nTask:\n\(arguments.task)" }
                ?? arguments.task
            return [MLXChatMessage(role: "user", content: content)]
        case .branch:
            guard !parentMessages.isEmpty else {
                throw ChatSpawnAgentToolError.noParentHistory
            }
            var cloned = parentMessages.compactMap { $0.apiMessage }
            cloned.append(MLXChatMessage(role: "user", content: arguments.task))
            return cloned
        }
    }
}

struct ChatSpawnAgentPreparedCall {
    let agentID: String
    let modelID: String
    let messages: [MLXChatMessage]
    let settings: NativSettings
    let canEditImage: Bool
    let subAgentContext: ChatToolExecutionContext
    let onUpdate: (@MainActor @Sendable ([ChatTranscriptMessage]) -> Void)?
    let registry: ChatAgentRegistry?
    let limits: ChatSpawnAgentResourceLimits
    var workerRoute: ChatSpawnAgentWorkerRoute? = nil
    var category: String? = nil
    var routeNote: String? = nil
    var suggestion: String? = nil
}

struct ChatSpawnAgentToolExecutor {
    func execute(call: MLXChatToolCall, context: ChatToolExecutionContext) async throws -> String {
        let prepared = try await prepare(call: call, context: context)
        return await run(prepared)
    }

    func prepare(call: MLXChatToolCall, context: ChatToolExecutionContext) async throws -> ChatSpawnAgentPreparedCall {
        guard call.function?.name == ChatSpawnAgentToolRegistry.toolName else {
            throw ChatImageToolError.unsupportedTool(call.function?.name ?? "unknown")
        }
        guard let argumentsData = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(ChatSpawnAgentToolArguments.self, from: argumentsData)
        else {
            throw ChatSpawnAgentToolError.invalidArguments
        }
        guard !arguments.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatSpawnAgentToolError.emptyTask
        }
        guard let settings = context.settings else {
            throw ChatSpawnAgentToolError.modelUnavailable(modelID: nil)
        }

        let messages = try ChatSpawnAgentTranscriptBuilder.initialMessages(
            arguments: arguments,
            parentMessages: context.spawnAgentParentMessages
        )
        try Task.checkCancellation()
        var runSettings = settings
        var workerRoute: ChatSpawnAgentWorkerRoute?
        var routedCategory: String?
        var routeNote: String?
        var suggestion: String?
        var modelID: String?
        var requestedModelID = arguments.modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if requestedModelID?.isEmpty == true { requestedModelID = nil }
        if let routing = context.workerRouting, let requestedCategory = arguments.category {
            let environment = await routing.environment()
            let pick = WorkerModelPicker.pick(category: requestedCategory, environment: environment)
            let decision = ChatSpawnAgentRouting.decide(
                modelID: requestedModelID,
                modelIsDownloaded: requestedModelID.map(environment.downloadedRepoIDs.contains) ?? false,
                category: requestedCategory,
                pick: pick,
                estimatedPromptTokens: ChatSpawnAgentRouting.estimatedTokens(messages),
                workerContextTokens: routing.workerContextTokens
            )
            // Managers often pass the model suggest_workers named; if it isn't downloaded, use the category pick.
            var overrideNote: String?
            if decision != .parent {
                routedCategory = pick.category
                if let ignored = requestedModelID {
                    overrideNote = "\(ignored) isn't downloaded; used the \(pick.category) pick instead"
                    requestedModelID = nil
                }
            }
            switch decision {
            case .worker(let candidate, let isFallback):
                routeNote = overrideNote
                modelID = candidate.repoID
                runSettings = ChatSpawnAgentRouting.workerSettings(settings, workerModelID: candidate.repoID)
                suggestion = ChatSpawnAgentRouting.suggestion(
                    recommended: pick.recommended, ran: candidate, isFallback: isFallback)
                workerRoute = ChatSpawnAgentWorkerRoute(
                    candidate: candidate,
                    summary: ChatSpawnAgentRouting.summary(
                        candidate, requestedCategory: pick.category, isFallback: isFallback),
                    ensureEndpoint: routing.ensureEndpoint
                )
            case .manager(let note):
                routeNote = [overrideNote, note].compactMap { $0 }.joined(separator: "; ")
                // When workers are blocked by memory, another download wouldn't help.
                suggestion = pick.blockedByMemory
                    ? nil
                    : ChatSpawnAgentRouting.suggestion(
                        recommended: pick.recommended, ran: nil, isFallback: false)
            case .parent:
                break
            }
        }
        let resolvedModelID: String
        if let modelID {
            resolvedModelID = modelID
        } else {
            resolvedModelID = try await ChatSpawnAgentModelResolver.resolve(
                requestedModelID: requestedModelID,
                fallbackModelID: settings.languageModelID,
                searchPaths: LocalModelSearchPaths(
                    primary: context.modelSearchPath,
                    additional: context.additionalModelSearchPaths
                )
            )
        }
        try Task.checkCancellation()
        // Worker spawns use their own server slot, so they may run in the background.
        if arguments.runInBackground, workerRoute == nil, resolvedModelID != settings.languageModelID {
            throw ChatSpawnAgentToolError.backgroundModelSwitch
        }
        let parentImages = context.spawnAgentParentMessages.reversed().lazy
            .map { $0.imageAttachments.filter { $0.chatAttachmentKind == .image } }
            .first { !$0.isEmpty } ?? []

        var subAgentContext = context
        // Scope and trackers are inherited, but approvals belong to individual
        // parent tool calls and must never authorize a child's different call.
        subAgentContext.fileWriteApprovalGranted = false
        subAgentContext.terminalApprovalGranted = false
        subAgentContext.workAction = nil
        subAgentContext.imageModelSelection = nil
        subAgentContext.imageExecutionWillStart = nil
        subAgentContext.settings = nil
        subAgentContext.spawnAgentParentMessages = []
        subAgentContext.spawnAgentUpdate = nil
        subAgentContext.workerRouting = nil

        let agentID = await context.agentRegistry?.register(
            task: arguments.task, modelID: resolvedModelID, category: routedCategory)
            ?? UUID().uuidString

        return ChatSpawnAgentPreparedCall(
            agentID: agentID,
            modelID: resolvedModelID,
            messages: messages,
            settings: runSettings,
            canEditImage: !parentImages.isEmpty,
            subAgentContext: subAgentContext,
            onUpdate: context.spawnAgentUpdate,
            registry: context.agentRegistry,
            limits: ChatSpawnAgentResourceLimits(
                maxTurns: arguments.resourceLimits.maxTurns,
                maxTokens: settings.maxTokens,
                maxWallTimeSeconds: arguments.resourceLimits.maxWallTimeSeconds
            ),
            workerRoute: workerRoute,
            category: routedCategory,
            routeNote: routeNote,
            suggestion: suggestion
        )
    }

    func run(_ prepared: ChatSpawnAgentPreparedCall) async -> String {
        await prepared.registry?.markRunning(prepared.agentID)
        do {
            try Task.checkCancellation()
            let result = try await ChatAgentLoop.withTimeout(seconds: prepared.limits.maxWallTimeSeconds) {
                var context = prepared.subAgentContext
                if let route = prepared.workerRoute {
                    context.baseURL = try await route.ensureEndpoint()
                }
                let endpoint = context.baseURL
                try await ChatAgentModelGate.shared.acquire(modelID: prepared.modelID, endpoint: endpoint)
                defer { ChatAgentModelGate.shared.release(endpoint: endpoint) }
                return try await ChatAgentLoop.run(
                    messages: prepared.messages,
                    modelID: prepared.modelID,
                    settings: prepared.settings,
                    canEditImage: prepared.canEditImage,
                    context: context,
                    agentID: prepared.agentID,
                    limits: prepared.limits,
                    onUpdate: prepared.onUpdate
                )
            }
            if let stopReason = result.stopReason {
                await prepared.registry?.stop(prepared.agentID, reason: stopReason, partialResult: result.completion.content)
                return (try? encodedPayload(annotated(ChatSpawnAgentToolResultPayload(
                    ok: true,
                    agentID: prepared.agentID,
                    status: ChatSpawnedAgentStatus.stopped.rawValue,
                    stopReason: stopReason.rawValue,
                    answer: result.completion.content,
                    error: nil
                ), prepared))) ?? #"{"ok":true}"#
            }
            await prepared.registry?.complete(prepared.agentID, result: result.completion.content)
            return (try? encodedPayload(annotated(ChatSpawnAgentToolResultPayload(
                ok: true,
                agentID: prepared.agentID,
                status: ChatSpawnedAgentStatus.completed.rawValue,
                stopReason: nil,
                answer: result.completion.content,
                error: nil
            ), prepared))) ?? #"{"ok":true}"#
        } catch ChatAgentLoopError.timedOut {
            await prepared.registry?.stop(prepared.agentID, reason: .timeout, partialResult: nil)
            return (try? encodedPayload(annotated(ChatSpawnAgentToolResultPayload(
                ok: true, agentID: prepared.agentID,
                status: ChatSpawnedAgentStatus.stopped.rawValue,
                stopReason: ChatSpawnedAgentStopReason.timeout.rawValue,
                answer: nil, error: nil
            ), prepared))) ?? #"{"ok":false,"error":"Sub-agent timed out."}"#
        } catch is CancellationError {
            await prepared.registry?.stop(prepared.agentID, reason: .cancelled, partialResult: nil)
            return (try? encodedPayload(annotated(ChatSpawnAgentToolResultPayload(
                ok: true,
                agentID: prepared.agentID,
                status: ChatSpawnedAgentStatus.stopped.rawValue,
                stopReason: ChatSpawnedAgentStopReason.cancelled.rawValue,
                answer: nil,
                error: nil
            ), prepared))) ?? #"{"ok":true}"#
        } catch {
            let error = ChatSpawnAgentRouting.reportedError(error, onWorker: prepared.workerRoute != nil)
            await prepared.registry?.fail(prepared.agentID, error: error.localizedDescription)
            return failurePayload(agentID: prepared.agentID, error: error, prepared: prepared)
        }
    }

    func handlePayload(agentID: String) -> String {
        (try? encodedPayload(ChatSpawnAgentToolResultPayload(
            ok: true,
            agentID: agentID,
            status: ChatSpawnedAgentStatus.queued.rawValue,
            stopReason: nil,
            answer: nil,
            error: nil
        ))) ?? #"{"ok":true,"status":"queued"}"#
    }

    func failurePayload(error: Error) -> String {
        failurePayload(agentID: nil, error: error)
    }

    func failurePayload(agentID: String?, error: Error, prepared: ChatSpawnAgentPreparedCall? = nil) -> String {
        var payload = ChatSpawnAgentToolResultPayload(
            ok: false,
            agentID: agentID,
            status: agentID == nil ? nil : ChatSpawnedAgentStatus.error.rawValue,
            stopReason: nil,
            answer: nil,
            error: error.localizedDescription
        )
        if let prepared { payload = annotated(payload, prepared) }
        return (try? encodedPayload(payload))
            ?? #"{"ok":false,"error":"spawn_agent failed."}"#
    }

    private func annotated(
        _ payload: ChatSpawnAgentToolResultPayload,
        _ prepared: ChatSpawnAgentPreparedCall
    ) -> ChatSpawnAgentToolResultPayload {
        var payload = payload
        if let route = prepared.workerRoute {
            payload.model = route.candidate.repoID
            payload.worker = route.summary
        } else if prepared.routeNote != nil {
            payload.model = prepared.modelID
        }
        payload.note = prepared.routeNote
        payload.category = prepared.category
        payload.suggestion = prepared.suggestion
        return payload
    }

    private func encodedPayload(_ payload: ChatSpawnAgentToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}


struct ChatSpawnAgentWorkerRoute: Sendable {
    let candidate: WorkerCandidate
    let summary: String
    let ensureEndpoint: @MainActor @Sendable () async throws -> URL
}

enum ChatSpawnAgentRouteDecision: Equatable {
    case parent
    case manager(note: String)
    case worker(WorkerCandidate, isFallback: Bool)
}

enum ChatSpawnAgentRouting {
    static func decide(
        modelID: String?,
        modelIsDownloaded: Bool,
        category: String?,
        pick: WorkerPick?,
        estimatedPromptTokens: Int,
        workerContextTokens: Int
    ) -> ChatSpawnAgentRouteDecision {
        if let modelID, !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           modelIsDownloaded || category == nil
        {
            return .parent
        }
        guard category != nil, let pick else { return .parent }
        guard let runnable = pick.runnable else {
            if pick.blockedByMemory {
                return .manager(
                    note: "no downloaded worker fits in memory next to the manager; lower the manager's Context window in Model Configuration or Worker context in Settings; ran on the manager model")
            }
            return .manager(note: "no fast worker downloaded for \(pick.category); ran on the manager model")
        }
        if estimatedPromptTokens > workerContextTokens {
            return .manager(
                note: "conversation is too long for the worker context (\(estimatedPromptTokens) tokens); ran on the manager model")
        }
        return .worker(runnable, isFallback: pick.runnableIsFallback)
    }

    static func estimatedTokens(_ messages: [MLXChatMessage]) -> Int {
        messages.reduce(0) { total, message in
            switch message.content {
            case .text(let text): total + text.count
            case .parts(let parts): total + parts.reduce(0) { $0 + ($1.text?.count ?? 0) }
            case nil: total
            }
        } / 4
    }

    static func workerSettings(_ base: NativSettings, workerModelID: String) -> NativSettings {
        var settings = base
        let profile = base.modelProfile(for: workerModelID)
        settings.thinkingEnabled = profile?.thinkingEnabled ?? false
        settings.thinkingBudgetEnabled = profile?.thinkingBudgetEnabled ?? false
        if let profile { settings.thinkingBudget = profile.thinkingBudget }
        settings.speculativeDecodingEnabled = false
        return settings
    }

    static func summary(_ candidate: WorkerCandidate, requestedCategory: String, isFallback: Bool) -> String {
        let quality = Int(candidate.estimatedQuality.rounded())
        var text = "ran on \(candidate.repoID) (\(candidate.category), est. speed \(candidate.speed.rawValue), est. quality \(quality))"
        if isFallback {
            text += "; no \(requestedCategory) worker downloaded, used the best general worker"
        }
        return text
    }

    static func suggestion(
        recommended: WorkerCandidate?,
        ran: WorkerCandidate?,
        isFallback: Bool
    ) -> String? {
        guard let recommended, !recommended.isDownloaded, recommended.repoID != ran?.repoID else { return nil }
        if let ran, !isFallback, recommended.estimatedQuality <= ran.estimatedQuality { return nil }
        let gigabytes = String(format: "%.1f", Double(recommended.sizeBytes) / 1_000_000_000)
        return "better: \(recommended.repoID) (\(gigabytes) GB, not downloaded); suggest the user downloads it"
    }

    static func reportedError(_ error: Error, onWorker: Bool) -> Error {
        guard onWorker, error is URLError || error is NativChatError else { return error }
        if case NativChatError.httpStatus = error { return error }
        if case NativChatError.serverError = error { return error }
        return ChatSpawnAgentWorkerError.stopped(error.localizedDescription)
    }
}

enum ChatSpawnAgentWorkerError: LocalizedError {
    case stopped(String)

    var errorDescription: String? {
        switch self {
        case .stopped(let detail): "The worker server stopped responding (\(detail)). The next worker spawn restarts it."
        }
    }
}
