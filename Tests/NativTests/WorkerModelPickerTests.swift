import XCTest

final class WorkerModelPickerTests: XCTestCase {
    private func base(
        _ repo: String, params: Double, scores: [String: Double], tools: Bool = true
    ) -> WorkerBaseModel {
        WorkerBaseModel(
            baseID: repo, totalParams: params, activeParams: params, kvBytesPerToken: 100_000,
            modality: "text",
            scores: scores.mapValues { WorkerCategoryScore(score: $0, sources: []) },
            variants: [WorkerVariant(
                repoID: repo, bits: 4, sizeBytes: Int64(params * 500_000_000), downloads: 1,
                supportsTools: tools)]
        )
    }

    private func catalog(_ models: [WorkerBaseModel], categories: [String] = ["coding", "writing", "general"])
        -> WorkerModelCatalog
    {
        WorkerModelCatalog(
            version: 1, generated: "test", categories: categories, attribution: [], estimates: .default,
            models: models)
    }

    private func environment(
        _ catalog: WorkerModelCatalog, downloaded: Set<String>, budget: Int64 = 100_000_000_000,
        excluded: Set<String> = []
    ) -> WorkerPickEnvironment {
        WorkerPickEnvironment(
            catalog: catalog, downloadedRepoIDs: downloaded, budgetBytes: budget, contextTokens: 8192,
            bandwidthGBps: 120, excludedRepoIDs: excluded)
    }

    // After the 4-bit loss: A 71.04 at ~36 tok/s, B 67.16 at ~85 tok/s, C 51. D is general only; E has no tools.
    private lazy var fixture = catalog([
        base("A", params: 4, scores: ["coding": 74]),
        base("B", params: 1.7, scores: ["coding": 73]),
        base("C", params: 0.6, scores: ["coding": 60]),
        base("D", params: 4, scores: ["general": 60]),
        base("E", params: 4, scores: ["coding": 90], tools: false),
    ])

    private func pick(_ category: String, downloaded: Set<String>, budget: Int64 = 100_000_000_000) -> WorkerPick {
        WorkerModelPicker.pick(category: category, environment: environment(fixture, downloaded: downloaded, budget: budget))
    }

    func testBestScoringFastModelWins() {
        XCTAssertEqual(pick("coding", downloaded: []).recommended?.repoID, "A")
    }

    func testEqualScoresGoToTheFasterModel() {
        let even = catalog([
            base("Slower", params: 4, scores: ["coding": 74]),
            base("Faster", params: 3, scores: ["coding": 74]),
        ])
        XCTAssertEqual(
            WorkerModelPicker.pick(category: "coding", environment: environment(even, downloaded: [])).recommended?.repoID,
            "Faster")
    }

    func testModelWithoutTheCategoryTestIsNotRecommendedThere() {
        XCTAssertFalse(WorkerModelPicker.candidates(
            category: "coding", environment: environment(fixture, downloaded: ["D"])).contains { $0.repoID == "D" })
        let result = pick("coding", downloaded: ["D"])
        XCTAssertEqual(result.recommended?.repoID, "A")
        XCTAssertEqual(result.runnable?.repoID, "D")
        XCTAssertTrue(result.runnableIsFallback)
    }

    func testSlowModelsAreNeverPicked() {
        let mixed = catalog([
            base("Big", params: 8, scores: ["coding": 95]),
            base("Small", params: 4, scores: ["coding": 74]),
        ])
        let result = WorkerModelPicker.pick(category: "coding", environment: environment(mixed, downloaded: ["Big"]))
        XCTAssertEqual(result.recommended?.repoID, "Small")
        XCTAssertNil(result.runnable)
        XCTAssertFalse(result.blockedByMemory)
        XCTAssertFalse(WorkerModelPicker.candidates(
            category: "coding", environment: environment(mixed, downloaded: [])).contains { $0.repoID == "Big" })
    }

    func testSharedSetPrefersFastModels() {
        let mixed = catalog([
            base("Big", params: 8, scores: ["coding": 95]),
            base("Small", params: 4, scores: ["coding": 74]),
        ])
        let set = WorkerModelPicker.sharedSet(
            subtasks: [WorkerSubtask(id: "1", category: "coding")], environment: environment(mixed, downloaded: []))
        XCTAssertEqual(set.models.map(\.candidate.repoID), ["Small"])
    }

    func testManagerModelIsNeverAWorker() {
        let result = WorkerModelPicker.pick(
            category: "coding", environment: environment(fixture, downloaded: ["A", "C"], excluded: ["A", "B"]))
        XCTAssertEqual(result.runnable?.repoID, "C")
        XCTAssertEqual(result.recommended?.repoID, "C")
        let set = WorkerModelPicker.sharedSet(
            subtasks: [WorkerSubtask(id: "1", category: "coding")],
            environment: environment(fixture, downloaded: [], excluded: ["A", "B"]))
        XCTAssertEqual(set.models.map(\.candidate.repoID), ["C"])
        XCTAssertFalse(WorkerModelPicker.pick(
            category: "coding", environment: environment(fixture, downloaded: ["A"], budget: 1, excluded: ["A"])
        ).blockedByMemory)
    }

    func testRunnableComesFromDownloadedOnly() {
        let result = pick("coding", downloaded: ["C"])
        XCTAssertEqual(result.recommended?.repoID, "A")
        XCTAssertEqual(result.runnable?.repoID, "C")
        XCTAssertFalse(result.runnableIsFallback)
        XCTAssertEqual(result.runnable?.isDownloaded, true)
    }

    func testFallsBackToBestDownloadedGeneral() {
        let result = pick("writing", downloaded: ["D"])
        XCTAssertEqual(result.runnable?.repoID, "D")
        XCTAssertTrue(result.runnableIsFallback)
    }

    func testNothingDownloadedMeansNoRunnable() {
        XCTAssertNil(pick("coding", downloaded: []).runnable)
    }

    func testToolLessModelsAreNeverCandidates() throws {
        let candidates = WorkerModelPicker.candidates(
            category: "coding", environment: environment(fixture, downloaded: []))
        XCTAssertFalse(candidates.contains { $0.repoID == "E" })
        XCTAssertEqual(try XCTUnwrap(candidates.first { $0.repoID == "A" }?.estimatedQuality), 71.04, accuracy: 0.001)
    }

    func testModelsThatDontFitAreSkipped() {
        XCTAssertNil(pick("coding", downloaded: ["A", "B", "C"], budget: 1).runnable)
    }

    func testUnknownCategoryBecomesGeneral() {
        XCTAssertEqual(WorkerModelPicker.normalizedCategory("Cyber", catalog: fixture), "general")
        XCTAssertEqual(WorkerModelPicker.normalizedCategory(" Coding ", catalog: fixture), "coding")
        XCTAssertEqual(pick("cyber", downloaded: ["D"]).category, "general")
    }

    func testSharedSetReusesTheBestModelAcrossCategories() throws {
        let shared = catalog([
            base("M", params: 4, scores: ["coding": 80, "writing": 80, "general": 80]),
            base("X", params: 4, scores: ["coding": 85]),
        ])
        let set = WorkerModelPicker.sharedSet(
            subtasks: [("1", "coding"), ("2", "coding"), ("3", "writing"), ("4", "writing"), ("5", "general")]
                .map { WorkerSubtask(id: $0.0, category: $0.1) },
            environment: environment(shared, downloaded: []))
        XCTAssertEqual(set.models.count, 2)
        let byModel = Dictionary(uniqueKeysWithValues: set.models.map { ($0.candidate.repoID, $0.subtaskIDs.sorted()) })
        XCTAssertEqual(byModel["X"], ["1", "2"])
        XCTAssertEqual(byModel["M"], ["3", "4", "5"])
        XCTAssertEqual(
            try XCTUnwrap(set.models.first { $0.candidate.repoID == "M" }?.qualityBySubtask["3"]), 76.8, accuracy: 0.001)
        XCTAssertTrue(set.uncoveredSubtaskIDs.isEmpty)
    }

    func testSharedSetUsesTwoModelsWhenNoneCoversAll() {
        let split = catalog([
            base("X", params: 4, scores: ["coding": 85]),
            base("Y", params: 4, scores: ["writing": 85]),
        ])
        let set = WorkerModelPicker.sharedSet(
            subtasks: [WorkerSubtask(id: "1", category: "coding"), WorkerSubtask(id: "2", category: "writing")],
            environment: environment(split, downloaded: []))
        XCTAssertEqual(Set(set.models.map(\.candidate.repoID)), ["X", "Y"])
    }

    func testSharedSetFallsBackToGeneral() {
        let set = WorkerModelPicker.sharedSet(
            subtasks: [WorkerSubtask(id: "1", category: "coding"), WorkerSubtask(id: "9", category: "vision")],
            environment: environment(catalog(fixture.models, categories: ["coding", "vision", "general"]), downloaded: []))
        XCTAssertTrue(set.uncoveredSubtaskIDs.isEmpty)
        XCTAssertTrue(set.models.contains { $0.candidate.repoID == "D" && $0.subtaskIDs == ["9"] })
    }

    func testSharedSetReportsUncoveredOnlyWithoutGeneral() {
        let codingOnly = catalog([base("A", params: 4, scores: ["coding": 74])], categories: ["coding", "vision", "general"])
        let set = WorkerModelPicker.sharedSet(
            subtasks: [WorkerSubtask(id: "1", category: "coding"), WorkerSubtask(id: "9", category: "vision")],
            environment: environment(codingOnly, downloaded: []))
        XCTAssertEqual(set.uncoveredSubtaskIDs, ["9"])
    }

    func testSharedSetHandlesDuplicateSubtaskIDs() {
        let set = WorkerModelPicker.sharedSet(
            subtasks: [WorkerSubtask(id: "a", category: "coding"), WorkerSubtask(id: "a", category: "coding")],
            environment: environment(fixture, downloaded: []))
        XCTAssertEqual(set.models.count, 1)
        XCTAssertEqual(set.models.first?.subtaskIDs, ["a"])
    }

    func testPickReportsWorkersBlockedByMemory() {
        XCTAssertTrue(pick("coding", downloaded: ["A"], budget: 1).blockedByMemory)
        XCTAssertFalse(pick("coding", downloaded: [], budget: 1).blockedByMemory)
        XCTAssertFalse(pick("coding", downloaded: ["A"]).blockedByMemory)
    }

    func testRowsCoverEveryCatalogCategory() {
        let rows = WorkerSettingsTable.rows(environment: environment(fixture, downloaded: ["C"]))
        XCTAssertEqual(rows.map(\.category), ["coding", "writing", "general"])
        XCTAssertEqual(rows[0].recommended?.repoID, "A")
        XCTAssertEqual(rows[0].runnable?.repoID, "C")
    }

    func testMemoryHintWhenDownloadedWorkersDontFit() {
        let blocked = WorkerSettingsTable.rows(environment: environment(fixture, downloaded: ["A", "D"], budget: 1))
        XCTAssertTrue(WorkerSettingsTable.needsMemoryHint(rows: blocked))
        let nothingDownloaded = WorkerSettingsTable.rows(environment: environment(fixture, downloaded: [], budget: 1))
        XCTAssertFalse(WorkerSettingsTable.needsMemoryHint(rows: nothingDownloaded))
        let fits = WorkerSettingsTable.rows(environment: environment(fixture, downloaded: ["A", "D"]))
        XCTAssertFalse(WorkerSettingsTable.needsMemoryHint(rows: fits))
    }

    func testMemoryHintNamesTheContextWindowSetting() {
        XCTAssertEqual(
            WorkerSettingsTable.memoryHint(managerContextIsModelDefault: true),
            "Your main model's Context window is set to model default, which reserves memory for its full context. Set it to 8192 or 32768 in Model Configuration to make room for workers.")
        XCTAssertEqual(
            WorkerSettingsTable.memoryHint(managerContextIsModelDefault: false),
            "Your downloaded workers don't fit next to the main model. Lower its Context window in Model Configuration, or lower Worker context here.")
    }
}
