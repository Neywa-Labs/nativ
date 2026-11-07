import Foundation

struct WorkerSettingsRow: Equatable, Sendable {
    let category: String
    let recommended: WorkerCandidate?
    let runnable: WorkerCandidate?
    var blockedByMemory: Bool = false
}

enum WorkerSettingsTable {
    static func rows(environment: WorkerPickEnvironment) -> [WorkerSettingsRow] {
        environment.catalog.categories.map { category in
            let pick = WorkerModelPicker.pick(category: category, environment: environment)
            return WorkerSettingsRow(
                category: category,
                recommended: pick.recommended,
                runnable: pick.runnable,
                blockedByMemory: pick.blockedByMemory
            )
        }
    }

    static func memoryHint(managerContextIsModelDefault: Bool) -> String {
        managerContextIsModelDefault
            ? "Your main model's Context window is set to model default, which reserves memory for its full context. Set it to 8192 or 32768 in Model Configuration to make room for workers."
            : "Your downloaded workers don't fit next to the main model. Lower its Context window in Model Configuration, or lower Worker context here."
    }

    static func needsMemoryHint(rows: [WorkerSettingsRow]) -> Bool {
        rows.allSatisfy { $0.runnable == nil } && rows.contains(where: \.blockedByMemory)
    }
}
