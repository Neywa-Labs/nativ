import Foundation
import simd

/// Four aligned float4s shared with the Metal vertex shader.
struct GaussianSplat: Sendable {
    var position: SIMD4<Float>
    var covarianceA: SIMD4<Float> // xx, xy, xz, yy
    var covarianceB: SIMD4<Float> // yz, zz, unused, unused
    var color: SIMD4<Float> // RGB and opacity
}

struct GaussianSplatScene: Sendable {
    let splats: [GaussianSplat]
    let center: SIMD3<Float>
    let extent: Float

    enum ReadError: LocalizedError {
        case unsupported, malformed, empty
        var errorDescription: String? {
            switch self {
            case .unsupported: "This preview supports binary little-endian Gaussian splat PLY files."
            case .malformed: "The Gaussian splat file is incomplete or contains invalid values."
            case .empty: "The file contains no visible Gaussian splats."
            }
        }
    }

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        let headerLimit = data.prefix(65_536)
        guard let end = headerLimit.range(of: Data("end_header\n".utf8)),
              let header = String(data: data[..<end.upperBound], encoding: .ascii),
              header.hasPrefix("ply\n") else { throw ReadError.unsupported }
        var count = 0
        var properties: [String] = []
        var isVertex = false
        var binary = false
        for line in header.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let kind = parts.first else { continue }
            switch kind {
            case "format": binary = parts == ["format", "binary_little_endian", "1.0"]
            case "element":
                guard parts.count == 3, parts[1] == "vertex", count == 0,
                      let n = Int(parts[2]), (1...2_000_000).contains(n) else { throw ReadError.unsupported }
                count = n
                isVertex = true
            case "property":
                guard isVertex, parts.count == 3, parts[1] == "float",
                      !properties.contains(String(parts[2])), properties.count < 128 else { throw ReadError.unsupported }
                properties.append(String(parts[2]))
            default: break
            }
        }
        let required = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                        "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        guard binary, count > 0, required.allSatisfy(properties.contains) else { throw ReadError.unsupported }
        let offsets = required.map { properties.firstIndex(of: $0)! * 4 }
        let stride = properties.count * 4, start = end.upperBound
        guard data.count - start >= count * stride else { throw ReadError.malformed }
        var result: [GaussianSplat] = []
        result.reserveCapacity(count)
        try data.withUnsafeBytes { bytes in
            for i in 0..<count {
                if i % 4096 == 0 { try Task.checkCancellation() }
                let base = start + i * stride
                let values = offsets.map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: base + $0, as: UInt32.self))) }
                guard values.allSatisfy(\.isFinite) else { throw ReadError.malformed }
                let alpha: Float = 1 / (1 + exp(-values[6]))
                if alpha < 0.005 { continue }
                let scales = SIMD3(exp(values[7]), exp(values[8]), exp(values[9]))
                guard scales.x.isFinite, scales.y.isFinite, scales.z.isFinite,
                      simd_reduce_max(scales) < 1_000 else { throw ReadError.malformed }
                // Idol exports y-up PLY. Restore its z-up camera convention.
                let position = SIMD3(values[0], values[2], -values[1])
                guard simd_reduce_max(abs(position)) < 1_000_000 else { throw ReadError.malformed }
                let w = values[10], x = values[11], y = values[12], z = values[13]
                let q = simd_quatf(vector: SIMD4(x - w, y + z, z - y, w + x) * sqrt(0.5))
                guard q.length.isFinite, q.length > 0.00001 else { throw ReadError.malformed }
                let rotation = simd_float3x3(q.normalized)
                let scaled = simd_float3x3(columns: (rotation.columns.0 * scales.x,
                    rotation.columns.1 * scales.y, rotation.columns.2 * scales.z))
                let covariance = scaled * scaled.transpose
                let rgb = simd_clamp(SIMD3(values[3], values[4], values[5]) * 0.28209479177387814 + 0.5,
                                     SIMD3(repeating: 0), SIMD3(repeating: 1))
                result.append(GaussianSplat(
                    position: SIMD4(position, 0),
                    covarianceA: SIMD4(covariance[0, 0], covariance[0, 1], covariance[0, 2], covariance[1, 1]),
                    covarianceB: SIMD4(covariance[1, 2], covariance[2, 2], 0, 0),
                    color: SIMD4(rgb, alpha)
                ))
            }
        }
        guard !result.isEmpty else { throw ReadError.empty }
        // A few low-opacity floaters should not make the object tiny in the viewer.
        let visible = result.filter { $0.color.w > 0.05 }
        let framing = visible.isEmpty ? result : visible
        var low = SIMD3<Float>(), high = SIMD3<Float>()
        for axis in 0..<3 {
            let coordinates = framing.map { $0.position[axis] }.sorted()
            low[axis] = coordinates[Int(Float(coordinates.count - 1) * 0.01)]
            high[axis] = coordinates[Int(ceil(Float(coordinates.count - 1) * 0.99))]
        }
        splats = result
        center = (low + high) * 0.5
        extent = max(simd_length(high - low) * 0.5, 0.01)
    }
}

struct GaussianSplatCamera: Sendable, Equatable {
    var yaw: Float = 0
    var pitch: Float = 0.15
    var zoom: Float = 1
    var fieldOfView: Float = 30 * .pi / 180

    init(url: URL? = nil) {
        guard let url, let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: Float].self, from: data) else { return }
        if let value = values["yaw"], value.isFinite { yaw = value }
        if let value = values["pitch"], value.isFinite { pitch = min(1.45, max(-1.45, value)) }
        if let value = values["fov"], value.isFinite, (5...100).contains(value) { fieldOfView = value * .pi / 180 }
    }

    mutating func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(1.45, max(-1.45, pitch + dy * 0.008))
    }

    mutating func magnify(_ delta: Float) {
        zoom = min(4, max(0.25, zoom * exp(delta * 0.01)))
    }
}
