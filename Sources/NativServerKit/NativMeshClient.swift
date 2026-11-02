import Foundation

/// Single-image Gaussian-splat generation via mlx-vlm's asynchronous mesh API.
public struct MLXMeshRequest: Encodable, Equatable, Sendable {
    public enum InputMode: String, Codable, CaseIterable, Sendable {
        case real, synthetic
    }

    public var model: String
    public var inputImage: String
    public var mode: InputMode
    public var steps: Int
    public var seed: UInt32
    public var guidance: Double
    public var numGaussians: Int

    public init(
        model: String = "speridlabs/idol", inputImage: String,
        mode: InputMode = .real, steps: Int = 50, seed: UInt32 = 42,
        guidance: Double = 3, numGaussians: Int = 262_144
    ) {
        self.model = model
        self.inputImage = inputImage
        self.mode = mode
        self.steps = steps
        self.seed = seed
        self.guidance = guidance
        self.numGaussians = numGaussians
    }

    enum CodingKeys: String, CodingKey {
        case model, mode, steps, seed, guidance
        case inputImage = "input_image"
        case numGaussians = "num_gaussians"
    }
}

public struct MLXMeshJob: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable {
        case queued, inProgress = "in_progress", completed, failed, deleted
    }

    public struct Failure: Decodable, Equatable, Sendable {
        public let message: String
    }

    public let id: String
    public let status: Status
    public let model: String
    public let seed: UInt32
    public let format: String
    public let representation: String
    public let fileSizeBytes: Int64?
    public let camera: [String: Double]?
    public let error: Failure?

    enum CodingKeys: String, CodingKey {
        case id, status, model, seed, format, representation, camera, error
        case fileSizeBytes = "file_size_bytes"
    }
}

public enum NativMeshError: Error, LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int, String)
    case generationFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid 3D result."
        case .httpStatus(let code, let body):
            NativServerErrorMessage.endpointFailure(
                endpoint: "3D generation endpoint", statusCode: code, responseBody: body
            )
        case .generationFailed(let message):
            message
        case .timedOut:
            "The server took too long to respond. Check its status in Developer."
        }
    }
}

public final class NativMeshClient: Sendable {
    private let baseURL: URL
    private let apiKey: String?
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8080")!,
        apiKey: String? = nil, session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func create(_ payload: MLXMeshRequest) async throws -> MLXMeshJob {
        var request = makeRequest(path: "v1/meshes", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(MLXMeshJob.self, from: await data(for: request))
    }

    public func retrieve(_ id: String) async throws -> MLXMeshJob {
        let request = try jobRequest(id)
        return try JSONDecoder().decode(MLXMeshJob.self, from: await data(for: request))
    }

    public func download(_ job: MLXMeshJob) async throws -> Data {
        guard job.status == .completed, job.format == "ply",
              job.representation == "gaussian_splat"
        else { throw NativMeshError.invalidResponse }
        // Construct a same-server route instead of following a response URL
        // that could send the server API key to another origin.
        let data = try await data(for: jobRequest(job.id, content: true))
        guard data.starts(with: Data("ply\n".utf8)),
              job.fileSizeBytes.map({ $0 == data.count }) ?? true
        else { throw NativMeshError.invalidResponse }
        return data
    }

    public func waitForCompletion(
        _ submitted: MLXMeshJob, timeout: TimeInterval = 7_200,
        pollInterval: Duration = .seconds(1),
        onUpdate: @Sendable (MLXMeshJob) async -> Void = { _ in }
    ) async throws -> MLXMeshJob {
        let deadline = ContinuousClock.now + .seconds(timeout)
        var job = submitted
        while true {
            try Task.checkCancellation()
            await onUpdate(job)
            switch job.status {
            case .completed: return job
            case .failed:
                throw NativMeshError.generationFailed(job.error?.message ?? "3D generation failed.")
            case .deleted:
                throw NativMeshError.generationFailed("This 3D job is no longer available.")
            case .queued, .inProgress: break
            }
            guard ContinuousClock.now < deadline else { throw NativMeshError.timedOut }
            try await Task.sleep(for: pollInterval)
            job = try await retrieve(submitted.id)
        }
    }

    public func waitUntilReady(timeout: TimeInterval = 120) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var request = makeRequest(path: "health")
            request.timeoutInterval = 2
            do {
                _ = try await data(for: request)
                return
            } catch let error as NativMeshError {
                // Authentication errors require a settings change, not a retry.
                if case .httpStatus(let code, _) = error, code == 401 || code == 403 { throw error }
            } catch is CancellationError {
                throw CancellationError()
            } catch { }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw NativMeshError.timedOut
    }

    func makeRequest(path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        NativServerAuthorization.authorize(&request, apiKey: apiKey)
        return request
    }

    func jobRequest(_ id: String, content: Bool = false) throws -> URLRequest {
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
        }) else { throw NativMeshError.invalidResponse }
        return makeRequest(path: "v1/meshes/\(id)" + (content ? "/content" : ""))
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativMeshError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw NativMeshError.httpStatus(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
