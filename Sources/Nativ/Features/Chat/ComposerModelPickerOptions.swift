enum ComposerSpeedMethod: String {
    case mtp, eagle3, dflash, dflash2, dspark, other

    init(kind: String?, modelType: String? = nil) {
        let type = modelType?.lowercased() ?? ""
        self = type.contains("dflash2") ? .dflash2 : type.contains("dspark")
            ? .dspark : Self(rawValue: kind ?? "") ?? .other
    }

    var rank: Int { self == .dflash2 ? 2 : self == .dflash || self == .dspark ? 1 : 0 }
    var tier: String { ["Fast", "Turbo", "Turbo+"][rank] }
    var label: String { self == .other ? "" : rawValue.uppercased() }
    var detail: String {
        switch self {
        case .mtp: "Multi-token prediction"
        case .eagle3: "EAGLE3 speculative decoding"
        case .dflash: "DFlash speculative decoding"
        case .dflash2: "DFlash 2 speculative decoding"
        case .dspark: "DSpark speculative decoding"
        case .other: "Speculative decoding"
        }
    }
}

struct ComposerModelPickerSecondaryOption: Identifiable {
    let id: String
    let title: String
    let detail: String
    var speedMethod: ComposerSpeedMethod? = nil
    var isEnabled = true

    static func speedOptions(
        drafters: [LocalModel], activeID: String, activeKind: String, target: LocalModel? = nil
    ) -> [Self] {
        var candidates = drafters.map { model in
            let method = ComposerSpeedMethod(kind: model.drafterKind, modelType: model.drafterModelType)
            return Self(id: model.repoID, title: method.tier, detail: method.detail, speedMethod: method)
        }
        if let target, target.hasBuiltInMTP {
            candidates.insert(Self(id: target.repoID, title: "Fast", detail: "Built-in multi-token prediction",
                                   speedMethod: .mtp), at: 0)
        }
        let preferred: [(String, ComposerSpeedMethod)] =
            target.map { DrafterModelCompatibility.discoveryQuery(for: $0.repoID).lowercased() } == "qwen3.8-27b"
            ? [("RedHatAI/Qwen3.8-27B-speculator.dspark", .dspark), ("incoai/Qwen3.8-27B-DFlash2", .dflash2)] : []
        for (repoID, method) in preferred where !candidates.contains(where: { $0.id == repoID }) {
            candidates.append(Self(id: repoID, title: method.tier, detail: "\(method.detail) · Download required",
                                   speedMethod: method, isEnabled: false))
        }
        if !activeID.isEmpty, !candidates.contains(where: { $0.id == activeID }) {
            let method = ComposerSpeedMethod(kind: activeKind)
            candidates.append(Self(id: activeID, title: method.tier, detail: "Draft model unavailable",
                                   speedMethod: method, isEnabled: false))
        }
        // Keep the active drafter when multiple installed models provide the same tier.
        func priority(_ option: Self) -> Int {
            (option.id == activeID ? 100 : 0) + (option.isEnabled ? 10 : 0)
                + (target?.hasBuiltInMTP == true && option.id == target?.repoID ? 2 : 0)
                + (preferred.contains { $0.0 == option.id } ? 1 : 0)
        }
        var tiers: [Int: Self] = [:]
        for option in candidates.sorted(by: { $0.id < $1.id }) {
            let rank = option.speedMethod?.rank ?? 0
            if tiers[rank].map({ priority($0) < priority(option) }) ?? true { tiers[rank] = option }
        }
        return [Self(id: "", title: "Off", detail: "Standard decoding")]
            + tiers.keys.sorted().compactMap { tiers[$0] }
    }
}

struct ComposerModelPickerSecondarySection: Identifiable {
    let id: String
    let title: String
    let selectedID: String
    let selectedLabel: String
    let options: [ComposerModelPickerSecondaryOption]
    let statusTitle: String?
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onSelect: (String) -> Void

    var selectedOption: ComposerModelPickerSecondaryOption? {
        options.first { $0.id == selectedID }
    }

    var speedToggleOption: ComposerModelPickerSecondaryOption? {
        selectedID.isEmpty ? options.first { !$0.id.isEmpty && $0.isEnabled }
            : options.first { $0.id.isEmpty }
    }

    init(
        id: String,
        title: String,
        selectedID: String,
        selectedLabel: String,
        options: [ComposerModelPickerSecondaryOption],
        statusTitle: String? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil,
        onSelect: @escaping (String) -> Void
    ) {
        self.id = id
        self.title = title
        self.selectedID = selectedID
        self.selectedLabel = selectedLabel
        self.options = options
        self.statusTitle = statusTitle
        self.actionTitle = actionTitle
        self.onAction = onAction
        self.onSelect = onSelect
    }
}
