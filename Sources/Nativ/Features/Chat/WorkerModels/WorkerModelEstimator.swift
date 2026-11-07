import Foundation

enum WorkerSpeedBucket: String, Codable, Sendable {
    case superFast = "super fast"
    case fast
    case slow
    case superSlow = "super slow"
}

/// Estimates from published quantization studies and memory bandwidth, not measurements.
enum WorkerModelEstimator {
    static func quantizationPenalty(
        bits: Double,
        totalParams: Double,
        tunables: WorkerEstimateTunables
    ) -> Double {
        if bits >= 8 { return tunables.penaltyHighBit }
        if bits >= 6 { return tunables.penaltySixBit }
        var penalty = tunables.fourBitPenalties.first { bucket in
            guard let maxParams = bucket.maxParams else { return true }
            return totalParams < maxParams
        }?.penalty ?? 0
        if bits <= 3 { penalty *= tunables.lowBitFactor }
        return penalty
    }

    static func estimatedQuality(
        score: Double,
        bits: Double,
        totalParams: Double,
        tunables: WorkerEstimateTunables
    ) -> Double {
        score * (1 - quantizationPenalty(bits: bits, totalParams: totalParams, tunables: tunables) / 100)
    }

    /// Decode is memory-bandwidth bound: each token reads the active weights once.
    static func estimatedTokensPerSecond(
        activeParams: Double,
        bits: Double,
        bandwidthGBps: Double,
        efficiency: Double
    ) -> Double {
        let gigabytesPerToken = activeParams * bits / 8
        guard gigabytesPerToken > 0 else { return 0 }
        return bandwidthGBps * efficiency / gigabytesPerToken
    }

    static func speedBucket(tokensPerSecond: Double, floors: [Double]) -> WorkerSpeedBucket {
        let buckets: [WorkerSpeedBucket] = [.superFast, .fast, .slow]
        for (bucket, floor) in zip(buckets, floors) where tokensPerSecond >= floor {
            return bucket
        }
        return .superSlow
    }

    static func fits(sizeBytes: Int64, kvBytesPerToken: Int64, contextTokens: Int, budgetBytes: Int64) -> Bool {
        sizeBytes + kvBytesPerToken * Int64(contextTokens) <= budgetBytes
    }
}

enum AppleSiliconBandwidth {
    private static let table: [String: Double] = [
        "M1": 68, "M1 Pro": 200, "M1 Max": 400, "M1 Ultra": 800,
        "M2": 100, "M2 Pro": 200, "M2 Max": 400, "M2 Ultra": 800,
        "M3": 100, "M3 Pro": 150, "M3 Max": 400, "M3 Ultra": 819,
        "M4": 120, "M4 Pro": 273, "M4 Max": 546,
        "M5": 153, "M5 Pro": 307, "M5 Max": 614,
    ]

    static func gigabytesPerSecond(chipName: String) -> Double {
        guard let match = chipName.firstMatch(of: /M(\d)(?:\s+(Pro|Max|Ultra))?/) else { return 100 }
        let key = match.2.map { "M\(match.1) \($0)" } ?? "M\(match.1)"
        return table[key] ?? 100
    }
}

enum WorkerMemoryBudget {
    static let fallbackKVBytesPerToken: Int64 = 147_456
    static let fallbackContextTokens = 32_768

    static func workerBudgetBytes(
        workingSetBytes: Int64,
        managerWeightsBytes: Int64,
        managerKVBytesPerToken: Int64?,
        managerContextTokens: Int?
    ) -> Int64 {
        let kv = (managerKVBytesPerToken ?? fallbackKVBytesPerToken)
            * Int64(managerContextTokens ?? fallbackContextTokens)
        return max(0, workingSetBytes - managerWeightsBytes - kv)
    }
}

extension AppleSiliconBandwidth {
    static func currentChipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
