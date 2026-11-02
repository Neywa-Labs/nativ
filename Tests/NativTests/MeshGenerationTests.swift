import AppKit
import Foundation
import XCTest

@testable import NativServerKit

@MainActor
final class MeshGenerationTests: XCTestCase {
    func testImageImportAndSeedValidation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("castle.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: source)
        let viewModel = MeshGenerationViewModel(directory: folder)
        XCTAssertFalse(viewModel.canGenerate)
        viewModel.importImage(source)
        XCTAssertTrue(viewModel.canGenerate)
        XCTAssertEqual(viewModel.sourceName, "castle")
        XCTAssertNotNil(viewModel.sourceImage)
        let normalized = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(viewModel.sourceData)))
        XCTAssertTrue(normalized.hasAlpha)
        viewModel.seedText = "-1"
        XCTAssertFalse(viewModel.canGenerate)
        viewModel.seedText = "4294967295"
        XCTAssertTrue(viewModel.canGenerate)
        viewModel.seedText = "4294967296"
        XCTAssertFalse(viewModel.canGenerate)
    }

    func testHistoryRestoresOnlyExistingObjects() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = MeshGenerationRecord(id: UUID(), name: "Castle", createdAt: Date(), seed: 42, mode: .synthetic, bytes: 4)
        let missing = MeshGenerationRecord(id: UUID(), name: "Missing", createdAt: Date(), seed: 1, mode: .real, bytes: 4)
        let objectDirectory = folder.appendingPathComponent(record.id.uuidString)
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        try Data("ply\n".utf8).write(to: objectDirectory.appendingPathComponent("object.ply"))
        try JSONEncoder().encode([missing, record]).write(to: folder.appendingPathComponent("history.json"))
        let viewModel = MeshGenerationViewModel(directory: folder)
        XCTAssertEqual(viewModel.results, [record])
        XCTAssertEqual(viewModel.selectedResult, record)
    }

    func testSingleImagePayloadMatchesIdolAPI() throws {
        let payload = MLXMeshRequest(inputImage: "data:image/png;base64,aW1hZ2U=", mode: .synthetic, seed: .max)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "speridlabs/idol")
        XCTAssertEqual(json["input_image"] as? String, payload.inputImage)
        XCTAssertEqual(json["mode"] as? String, "synthetic")
        XCTAssertEqual(json["seed"] as? UInt64, UInt64(UInt32.max))
        XCTAssertEqual(json["steps"] as? Int, 50)
        XCTAssertEqual(json["guidance"] as? Double, 3)
        XCTAssertEqual(json["num_gaussians"] as? Int, 262_144)
        XCTAssertNil(json["input_images"])
    }

    func testAuthenticatedCreatePollAndDownload() async throws {
        let client = makeClient()
        let submitted = try await client.create(MLXMeshRequest(inputImage: "data:image/png;base64,aW1hZ2U="))
        XCTAssertEqual(submitted.status, .queued)
        let completed = try await client.waitForCompletion(submitted, pollInterval: .zero)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.camera?["yaw"], 0.25)
        let data = try await client.download(completed)
        XCTAssertEqual(data, MeshTestProtocol.ply)
    }

    func testFailureAndDeletedJobsStopPolling() async throws {
        for status in ["failed", "deleted"] {
            let job = try JSONDecoder().decode(MLXMeshJob.self, from: meshJobData(status: status))
            do {
                _ = try await makeClient().waitForCompletion(job)
                XCTFail("Expected a terminal failure")
            } catch NativMeshError.generationFailed(let message) {
                XCTAssertFalse(message.isEmpty)
                if status == "failed" { XCTAssertEqual(message, "Encoder access is required") }
            }
        }
    }

    func testInvalidAndIncompleteFilesAreRejected() async throws {
        for id in ["corrupt", "truncated"] {
            let job = try JSONDecoder().decode(MLXMeshJob.self, from: meshJobData(status: "completed", id: id))
            do {
                _ = try await makeClient().download(job)
                XCTFail("Expected invalid PLY rejection")
            } catch NativMeshError.invalidResponse { }
        }
    }

    func testPendingJobsCannotBeDownloaded() async throws {
        let job = try JSONDecoder().decode(MLXMeshJob.self, from: meshJobData(status: "in_progress"))
        do {
            _ = try await makeClient().download(job)
            XCTFail("Expected pending job rejection")
        } catch NativMeshError.invalidResponse { }
    }

    func testAuthenticationErrorsAreNotRetried() async throws {
        do {
            try await makeClient(prefix: "denied").waitUntilReady()
            XCTFail("Expected 401")
        } catch NativMeshError.httpStatus(let code, _) {
            XCTAssertEqual(code, 401)
        }
    }

    func testPollingTimeoutAndCancellation() async throws {
        let pending = try JSONDecoder().decode(MLXMeshJob.self, from: meshJobData(status: "queued"))
        do {
            _ = try await makeClient().waitForCompletion(pending, timeout: 0)
            XCTFail("Expected timeout")
        } catch NativMeshError.timedOut { }

        let task = Task {
            try await makeClient().waitForCompletion(pending, pollInterval: .seconds(60))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    func testJobIDsCannotChangeOriginOrPath() throws {
        let client = makeClient()
        for id in ["", "../other", "https://example.com/steal", "mesh_a?token", "a/b"] {
            XCTAssertThrowsError(try client.jobRequest(id, content: true))
        }
        let request = try client.jobRequest("mesh_abc-123", content: true)
        XCTAssertEqual(request.url?.absoluteString, "http://mesh.test/v1/meshes/mesh_abc-123/content")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    private func makeClient(prefix: String = "") -> NativMeshClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MeshTestProtocol.self]
        return NativMeshClient(
            baseURL: URL(string: "http://mesh.test/\(prefix)")!, apiKey: "test-key",
            session: URLSession(configuration: configuration)
        )
    }
}

private func meshJobData(status: String, id: String = "mesh_test") -> Data {
    Data("""
    {"id":"\(id)","status":"\(status)","model":"speridlabs/idol","seed":42,
     "format":"ply","representation":"gaussian_splat","file_size_bytes":\(MeshTestProtocol.ply.count),
     "camera":{"yaw":0.25,"pitch":0,"radius":2,"fov":35},
     "url":"https://untrusted.example/content","error":{"message":"Encoder access is required"}}
    """.utf8)
}

private final class MeshTestProtocol: URLProtocol {
    static let ply = Data("ply\nformat binary_little_endian 1.0\nelement vertex 0\nend_header\n".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        XCTAssertEqual(request.url?.host, "mesh.test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let path = request.url!.path
        let status = path.contains("denied") ? 401 : 200
        let body: Data
        if path.hasSuffix("/content") {
            body = path.contains("corrupt") ? Data("bad data".utf8)
                : path.contains("truncated") ? Data("ply\n".utf8) : Self.ply
        } else {
            body = meshJobData(status: request.httpMethod == "POST" ? "queued" : "completed")
            if request.httpMethod == "POST" {
                XCTAssertEqual(path, "/v1/meshes")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
