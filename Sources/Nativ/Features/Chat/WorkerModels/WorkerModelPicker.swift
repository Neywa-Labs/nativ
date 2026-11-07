import Foundation

struct WorkerPickEnvironment: Sendable {
    let catalog: WorkerModelCatalog
    let downloadedRepoIDs: Set<String>
    let budgetBytes: Int64
    let contextTokens: Int
    let bandwidthGBps: Double
    var excludedRepoIDs: Set<String> = []
}

struct WorkerCandidate: Equatable, Sendable {
    let repoID: String
    let baseID: String
    let category: String
    let estimatedQuality: Double
    let estimatedTokensPerSecond: Double
    let speed: WorkerSpeedBucket
    let sizeBytes: Int64
    let downloads: Int
    let isDownloaded: Bool
    let sources: [WorkerScoreSource]
}

struct WorkerPick: Equatable, Sendable {
    let category: String
    let recommended: WorkerCandidate?
    let runnable: WorkerCandidate?
    let runnableIsFallback: Bool
    var blockedByMemory: Bool = false
}

struct WorkerSubtask: Codable, Equatable, Sendable {
    let id: String
    let category: String
}

struct WorkerSharedSetModel: Equatable, Sendable {
    let candidate: WorkerCandidate
    let subtaskIDs: [String]
    let qualityBySubtask: [String: Double]
}

struct WorkerSharedSet: Equatable, Sendable {
    let models: [WorkerSharedSetModel]
    let uncoveredSubtaskIDs: [String]
}

enum WorkerModelPicker {
    static let generalCategory = "general"

    static func normalizedCategory(_ raw: String, catalog: WorkerModelCatalog) -> String {
        let category = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return catalog.categories.contains(category) ? category : generalCategory
    }

    static func candidates(category: String, environment: WorkerPickEnvironment) -> [WorkerCandidate] {
        let tunables = environment.catalog.estimates
        var result: [WorkerCandidate] = []
        for base in environment.catalog.models {
            guard let score = base.scores[category] else { continue }
            for variant in base.variants
            where variant.supportsTools && !environment.excludedRepoIDs.contains(variant.repoID) {
                guard WorkerModelEstimator.fits(
                    sizeBytes: variant.sizeBytes,
                    kvBytesPerToken: base.kvBytesPerToken,
                    contextTokens: environment.contextTokens,
                    budgetBytes: environment.budgetBytes
                ) else { continue }
                let quality = WorkerModelEstimator.estimatedQuality(
                    score: score.score,
                    bits: variant.bits,
                    totalParams: base.totalParams,
                    tunables: tunables
                )
                let tokensPerSecond = WorkerModelEstimator.estimatedTokensPerSecond(
                    activeParams: base.activeParams,
                    bits: variant.bits,
                    bandwidthGBps: environment.bandwidthGBps,
                    efficiency: tunables.bandwidthEfficiency
                )
                let speed = WorkerModelEstimator.speedBucket(
                    tokensPerSecond: tokensPerSecond, floors: tunables.speedBucketFloors)
                guard speed == .superFast || speed == .fast else { continue }
                result.append(WorkerCandidate(
                    repoID: variant.repoID,
                    baseID: base.baseID,
                    category: category,
                    estimatedQuality: quality,
                    estimatedTokensPerSecond: tokensPerSecond,
                    speed: speed,
                    sizeBytes: variant.sizeBytes,
                    downloads: variant.downloads,
                    isDownloaded: environment.downloadedRepoIDs.contains(variant.repoID),
                    sources: score.sources
                ))
            }
        }
        return result
    }

    static func choose(_ candidates: [WorkerCandidate]) -> WorkerCandidate? {
        candidates.min { lhs, rhs in
            if lhs.estimatedQuality != rhs.estimatedQuality { return lhs.estimatedQuality > rhs.estimatedQuality }
            return isPreferred(lhs, over: rhs)
        }
    }

    static func pick(category rawCategory: String, environment: WorkerPickEnvironment) -> WorkerPick {
        let category = normalizedCategory(rawCategory, catalog: environment.catalog)
        let all = candidates(category: category, environment: environment)
        let general = category == generalCategory
            ? all : candidates(category: generalCategory, environment: environment)

        let recommended = choose(all) ?? choose(general)
        if let runnable = choose(all.filter(\.isDownloaded)) {
            return WorkerPick(category: category, recommended: recommended, runnable: runnable, runnableIsFallback: false)
        }
        let fallback = category == generalCategory ? nil : choose(general.filter(\.isDownloaded))
        return WorkerPick(
            category: category,
            recommended: recommended,
            runnable: fallback,
            runnableIsFallback: fallback != nil,
            blockedByMemory: fallback == nil && hasDownloadedCandidatesIgnoringMemory(category, environment)
        )
    }

    private static func hasDownloadedCandidatesIgnoringMemory(
        _ category: String, _ environment: WorkerPickEnvironment
    ) -> Bool {
        let unlimited = WorkerPickEnvironment(
            catalog: environment.catalog,
            downloadedRepoIDs: environment.downloadedRepoIDs,
            budgetBytes: .max / 2,
            contextTokens: environment.contextTokens,
            bandwidthGBps: environment.bandwidthGBps,
            excludedRepoIDs: environment.excludedRepoIDs
        )
        return [category, generalCategory].contains { name in
            candidates(category: name, environment: unlimited).contains(where: \.isDownloaded)
        }
    }

    static func sharedSet(subtasks: [WorkerSubtask], environment: WorkerPickEnvironment) -> WorkerSharedSet {
        var shortlists: [String: [String: WorkerCandidate]] = [:]
        var remaining: [String] = []
        var uncovered: [String] = []
        var cache: [String: [WorkerCandidate]] = [:]

        func pool(_ category: String) -> [WorkerCandidate] {
            if let cached = cache[category] { return cached }
            let result = candidates(category: category, environment: environment)
            cache[category] = result
            return result
        }

        var seen = Set<String>()
        for subtask in subtasks where seen.insert(subtask.id).inserted {
            let category = normalizedCategory(subtask.category, catalog: environment.catalog)
            var choices = pool(category)
            if choices.isEmpty, category != generalCategory {
                choices = pool(generalCategory)
            }
            guard let best = choices.map(\.estimatedQuality).max() else {
                uncovered.append(subtask.id)
                continue
            }
            var shortlist: [String: WorkerCandidate] = [:]
            for candidate in choices where candidate.estimatedQuality == best {
                shortlist[candidate.repoID] = candidate
            }
            shortlists[subtask.id] = shortlist
            remaining.append(subtask.id)
        }

        var models: [WorkerSharedSetModel] = []
        while !remaining.isEmpty {
            var covers: [String: [String]] = [:]
            var representative: [String: WorkerCandidate] = [:]
            for id in remaining {
                for (repoID, candidate) in shortlists[id] ?? [:] {
                    covers[repoID, default: []].append(id)
                    if representative[repoID] == nil { representative[repoID] = candidate }
                }
            }
            guard let chosen = covers.keys.min(by: { lhs, rhs in
                let left = covers[lhs]!.count, right = covers[rhs]!.count
                if left != right { return left > right }
                let leftDownloaded = representative[lhs]!.isDownloaded, rightDownloaded = representative[rhs]!.isDownloaded
                if leftDownloaded != rightDownloaded { return leftDownloaded }
                return isPreferred(representative[lhs]!, over: representative[rhs]!)
            }) else { break }
            let ids = covers[chosen]!
            models.append(WorkerSharedSetModel(
                candidate: representative[chosen]!,
                subtaskIDs: ids,
                qualityBySubtask: Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                    shortlists[id]?[chosen].map { (id, $0.estimatedQuality) }
                })
            ))
            remaining.removeAll { ids.contains($0) }
        }
        return WorkerSharedSet(models: models, uncoveredSubtaskIDs: uncovered)
    }

    private static func isPreferred(_ lhs: WorkerCandidate, over rhs: WorkerCandidate) -> Bool {
        if lhs.estimatedTokensPerSecond != rhs.estimatedTokensPerSecond {
            return lhs.estimatedTokensPerSecond > rhs.estimatedTokensPerSecond
        }
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes < rhs.sizeBytes }
        if lhs.downloads != rhs.downloads { return lhs.downloads > rhs.downloads }
        return lhs.repoID < rhs.repoID
    }
}
