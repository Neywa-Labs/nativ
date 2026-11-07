import XCTest

final class WorkerModelEstimatorTests: XCTestCase {
    private let tunables = WorkerEstimateTunables.default

    private func penalty(_ bits: Double, _ params: Double) -> Double {
        WorkerModelEstimator.quantizationPenalty(bits: bits, totalParams: params, tunables: tunables)
    }

    private func quality(score: Double, bits: Double, params: Double) -> Double {
        WorkerModelEstimator.estimatedQuality(score: score, bits: bits, totalParams: params, tunables: tunables)
    }

    func testQuantizationPenaltiesArePercentages() {
        XCTAssertEqual(penalty(4, 0.6), 15)
        XCTAssertEqual(penalty(4, 1.7), 8)
        XCTAssertEqual(penalty(4, 4), 4)
        XCTAssertEqual(penalty(4, 8), 2)
        XCTAssertEqual(penalty(4, 30), 1)
        XCTAssertEqual(penalty(8, 4), 0.5)
        XCTAssertEqual(penalty(16, 4), 0.5)
        XCTAssertEqual(penalty(6, 4), 1)
        XCTAssertEqual(penalty(3, 4), 8)
    }

    func testQualityTakesThePenaltyAsAPercentageOfTheScore() {
        XCTAssertEqual(quality(score: 26.1, bits: 4, params: 3.7), 25.056, accuracy: 0.001)
        XCTAssertEqual(quality(score: 35.6, bits: 4, params: 1.7), 32.752, accuracy: 0.001)
        XCTAssertEqual(quality(score: 5.2, bits: 8, params: 1.2), 5.174, accuracy: 0.001)
    }

    func testSpeedBucketsOnM4() {
        let bandwidth = AppleSiliconBandwidth.gigabytesPerSecond(chipName: "Apple M4")
        XCTAssertEqual(bandwidth, 120)
        func bucket(_ active: Double, _ bits: Double) -> WorkerSpeedBucket {
            WorkerModelEstimator.speedBucket(
                tokensPerSecond: WorkerModelEstimator.estimatedTokensPerSecond(
                    activeParams: active, bits: bits, bandwidthGBps: bandwidth, efficiency: 0.6),
                floors: tunables.speedBucketFloors)
        }
        XCTAssertEqual(bucket(1.7, 4), .superFast)
        XCTAssertEqual(bucket(4, 4), .fast)
        XCTAssertEqual(bucket(14, 4), .slow)
        XCTAssertEqual(bucket(70, 4), .superSlow)
        XCTAssertEqual(bucket(3, 4), .fast)
    }

    func testCurrentChipNameReadsThisMac() {
        XCTAssertTrue(AppleSiliconBandwidth.currentChipName().hasPrefix("Apple M"))
    }

    func testUnknownChipFallsBackTo100() {
        XCTAssertEqual(AppleSiliconBandwidth.gigabytesPerSecond(chipName: "Mystery Chip"), 100)
        XCTAssertEqual(AppleSiliconBandwidth.gigabytesPerSecond(chipName: "Apple M4 Max"), 546)
    }

    func testFitAndBudget() {
        XCTAssertTrue(WorkerModelEstimator.fits(
            sizeBytes: 1_000_000_000, kvBytesPerToken: 100_000, contextTokens: 8192, budgetBytes: 2_000_000_000))
        XCTAssertFalse(WorkerModelEstimator.fits(
            sizeBytes: 1_000_000_000, kvBytesPerToken: 100_000, contextTokens: 8192, budgetBytes: 1_500_000_000))
        XCTAssertEqual(
            WorkerMemoryBudget.workerBudgetBytes(
                workingSetBytes: 10_737_418_240, managerWeightsBytes: 2_300_000_000,
                managerKVBytesPerToken: 147_456, managerContextTokens: 8192),
            7_229_458_688)
        XCTAssertEqual(
            WorkerMemoryBudget.workerBudgetBytes(
                workingSetBytes: 10_737_418_240, managerWeightsBytes: 2_300_000_000,
                managerKVBytesPerToken: nil, managerContextTokens: nil),
            3_605_580_032)
        XCTAssertEqual(
            WorkerMemoryBudget.workerBudgetBytes(
                workingSetBytes: 1, managerWeightsBytes: 5, managerKVBytesPerToken: 1, managerContextTokens: 1),
            0)
    }
}
