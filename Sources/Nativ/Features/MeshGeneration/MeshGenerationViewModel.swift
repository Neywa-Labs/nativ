import AppKit
import Combine
import Foundation
import NativServerKit
import UniformTypeIdentifiers

struct MeshGenerationRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let createdAt: Date
    let seed: UInt32
    let mode: MLXMeshRequest.InputMode
    let bytes: Int64
}

@MainActor
final class MeshGenerationViewModel: ObservableObject {
    static let modelID = "speridlabs/idol"
    @Published private(set) var sourceImage: NSImage?
    @Published private(set) var sourceData: Data?
    @Published private(set) var sourceName = "Object"
    @Published var mode: MLXMeshRequest.InputMode = .real
    @Published var seedText = "42"
    @Published private(set) var isGenerating = false
    @Published private(set) var statusText: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var results: [MeshGenerationRecord] = []
    @Published var selectedID: UUID?
    private let directory: URL
    private var task: Task<Void, Never>?

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Nativ/3D", isDirectory: true)
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("history.json")),
           let records = try? JSONDecoder().decode([MeshGenerationRecord].self, from: data) {
            results = records.filter {
                FileManager.default.fileExists(atPath: outputURL(for: $0).path)
            }
            selectedID = results.first?.id
        }
    }

    var selectedResult: MeshGenerationRecord? { results.first { $0.id == selectedID } }
    var canGenerate: Bool { sourceData != nil && UInt32(seedText) != nil && !isGenerating }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { importImage(url) }
    }

    func importImage(_ url: URL) {
        guard !isGenerating else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Normalize supported macOS image formats (including HEIC) to PNG for
        // the Python image loader, preserving transparency and orientation.
        guard let image = NSImage(contentsOf: url),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            errorMessage = "This image couldn’t be opened. Choose another image."
            return
        }
        sourceImage = image
        sourceData = data
        sourceName = url.deletingPathExtension().lastPathComponent
        errorMessage = nil
    }

    func generate(using model: NativModel) {
        guard canGenerate, let sourceData, let seed = UInt32(seedText) else { return }
        if !model.isRunning { model.startServer() }
        guard model.isRunning, let baseURL = model.activeServerBaseURL else {
            errorMessage = "The server couldn’t start. Check Developer for details."
            return
        }
        let client = NativMeshClient(baseURL: baseURL, apiKey: model.activeServerAPIKey)
        let settings = model.settings.normalized()
        let token = model.effectiveHuggingFaceToken
        let request = MLXMeshRequest(
            inputImage: "data:image/png;base64," + sourceData.base64EncodedString(),
            mode: mode, seed: seed
        )
        let id = UUID(), name = sourceName, inputMode = mode
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        isGenerating = true
        statusText = "Preparing Idol…"
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { isGenerating = false; task = nil }
            do {
                try await client.waitUntilReady()
                try await HuggingFaceDownloadManager.shared.downloadIfNeeded(
                    repoID: Self.modelID, sizeBytes: nil,
                    cachePath: settings.modelSearchPath,
                    volumeIdentifier: settings.externalModelCache?.volumeIdentifier,
                    token: token
                )
                statusText = "Submitting image…"
                let submitted = try await client.create(request)
                let completed = try await client.waitForCompletion(submitted) { [weak self] job in
                    await self?.updateStatus(job)
                }
                statusText = "Saving 3D result…"
                let ply = try await client.download(completed)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try sourceData.write(to: folder.appendingPathComponent("input.png"), options: .atomic)
                    try ply.write(to: folder.appendingPathComponent("object.ply"), options: .atomic)
                    if let camera = completed.camera {
                        try JSONEncoder().encode(camera).write(
                            to: folder.appendingPathComponent("camera.json"), options: .atomic
                        )
                    }
                }.value
                let record = MeshGenerationRecord(
                    id: id, name: name, createdAt: Date(), seed: seed,
                    mode: inputMode, bytes: Int64(ply.count)
                )
                results.insert(record, at: 0)
                selectedID = id
                try JSONEncoder().encode(results).write(
                    to: directory.appendingPathComponent("history.json"), options: .atomic
                )
                statusText = "3D object ready"
            } catch {
                errorMessage = error.localizedDescription
                statusText = nil
            }
        }
    }

    private func updateStatus(_ job: MLXMeshJob) {
        switch job.status {
        case .queued: statusText = "Queued — waiting for the 3D worker…"
        case .inProgress: statusText = "Generating 3D object…"
        case .completed: statusText = "Downloading 3D result…"
        case .failed, .deleted: break
        }
    }

    func outputURL(for record: MeshGenerationRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("object.ply")
    }

    func inputURL(for record: MeshGenerationRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString).appendingPathComponent("input.png")
    }

    func cameraURL(for record: MeshGenerationRecord) -> URL {
        outputURL(for: record).deletingLastPathComponent().appendingPathComponent("camera.json")
    }

    func save(_ record: MeshGenerationRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ply") ?? .data]
        panel.nameFieldStringValue = record.name + ".ply"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(contentsOf: outputURL(for: record)).write(to: destination, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }

    func reveal(_ record: MeshGenerationRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([outputURL(for: record)])
    }
}
