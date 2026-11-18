import Foundation
import NativServerKit

struct MLXImageModelResolver: Sendable {
    static let shared = MLXImageModelResolver(
        generationModelTypes: (try? Nativ.imageGenerationModelTypes())
            ?? [
                "bonsai", "ernie_image", "flux2", "flux3", "ideogram4",
                "llada_image", "mage_flow", "minimax_h3_image", "moss_image", "qwen_image", "z_image",
            ],
        editingModelTypes: (try? Nativ.imageEditingModelTypes())
            ?? [
                "ernie_image", "flux2", "flux3", "llada_image", "mage_flow",
                "minimax_h3_image", "qwen_image", "z_image",
            ]
    )

    private let generationModelTypes: Set<String>
    private let editingModelTypes: Set<String>

    init(
        generationModelTypes: Set<String>,
        editingModelTypes: Set<String>
    ) {
        self.generationModelTypes = generationModelTypes
        self.editingModelTypes = editingModelTypes
    }

    func isImageGenerationModel(
        model: String,
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let modelType = supportedModelType(
            model: model,
            at: root,
            fileManager: fileManager,
            supportedModelTypes: generationModelTypes
        ) else {
            return false
        }
        return modelType != "mage_flow"
            || !isMageFlowEditModel(
                model: model,
                at: root,
                fileManager: fileManager
            )
    }

    func isImageEditingModel(
        model: String,
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let modelType = supportedModelType(
            model: model,
            at: root,
            fileManager: fileManager,
            supportedModelTypes: editingModelTypes
        ) else {
            return false
        }
        if modelType == "mage_flow" {
            return isMageFlowEditModel(
                model: model,
                at: root,
                fileManager: fileManager
            )
        }
        return true
    }

    func isSupportedImageModel(
        model: String,
        at root: URL,
        fileManager: FileManager
    ) -> Bool {
        supportedModelType(
            model: model,
            at: root,
            fileManager: fileManager,
            supportedModelTypes: generationModelTypes.union(editingModelTypes)
        ) != nil
    }

    static func isKnownImageEditOnlyModelID(_ model: String) -> Bool {
        guard let normalizedName = normalizedModelName(model) else {
            return false
        }
        return normalizedName == "mage_flow_edit"
            || normalizedName.hasPrefix("mage_flow_edit_")
    }

    private func supportedModelType(
        model: String,
        at root: URL,
        fileManager: any ImagePackageFiles,
        supportedModelTypes: Set<String>
    ) -> String? {
        var candidates = localModelTypes(at: root, fileManager: fileManager)
        addModelType(modelType(from: model), to: &candidates)

        for candidate in candidates where supportedModelTypes.contains(candidate) {
            if supportsLocalLayout(
                modelType: candidate,
                at: root,
                fileManager: fileManager
            ) != false {
                return candidate
            }
        }
        return nil
    }

    /// A missing verdict leaves inconclusive packages eligible for download.
    func downloadBlocker(for package: ImageDownloadManifest) -> String? {
        imageCompatibility(for: package).blocker
    }

    func imageCompatibility(for package: ImageDownloadManifest) -> ImagePackageCompatibility {
        let files = RemoteImagePackage(package)
        let root = files.root
        func config(_ path: String) -> [String: Any]? {
            loadJSONObject(at: root.appendingPathComponent(path), fileManager: files)
        }
        let pipeline = config("model_index.json")?["_class_name"] as? String
        let supported = generationModelTypes.union(editingModelTypes)
        if pipeline?.hasPrefix("StableDiffusionXL") == true,
           supported.isDisjoint(with: ["sdxl", "stable_diffusion_xl"]) {
            return .blocked("This is a Stable Diffusion XL (SDXL) pipeline. This Nativ build has no SDXL image backend.")
        }
        if !files.paths.contains("model_index.json"),
           files.paths.contains("transformer/adapter_model.safetensors"),
           !files.paths.contains(where: {
               $0.hasSuffix(".safetensors") && !$0.hasSuffix("adapter_model.safetensors")
                   && !$0.hasPrefix("loras/")
           }),
           let adapter = config("transformer/adapter_config.json"),
           (adapter["peft_type"] as? String)?.uppercased() == "LORA" {
            let base = adapter["base_model_name_or_path"] as? String
            return .blocked("This is a LoRA adapter. Standalone generation requires its base model"
                + (base.flatMap { $0.isEmpty ? nil : " (\($0))" } ?? "") + ".")
        }

        var candidates = localModelTypes(at: root, fileManager: files)
        addModelType(modelType(from: package.model), to: &candidates)
        let families = candidates.filter(supported.contains)
        guard !families.isEmpty else { return .unknown }
        if families == ["z_image"] {
            let required = ["scheduler/scheduler_config.json", "transformer/config.json",
                            "text_encoder/config.json", "vae/config.json", "tokenizer/tokenizer.json"]
            if let missing = required.first(where: { !files.paths.contains($0) }) {
                return .blocked("This Z-Image package is missing \(missing).")
            }
            for component in ["transformer", "text_encoder", "vae"]
                where !hasSafetensors(in: component, at: root, fileManager: files) {
                return .blocked("This Z-Image package is missing weights in \(component)/.")
            }
        }
        if families.contains("flux3"),
           let fluxConfig = config("config.json"), isFlux3Configuration(fluxConfig),
           let quantization = fluxConfig["quantization"], !(quantization is NSNull),
           (quantization as? [String: Any])?.isEmpty != true {
            return .blocked("This Nativ build cannot load this FLUX.3 quantization.")
        }
        guard package.metadataComplete else { return .unknown }
        if families == ["z_image"] { return .recognized }
        let layouts = families.map { supportsLocalLayout(modelType: $0, at: root, fileManager: files) }
        if layouts.contains(true) { return .recognized }
        if layouts.contains(nil) { return .unknown }
        return .blocked("This repository does not contain the file layout required by Nativ’s \(families[0]) image backend.")
    }

    private func isMageFlowEditModel(
        model: String,
        at root: URL,
        fileManager: any ImagePackageFiles
    ) -> Bool {
        if Self.isKnownImageEditOnlyModelID(model) {
            return true
        }

        let metadataURL = root.appendingPathComponent("mlx_mage_flow.json")
        guard let metadata = loadJSONObject(
            at: metadataURL,
            fileManager: fileManager
        ) else {
            return false
        }
        return Self.isKnownImageEditOnlyModelID(
            String(describing: metadata["variant"] ?? "")
        )
    }

    private func localModelTypes(
        at root: URL,
        fileManager: any ImagePackageFiles
    ) -> [String] {
        var candidates: [String] = []

        for filename in ["model_index.json", "config.json"] {
            let url = root.appendingPathComponent(filename)
            if let metadata = loadJSONObject(at: url, fileManager: fileManager) {
                addMetadataCandidates(metadata, to: &candidates)
            }
        }

        let manifestURL = root.appendingPathComponent("manifest.json")
        if let manifest = loadJSONObject(at: manifestURL, fileManager: fileManager),
            isBonsaiManifest(manifest)
        {
            addModelType("bonsai", to: &candidates)
        }

        if Self.qwenImageWeightMarkers.isSubset(
            of: transformerWeightNames(at: root, fileManager: fileManager)
        ) {
            addModelType("qwen_image", to: &candidates)
        }

        let componentURLs = fileManager.children(of: root)
        for componentURL in componentURLs.sorted(by: { $0.path < $1.path }) {
            // Shared autoencoders and schedulers don't identify the image
            // model family (MOSS-Image, for example, uses the Flux 2 VAE).
            if ["vae", "scheduler"].contains(componentURL.lastPathComponent) {
                continue
            }
            let configURL = componentURL.appendingPathComponent("config.json")
            if let metadata = loadJSONObject(
                at: configURL,
                fileManager: fileManager
            ) {
                addMetadataCandidates(metadata, to: &candidates)
            }
        }

        return candidates
    }

    private func addMetadataCandidates(
        _ metadata: [String: Any],
        to candidates: inout [String]
    ) {
        addModelType(metadata["model_type"], to: &candidates)
        addClassNameCandidates(metadata["_class_name"], to: &candidates)

        if isFlux3Configuration(metadata) {
            addModelType("flux3", to: &candidates)
        }

        for component in ["transformer", "text_encoder"] {
            let value = metadata[component]
            if let values = value as? [Any], let className = values.last {
                addClassNameCandidates(className, to: &candidates)
            } else if let value = value as? [String: Any] {
                addClassNameCandidates(
                    value["_class_name"] ?? value["class"],
                    to: &candidates
                )
            }
        }
    }

    private func addClassNameCandidates(
        _ value: Any?,
        to candidates: inout [String]
    ) {
        guard let value else {
            return
        }
        let className = String(describing: value)
        // MiniMax's mixed-case name splits into Mini_Max rather than minimax.
        if [
            "MiniMaxH3ImagePipeline", "MiniMaxH3ImageTransformer2DModel",
            "AutoencoderKLMiniMaxH3Image",
        ].contains(className) {
            addModelType("minimax_h3_image", to: &candidates)
        }
        let range = NSRange(className.startIndex..., in: className)
        let tokens = Self.pascalCaseTokenRegex.matches(
            in: className,
            range: range
        ).compactMap { match -> String? in
            guard let tokenRange = Range(match.range, in: className) else {
                return nil
            }
            return String(className[tokenRange])
        }

        if !tokens.isEmpty {
            for end in 1 ... tokens.count {
                addModelType(
                    tokens.prefix(end).joined(separator: "_"),
                    to: &candidates
                )
            }
        }
        for token in tokens {
            addModelType(token, to: &candidates)
        }
    }

    private func addModelType(_ value: Any?, to candidates: inout [String]) {
        guard let normalized = normalizedModelType(value),
            !candidates.contains(normalized)
        else {
            return
        }
        candidates.append(normalized)
    }

    private func normalizedModelType(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = String(describing: value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        guard !normalized.isEmpty,
            normalized.range(
                of: #"^[a-z_][a-z0-9_]*$"#,
                options: .regularExpression
            ) != nil
        else {
            return nil
        }
        return normalized
    }

    private func modelType(from model: String) -> String? {
        guard let normalizedName = Self.normalizedModelName(model) else {
            return nil
        }
        if normalizedName == "minimax_h3_image_pe"
            || normalizedName.hasPrefix("minimax_h3_image_pe_")
        {
            return nil
        }
        if normalizedName.hasPrefix("flux_3_")
            || normalizedName.hasPrefix("flux.3_")
        {
            return "flux3"
        }
        for modelType in generationModelTypes.union(editingModelTypes)
            .sorted(by: { $0.count > $1.count })
        where normalizedName == modelType
            || normalizedName.hasPrefix("\(modelType)_") {
            return modelType
        }
        let name = Substring(normalizedName)
        let modelType = String(name.split(separator: "_", maxSplits: 1).first ?? name)
        switch modelType {
        case "ternary", "2bit":
            return "bonsai"
        case "flux.2", "flux2", "klein":
            return "flux2"
        case "qwen", "qwenimage":
            return "qwen_image"
        default:
            return normalizedModelType(modelType)
        }
    }

    private static func normalizedModelName(_ model: String) -> String? {
        let normalized =
            model
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let name = normalized.split(separator: "/").last else {
            return nil
        }
        let normalizedName = String(name)
            .replacingOccurrences(of: "-", with: "_")
        return normalizedName.isEmpty ? nil : normalizedName
    }

    private func transformerWeightNames(
        at root: URL,
        fileManager: any ImagePackageFiles
    ) -> Set<String> {
        for filename in [
            "diffusion_pytorch_model.safetensors.index.json",
            "model.safetensors.index.json",
        ] {
            let url = root.appendingPathComponent("transformer/\(filename)")
            guard let index = loadJSONObject(at: url, fileManager: fileManager),
                let weightMap = index["weight_map"] as? [String: Any]
            else {
                continue
            }
            return Set(weightMap.keys)
        }
        return []
    }

    private func isBonsaiManifest(_ manifest: [String: Any]) -> Bool {
        guard let entries = manifest["files"] as? [Any] else {
            return false
        }
        let paths = Set(
            entries.compactMap { entry -> String? in
                if let path = entry as? String {
                    return path
                }
                guard let entry = entry as? [String: Any] else {
                    return nil
                }
                return [
                    "remote_path",
                    "path",
                    "filename",
                    "name",
                ].compactMap { entry[$0] as? String }.first
            })
        return paths.contains(
            "transformer-packed-mflux/diffusion_pytorch_model.safetensors"
        )
            && paths.contains("text_encoder-mlx-4bit/model.safetensors")
            && paths.contains("tokenizer/tokenizer.json")
    }

    private func loadJSONObject(
        at url: URL,
        fileManager: any ImagePackageFiles
    ) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path),
            let data = fileManager.metadata(at: url),
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private func supportsLocalLayout(
        modelType: String,
        at root: URL,
        fileManager: any ImagePackageFiles
    ) -> Bool? {
        switch modelType {
        case "bonsai":
            return [
                "transformer-packed-mflux/diffusion_pytorch_model.safetensors",
                "text_encoder-mlx-4bit/model.safetensors",
                "tokenizer/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(
                    atPath: root.appendingPathComponent($0).path
                )
            }
        case "flux2":
            return hasSafetensors(
                in: "transformer",
                at: root,
                fileManager: fileManager
            )
                && hasSafetensors(
                    in: "text_encoder",
                    at: root,
                    fileManager: fileManager
                )
                && hasSafetensors(in: "vae", at: root, fileManager: fileManager)
                && fileManager.fileExists(
                    atPath: root.appendingPathComponent(
                        "tokenizer/tokenizer.json"
                    ).path
                )
        case "flux3":
            guard
                let metadata = loadJSONObject(
                    at: root.appendingPathComponent("config.json"),
                    fileManager: fileManager
                ), isFlux3Configuration(metadata),
                metadata["quantization"] == nil
                    || metadata["quantization"] is NSNull
                    || (metadata["quantization"] as? [String: Any])?.isEmpty == true
            else {
                return false
            }
            return [
                "model.safetensors",
                "ae.safetensors",
                "text_encoder/config.json",
                "text_encoder/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
            }
                && hasSafetensors(
                    in: "text_encoder",
                    at: root,
                    fileManager: fileManager
                )
        case "minimax_h3_image":
            guard let metadata = loadJSONObject(
                at: root.appendingPathComponent("model_index.json"),
                fileManager: fileManager
            ),
                metadata["_class_name"] as? String == "MiniMaxH3ImagePipeline"
                    || metadata["model_type"] as? String == "minimax_h3_image"
            else {
                return false
            }
            let hasTextEncoder: Bool
            if fileManager.fileExists(
                atPath: root.appendingPathComponent("text_encoder/config.json").path
            ) {
                hasTextEncoder = hasSafetensors(in: "text_encoder", at: root, fileManager: fileManager)
            } else {
                // Official packages may reference a shared conditioner in another Hub repo.
                let entry = metadata["text_encoder"] as? [Any]
                let reference = entry?.dropFirst(2).first as? [String: Any]
                let repository = reference?["pretrained_model_name_or_path"] as? String
                let subfolder = reference?["subfolder"] as? String ?? "text_encoder"
                hasTextEncoder = repository?.isEmpty == false && subfolder == "text_encoder"
            }
            return hasTextEncoder
                && ["tokenizer", "conditioner", "text_encoder"].contains {
                    fileManager.fileExists(
                        atPath: root.appendingPathComponent("\($0)/tokenizer.json").path
                    )
                }
                && ["transformer", "vae"].allSatisfy { component in
                    // Match mlx-vlm's preference for the official Diffusers weights.
                    let directory = fileManager.fileExists(
                        atPath: root.appendingPathComponent("\(component)_diffusers/config.json").path
                    ) ? "\(component)_diffusers" : component
                    guard let config = loadJSONObject(
                        at: root.appendingPathComponent("\(directory)/config.json"),
                        fileManager: fileManager
                    ) else {
                        return false
                    }
                    let classNames = component == "transformer"
                        ? ["MiniMaxH3ImageTransformer2DModel", "MiniMaxH3ImageTransformer"]
                        : ["AutoencoderKLMiniMaxH3Image"]
                    return classNames.contains(config["_class_name"] as? String ?? "")
                        && hasSafetensors(in: directory, at: root, fileManager: fileManager)
                }
        case "moss_image":
            guard
                let metadata = loadJSONObject(
                    at: root.appendingPathComponent("model_index.json"),
                    fileManager: fileManager
                ), metadata["_class_name"] as? String == "MOSSImagePipeline"
            else {
                return false
            }
            return [
                "scheduler/scheduler_config.json",
                "tokenizer/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
            }
                && ["transformer", "text_encoder", "vae"].allSatisfy {
                    fileManager.fileExists(
                        atPath: root.appendingPathComponent("\($0)/config.json").path
                    )
                        && hasSafetensors(in: $0, at: root, fileManager: fileManager)
                }
        case "ideogram4":
            let componentDirectories = [
                "transformer",
                "unconditional_transformer",
                "text_encoder",
                "vae",
            ]
            return componentDirectories.allSatisfy {
                hasSafetensors(in: $0, at: root, fileManager: fileManager)
                    && fileManager.fileExists(
                        atPath: root.appendingPathComponent(
                            "\($0)/config.json"
                        ).path
                    )
            }
                && fileManager.fileExists(
                    atPath: root.appendingPathComponent(
                        "tokenizer/tokenizer.json"
                    ).path
                )
        case "llada_image":
            return [
                "model_index.json",
                "scheduler/scheduler_config.json",
                "tokenizer/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(
                    atPath: root.appendingPathComponent($0).path
                )
            }
                && [
                    "queryformer", "sigvq", "text_encoder", "text_projection",
                    "transformer",
                ].allSatisfy {
                    fileManager.fileExists(
                        atPath: root.appendingPathComponent("\($0)/config.json").path
                    )
                        && hasSafetensors(
                            in: $0,
                            at: root,
                            fileManager: fileManager
                        )
                }
        case "mage_flow":
            return [
                "model_index.json",
                "transformer/config.json",
                "vae/config.json",
                "text_encoder/config.json",
                "text_encoder/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(
                    atPath: root.appendingPathComponent($0).path
                )
            }
                && [
                    "transformer",
                    "vae",
                    "text_encoder",
                ].allSatisfy {
                    hasSafetensors(
                        in: $0,
                        at: root,
                        fileManager: fileManager
                    )
                }
        case "qwen_image":
            return [
                "transformer/config.json",
                "vae/config.json",
                "text_encoder/config.json",
                "processor/tokenizer.json",
            ].allSatisfy {
                fileManager.fileExists(
                    atPath: root.appendingPathComponent($0).path
                )
            }
                && [
                    "transformer",
                    "vae",
                    "text_encoder",
                ].allSatisfy {
                    hasSafetensors(
                        in: $0,
                        at: root,
                        fileManager: fileManager
                    )
                }
        default:
            // The generated manifest is authoritative for newly bundled
            // backends whose local layout is not yet known to the app.
            return nil
        }
    }

    private func hasSafetensors(
        in directory: String,
        at root: URL,
        fileManager: any ImagePackageFiles
    ) -> Bool {
        let directoryURL = root.appendingPathComponent(directory)
        let contents = fileManager.children(of: directoryURL)
        return contents.contains { $0.pathExtension == "safetensors" }
    }

    private func isFlux3Configuration(_ metadata: [String: Any]) -> Bool {
        guard let model = metadata["model"] as? String,
            model.hasPrefix("flux-3-image"),
            let dit = metadata["dit"] as? [String: Any],
            let inputChannels = dit["in_channels"] as? [String: Any]
        else {
            return false
        }
        return Set(["image", "image_cond", "text"]).isSubset(of: Set(inputChannels.keys))
    }

    private static let qwenImageWeightMarkers: Set<String> = [
        "transformer_blocks.0.img_mlp.gate_layer.weight",
        "txt_in.text_norm.weight",
        "txt_in.in_layer.weight",
    ]

    private static let pascalCaseTokenRegex = try! NSRegularExpression(
        pattern: #"[A-Z]+(?=[A-Z][a-z]|$)|[A-Z][a-z0-9]*"#
    )
}

private protocol ImagePackageFiles {
    func fileExists(atPath path: String) -> Bool
    func children(of directory: URL) -> [URL]
    func metadata(at url: URL) -> Data?
}

extension FileManager: ImagePackageFiles {
    fileprivate func children(of directory: URL) -> [URL] {
        (try? contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    }

    fileprivate func metadata(at url: URL) -> Data? { try? Data(contentsOf: url) }
}

struct ImageDownloadManifest: Decodable, Equatable {
    let model: String
    let paths: [String]
    let metadata: [String: String]
    let metadataComplete: Bool
}

/// Interpret Hub paths in memory. No repository filenames are written to disk.
private struct RemoteImagePackage: ImagePackageFiles {
    let root = URL(fileURLWithPath: "/", isDirectory: true)
    let paths: Set<String>
    private let manifest: ImageDownloadManifest
    private let childrenByDirectory: [String: Set<String>]

    init(_ manifest: ImageDownloadManifest) {
        self.manifest = manifest
        paths = Set(manifest.paths)
        var children: [String: Set<String>] = [:]
        for path in paths {
            let parts = path.split(separator: "/")
            guard let first = parts.first else { continue }
            children["", default: []].insert(String(first))
            if parts.count == 2 {
                children[String(first), default: []].insert(String(parts[1]))
            }
        }
        childrenByDirectory = children
    }

    func fileExists(atPath path: String) -> Bool { paths.contains(String(path.dropFirst())) }
    func metadata(at url: URL) -> Data? {
        manifest.metadata[String(url.path.dropFirst())].map { Data($0.utf8) }
    }
    func children(of directory: URL) -> [URL] {
        (childrenByDirectory[String(directory.path.dropFirst())] ?? []).map {
            directory.appendingPathComponent($0)
        }
    }
}


enum ImagePackageCompatibility: Equatable, Sendable {
    case recognized
    case unknown
    case blocked(String)

    var blocker: String? {
        if case .blocked(let reason) = self { return reason }
        return nil
    }
}
