import Foundation
import NativServerKit

enum ChatSuggestWorkersToolRegistry {
    static let toolName = "suggest_workers"

    static func definition(categories: [String]) -> MLXChatToolDefinition {
        MLXChatToolDefinition(function: MLXChatFunctionDefinition(
            name: toolName,
            description: "After planning, list your sub-tasks with a category each. Returns the fewest worker models that cover them, and which ones the user still needs to download. Tell the user about any downloads, then call spawn_agent with each sub-task's category.",
            parameters: .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "subtasks": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "properties": .object([
                                "id": .object([
                                    "type": .string("string"),
                                    "description": .string("Your short label for the sub-task.")
                                ]),
                                "category": .object([
                                    "type": .string("string"),
                                    "enum": .array(categories.map { .string($0) })
                                ])
                            ]),
                            "required": .array([.string("id"), .string("category")])
                        ])
                    ])
                ]),
                "required": .array([.string("subtasks")])
            ])
        ))
    }
}

enum ChatSuggestWorkersToolError: LocalizedError {
    case disabled
    case invalidArguments

    var errorDescription: String? {
        switch self {
        case .disabled: "Worker sub-agents are turned off in Settings."
        case .invalidArguments: "suggest_workers needs a subtasks array of {id, category}."
        }
    }
}

struct ChatSuggestWorkersToolResultPayload: Encodable {
    struct Model: Encodable {
        let model: String
        let downloaded: Bool
        let sizeGB: Double
        let estSpeed: String
        let subtasks: [String]
        let estQuality: [String: Int]

        enum CodingKeys: String, CodingKey {
            case model, downloaded, subtasks
            case sizeGB = "size_gb"
            case estSpeed = "est_speed"
            case estQuality = "est_quality"
        }
    }

    let ok: Bool
    let models: [Model]
    let uncovered: [String]
    let error: String?
}

struct ChatSuggestWorkersToolExecutor {
    private struct Arguments: Decodable {
        let subtasks: [WorkerSubtask]
    }

    func execute(call: MLXChatToolCall, context: ChatToolExecutionContext) async throws -> String {
        guard let routing = context.workerRouting else { throw ChatSuggestWorkersToolError.disabled }
        guard let data = call.function?.arguments?.data(using: .utf8),
              let arguments = try? JSONDecoder().decode(Arguments.self, from: data)
        else {
            throw ChatSuggestWorkersToolError.invalidArguments
        }
        let set = WorkerModelPicker.sharedSet(subtasks: arguments.subtasks, environment: await routing.environment())
        let models = set.models.map { entry in
            ChatSuggestWorkersToolResultPayload.Model(
                model: entry.candidate.repoID,
                downloaded: entry.candidate.isDownloaded,
                sizeGB: (Double(entry.candidate.sizeBytes) / 100_000_000).rounded() / 10,
                estSpeed: entry.candidate.speed.rawValue,
                subtasks: entry.subtaskIDs,
                estQuality: entry.qualityBySubtask.mapValues { Int($0.rounded()) }
            )
        }
        return try encoded(ChatSuggestWorkersToolResultPayload(
            ok: true, models: models, uncovered: set.uncoveredSubtaskIDs, error: nil))
    }

    func failurePayload(error: Error) -> String {
        (try? encoded(ChatSuggestWorkersToolResultPayload(
            ok: false, models: [], uncovered: [], error: error.localizedDescription)))
            ?? #"{"ok":false,"error":"suggest_workers failed."}"#
    }

    private func encoded(_ payload: ChatSuggestWorkersToolResultPayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }
}

enum ChatWorkerToolSchema {
    static func apply(
        to definitions: [MLXChatToolDefinition],
        enabled: Bool,
        categories: [String]
    ) -> [MLXChatToolDefinition] {
        guard enabled,
              let index = definitions.firstIndex(where: { $0.function.name == ChatSpawnAgentToolRegistry.toolName })
        else {
            return definitions
        }
        var result = definitions
        result[index] = ChatSpawnAgentToolRegistry.definitions(workerCategories: categories)[0]
        result.append(ChatSuggestWorkersToolRegistry.definition(categories: categories))
        return result
    }
}
