import XCTest

final class WorkerModelCatalogTests: XCTestCase {
    func testCorruptDataLoadsEmptyCatalog() {
        XCTAssertEqual(WorkerModelCatalog.load(from: Data("nope".utf8)), .empty)
        XCTAssertEqual(WorkerModelCatalog.empty.categories, ["general"])
        XCTAssertTrue(WorkerModelCatalog.empty.models.isEmpty)
    }

    func testBundledCatalogDecodesAndHasGeneral() {
        XCTAssertTrue(WorkerModelCatalog.bundled.categories.contains("general"))
        XCTAssertFalse(WorkerModelCatalog.bundled.models.isEmpty)
    }

    func testBundledCatalogUsesOneTestPerCategory() {
        var testsByCategory: [String: Set<String>] = [:]
        for model in WorkerModelCatalog.bundled.models {
            XCTAssertFalse(model.scores.isEmpty, "\(model.baseID) has no score, so it shouldn't be in the catalog")
            for (category, score) in model.scores {
                XCTAssertEqual(score.sources.count, 1, "\(model.baseID) \(category)")
                XCTAssertTrue((0...100).contains(score.score), "\(model.baseID) \(category) \(score.score)")
                testsByCategory[category, default: []].formUnion(score.sources.map(\.benchmark))
            }
        }
        XCTAssertEqual(testsByCategory.keys.sorted(), WorkerModelCatalog.bundled.categories.sorted())
        XCTAssertEqual(WorkerModelCatalog.bundled.categories.count, 7)
        for (category, tests) in testsByCategory {
            XCTAssertEqual(tests.count, 1, "\(category) uses \(tests.sorted())")
        }
    }

    func testBundledScoresAreTheLeaderboardMarks() throws {
        let k2 = try XCTUnwrap(WorkerModelCatalog.bundled.models.first { $0.baseID == "IFM/K2-Horizon-3.7B" })
        XCTAssertEqual(k2.scores["general"]?.score, k2.scores["general"]?.sources.first?.raw)
        XCTAssertEqual(k2.scores["coding"]?.score, k2.scores["coding"]?.sources.first?.raw)
        let raw = try XCTUnwrap(k2.scores["knowledge"]?.sources.first?.raw)
        XCTAssertEqual(try XCTUnwrap(k2.scores["knowledge"]?.score), raw * 100, accuracy: 0.01)
    }

    func testDefaultTunablesMatchSpec() {
        let tunables = WorkerEstimateTunables.default
        XCTAssertEqual(tunables.bandwidthEfficiency, 0.6)
        XCTAssertEqual(tunables.speedBucketFloors, [80, 30, 10])
        XCTAssertEqual(tunables.penaltyHighBit, 0.5)
        XCTAssertEqual(tunables.penaltySixBit, 1)
        XCTAssertEqual(tunables.fourBitPenalties.map(\.penalty), [15, 8, 4, 2, 1])
        XCTAssertEqual(tunables.fourBitPenalties.map(\.maxParams), [1, 2, 5, 15, nil])
        XCTAssertEqual(tunables.lowBitFactor, 2)
    }

    func testDecodesGeneratorShape() throws {
        let json = """
        {"version":1,"generated":"2026-11-03","categories":["general","coding"],"attribution":["x"],
         "estimates":{"bandwidthEfficiency":0.6,"speedBucketFloors":[80,30,10],"penaltyHighBit":0.5,
           "penaltySixBit":1,"fourBitPenalties":[{"maxParams":1,"penalty":15},{"maxParams":null,"penalty":1}],
           "lowBitFactor":2},
         "models":[{"baseID":"Qwen/Qwen3-4B","totalParams":4,"activeParams":4,"kvBytesPerToken":147456,
           "modality":"text","scores":{"general":{"score":61.5,"sources":[{"benchmark":"index","raw":61.5,"source":"s","url":null}]}},
           "variants":[{"repoID":"mlx-community/Qwen3-4B-4bit","bits":4,"sizeBytes":2260000000,
             "downloads":10,"supportsTools":true}]}]}
        """
        let catalog = WorkerModelCatalog.load(from: Data(json.utf8))
        XCTAssertEqual(catalog.models.first?.variants.first?.repoID, "mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(catalog.models.first?.scores["general"]?.score, 61.5)
        XCTAssertNil(catalog.estimates.fourBitPenalties.last?.maxParams)
    }
}
