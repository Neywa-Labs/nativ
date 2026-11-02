import Foundation
import MetalKit
import XCTest
import simd

@MainActor
final class GaussianSplatTests: XCTestCase {
    func testPLYDecodingRestoresIdolCoordinatesAndCovariance() throws {
        var row = splat()
        row[0] = 1; row[1] = -3; row[2] = 2
        row[7] = log(0.1); row[8] = log(0.2); row[9] = log(0.3)
        let scene = try GaussianSplatScene(data: ply([row]))
        let value = try XCTUnwrap(scene.splats.first)
        XCTAssertEqual(value.position, SIMD4(1, 2, 3, 0))
        XCTAssertEqual(value.color, SIMD4(0.5, 0.5, 0.5, 0.5))
        XCTAssertEqual(value.covarianceA.x, 0.01, accuracy: 0.00001)
        XCTAssertEqual(value.covarianceA.w, 0.04, accuracy: 0.00001)
        XCTAssertEqual(value.covarianceB.y, 0.09, accuracy: 0.00001)
        XCTAssertEqual(value.covarianceA.y, 0, accuracy: 0.00001)
    }

    func testPLYPropertyOrderAndMalformedValues() throws {
        let row = splat()
        let original = try GaussianSplatScene(data: ply([row]))
        let reordered = try GaussianSplatScene(data: ply([row], reversed: true))
        XCTAssertEqual(original.splats[0].covarianceA, reordered.splats[0].covarianceA)
        XCTAssertThrowsError(try GaussianSplatScene(data: ply([row]).dropLast()))
        var invalid = row
        invalid[0] = .nan
        XCTAssertThrowsError(try GaussianSplatScene(data: ply([invalid])))
        invalid = row
        invalid[7] = 1_000
        XCTAssertThrowsError(try GaussianSplatScene(data: ply([invalid])))
        invalid = row
        for i in 10..<14 { invalid[i] = 0 }
        XCTAssertThrowsError(try GaussianSplatScene(data: ply([invalid])))
        XCTAssertThrowsError(try GaussianSplatScene(data: Data("ply\nformat ascii 1.0\nend_header\n".utf8)))
    }

    func testCameraControlsRemainFiniteAndAwayFromPoles() {
        var camera = GaussianSplatCamera()
        camera.orbit(dx: 100, dy: 100_000)
        camera.magnify(100_000)
        XCTAssertEqual(camera.pitch, 1.45)
        XCTAssertEqual(camera.zoom, 4)
        camera.orbit(dx: -100, dy: -100_000)
        camera.magnify(-100_000)
        XCTAssertEqual(camera.pitch, -1.45)
        XCTAssertEqual(camera.zoom, 0.25)
    }

    func testMetalBlendsSplatsInCameraDepthOrder() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var front = splat(), back = splat()
        front[2] = 0.1; back[2] = -0.1 // PLY z maps to Idol y.
        let sh: Float = 0.28209479177387814
        front[3] = 0.5 / sh; front[4] = -0.5 / sh; front[5] = -0.5 / sh
        back[3] = -0.5 / sh; back[4] = -0.5 / sh; back[5] = 0.5 / sh
        let scene = try GaussianSplatScene(data: ply([front, back]))
        var camera = GaussianSplatCamera()
        camera.pitch = 0
        let first = try centerPixel(scene: scene, camera: camera)
        XCTAssertGreaterThan(first.red, first.blue * 1.7)
        XCTAssertGreaterThan(first.blue, 45)
        camera.yaw = .pi
        let reverse = try centerPixel(scene: scene, camera: camera)
        XCTAssertGreaterThan(reverse.blue, reverse.red * 1.7)
        XCTAssertGreaterThan(reverse.red, 45)
    }

    private func centerPixel(scene: GaussianSplatScene, camera: GaussianSplatCamera) throws -> (red: Float, blue: Float) {
        let renderer = try GaussianSplatRenderer(scene: scene, camera: camera)
        let device = renderer.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let uniforms = GaussianSplatUniforms(scene: scene, camera: camera, size: CGSize(width: 64, height: 64))
        let order = uniforms.sortedIndices(in: scene)
        let indices = try XCTUnwrap(order.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        renderer.encode(command: command, target: texture, uniforms: uniforms, indices: indices)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        return (Float(pixel[2]), Float(pixel[0]))
    }

    private func splat() -> [Float] {
        [0, 0, 0, 0, 0, 0, 0, log(0.1), log(0.1), log(0.1), sqrt(0.5), sqrt(0.5), 0, 0]
    }

    private func ply(_ rows: [[Float]], reversed: Bool = false) -> Data {
        let properties = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        let order = reversed ? Array(properties.indices.reversed()) : Array(properties.indices)
        var data = Data(("ply\nformat binary_little_endian 1.0\nelement vertex \(rows.count)\n"
            + order.map { "property float \(properties[$0])\n" }.joined() + "end_header\n").utf8)
        for row in rows {
            for i in order {
                var bits = row[i].bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        return data
    }
}
