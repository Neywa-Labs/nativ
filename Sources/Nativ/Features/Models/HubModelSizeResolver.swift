import Foundation

/// Resolves download bytes independently of tensor/memory estimates. Only callers
/// still interested in a row keep its queued or in-flight request alive.
@MainActor
final class HubModelSizeResolver {
    static let shared = HubModelSizeResolver()

    struct Request: Hashable, Sendable {
        let repoID: String
        let revision: String?
        let token: String?
        let checkImage: Bool?

        init(repoID: String, revision: String? = nil, token: String? = nil, checkImage: Bool? = nil) {
            self.checkImage = checkImage
            self.repoID = repoID
            self.revision = revision
            self.token = HuggingFaceAuthentication.normalizedToken(token)
        }
    }

    typealias Fetch = @Sendable (Request) async -> Data?

    struct Details: Sendable {
        let bytes: Int64?
        let image: ImagePackageCompatibility?
    }

    private struct CachedSize {
        let details: Details
        let expires: Date
    }

    private final class Job {
        let request: Request
        var waiters: [UUID: CheckedContinuation<Details?, Never>] = [:]
        var task: Task<Void, Never>?

        init(request: Request) { self.request = request }
    }

    private let maximumConcurrentRequests: Int
    private let debounce: Duration
    private let fetch: Fetch
    private var cache: [Request: CachedSize] = [:]
    private var jobs: [Request: Job] = [:]
    private var queue: [Job] = []
    private var activeRequests = 0

    init(maximumConcurrentRequests: Int = 4, debounce: Duration = .milliseconds(250),
         fetch: @escaping Fetch = HubModelSizeResolver.fetchMetadata) {
        precondition(maximumConcurrentRequests > 0)
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.debounce = debounce
        self.fetch = fetch
    }

    func cachedDetails(for request: Request) -> Details? {
        guard let cached = cache[request], cached.expires > .now else { return nil }
        return cached.details
    }

    func resolveSize(for repoID: String, revision: String? = nil, token: String? = nil) async -> Int64? {
        await resolveDetails(for: Request(repoID: repoID, revision: revision, token: token))?.bytes
    }

    func resolveDetails(for request: Request) async -> Details? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache[request], cached.expires > .now { return cached.details }
        do { try await Task.sleep(for: debounce) } catch { return nil }
        guard !Task.isCancelled else { return nil }
        if let cached = cache[request], cached.expires > .now { return cached.details }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                let job: Job
                if let existing = jobs[request] {
                    job = existing
                } else {
                    job = Job(request: request)
                    jobs[request] = job
                    queue.append(job)
                }
                job.waiters[waiterID] = continuation
                startQueuedRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(waiterID, request: request)
            }
        }
    }

    private func cancel(_ waiterID: UUID, request: Request) {
        guard let job = jobs[request] else { return }
        job.waiters.removeValue(forKey: waiterID)?.resume(returning: nil)
        guard job.waiters.isEmpty else { return }
        jobs[request] = nil
        queue.removeAll { $0 === job }
        // The slot is released when URLSession acknowledges cancellation.
        job.task?.cancel()
    }

    private func startQueuedRequests() {
        while activeRequests < maximumConcurrentRequests, !queue.isEmpty {
            let job = queue.removeFirst()
            activeRequests += 1
            let fetch = fetch
            job.task = Task { [weak self] in
                let details = await Self.fetchDetails(job.request, fetch: fetch)
                guard let self else { return }
                self.activeRequests -= 1
                if self.jobs[job.request] === job {
                    self.jobs[job.request] = nil
                    if !Task.isCancelled {
                        // Bound memory; failures briefly back off rather than refetching
                        // every time a lazy row appears. Unspecified revisions expire sooner.
                        let lifetime: TimeInterval = details?.bytes == nil || details?.image == .unknown ? 30 : (job.request.revision == nil ? 300 : 3_600)
                        if self.cache.count >= 512,
                           let oldest = self.cache.min(by: { $0.value.expires < $1.value.expires })?.key {
                            self.cache[oldest] = nil
                        }
                        self.cache[job.request] = CachedSize(details: details ?? Details(bytes: nil, image: nil), expires: .now.addingTimeInterval(lifetime))
                    }
                    for waiter in job.waiters.values { waiter.resume(returning: details) }
                    job.waiters.removeAll()
                }
                self.startQueuedRequests()
            }
        }
    }

    @concurrent
    private static func fetchDetails(_ request: Request, fetch: Fetch) async -> Details? {
        guard let data = await fetch(request), !Task.isCancelled else { return nil }
        let image = request.checkImage == nil ? nil : await imageCompatibility(request: request, data: data)
        return Details(bytes: totalBytes(from: data), image: image)
    }

    nonisolated static func imageCompatibility(
        request: Request, data: Data,
        readConfig: @Sendable (URLRequest) async -> Data? = fetchData
    ) async -> ImagePackageCompatibility? {
        guard let listing = try? JSONDecoder().decode(SizePayload.self, from: data),
              let siblings = listing.siblings, !siblings.isEmpty else {
            return request.checkImage == true ? .unknown : nil
        }
        let paths = siblings.map(\.rfilename)
        guard request.checkImage == true || paths.contains("model_index.json")
            || paths.contains("ae.safetensors") || paths.contains(where: {
                $0.hasPrefix("transformer/") || $0.hasPrefix("transformer-packed-mflux/")
            }) else { return nil }
        guard let sha = listing.sha, !sha.isEmpty else { return .unknown }
        var metadata: [String: String] = [:]
        var complete = true
        var remaining = 512 * 1024
        let names: Set<String> = ["config.json", "model_index.json", "manifest.json",
                                  "adapter_config.json", "mlx_mage_flow.json",
                                  "model.safetensors.index.json", "diffusion_pytorch_model.safetensors.index.json"]
        for file in siblings {
            guard !Task.isCancelled else { return nil }
            let parts = file.rfilename.components(separatedBy: "/")
            guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
                  let name = parts.last, names.contains(name) else { continue }
            guard let size = file.lfs?.size ?? file.size, size >= 0,
                  size <= min(256 * 1024, remaining) else { complete = false; continue }
            remaining -= Int(size)
            var url = URLComponents(string: "https://huggingface.co")!
            url.path = "/\(request.repoID)/resolve/\(sha)/\(file.rfilename)"
            guard let configURL = url.url else { complete = false; continue }
            var configRequest = URLRequest(url: configURL)
            configRequest.timeoutInterval = 15
            HuggingFaceAuthentication.authorize(&configRequest, token: request.token)
            guard let bytes = await readConfig(configRequest), bytes.count <= size,
                  (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any],
                  let json = String(data: bytes, encoding: .utf8) else {
                complete = false
                continue
            }
            metadata[file.rfilename] = json
        }
        return MLXImageModelResolver.shared.imageCompatibility(for: ImageDownloadManifest(
            model: request.repoID, paths: paths, metadata: metadata, metadataComplete: complete
        ))
    }

    nonisolated static func metadataRequest(for request: Request) -> URLRequest? {
        var components = URLComponents(string: "https://huggingface.co")
        components?.path = "/api/models/\(request.repoID)"
        if let revision = request.revision { components?.path += "/revision/\(revision)" }
        components?.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        guard let url = components?.url else { return nil }
        var result = URLRequest(url: url)
        result.timeoutInterval = 20
        HuggingFaceAuthentication.authorize(&result, token: request.token)
        return result
    }

    private nonisolated static func fetchMetadata(_ request: Request) async -> Data? {
        guard let urlRequest = metadataRequest(for: request) else { return nil }
        return await fetchData(urlRequest)
    }

    private nonisolated static func fetchData(_ urlRequest: URLRequest) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: urlRequest),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    nonisolated static func totalBytes(from data: Data) -> Int64? {
        guard let payload = try? JSONDecoder().decode(SizePayload.self, from: data),
              let siblings = payload.siblings, !siblings.isEmpty else { return nil }
        var total: Int64 = 0
        for sibling in siblings where !HuggingFaceDownloadFilePolicy.shouldIgnore(path: sibling.rfilename) {
            // Missing sizes must never silently become zero and understate a download.
            guard let size = sibling.lfs?.size ?? sibling.size, size >= 0 else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total > 0 ? total : nil
    }

    private struct SizePayload: Decodable {
        struct Sibling: Decodable {
            struct LFS: Decodable { let size: Int64? }
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
        }
        let sha: String?
        let siblings: [Sibling]?
    }
}
