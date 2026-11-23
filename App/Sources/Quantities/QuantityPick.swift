import Foundation
import simd

/// Tap picking on the context model (v0.11.1).
///
/// The headset shows the light context USDZ (one mesh per layer and material), never the main
/// per-element USDZ. `tools/quantities/qv_pick.py` writes, per context mesh, its welded triangles
/// and the element each triangle came from (`Data/pick.json` + `Data/pick.bin`, model metres,
/// Y up, the frame of both USDZ files). A tap converts the hit into model space, takes the hit
/// mesh's triangles from the memory-mapped `pick.bin` (a grid per mesh is built on its first tap)
/// and returns the element of the nearest triangle.
final class QuantityPickIndex: @unchecked Sendable {
    static let jsonPath = "Data/pick.json"
    static let binPath = "Data/pick.bin"

    struct Mesh: Decodable, Sendable {
        let name: String
        let primPath: String
        let layerId: String?
        let triangleCount, vertexCount: Int
        let positionOffset, indexOffset, indexSize, elementOffset: Int
        let bounds: [[Float]]

        var lower: SIMD3<Float> { SIMD3(bounds[0][0], bounds[0][1], bounds[0][2]) }
        var upper: SIMD3<Float> { SIMD3(bounds[1][0], bounds[1][1], bounds[1][2]) }
    }

    private struct File: Decodable {
        let schemaVersion: Int
        let packageId: String
        let contextPath: String
        let contextSHA256: String
        let byteLength: Int
        let elementIds: [String]
        let meshes: [Mesh]
    }

    /// A uniform grid over one mesh's bounds: triangle indices per cell (CSR).
    private struct Grid {
        let lower: SIMD3<Float>
        let cell: SIMD3<Float>
        let dims: SIMD3<Int32>
        let start: [Int32]
        let items: [Int32]

        func cellIndex(_ c: SIMD3<Int32>) -> Int {
            Int(c.x) + Int(dims.x) * (Int(c.y) + Int(dims.y) * Int(c.z))
        }

        func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int32> {
            var f = ((p - lower) / cell).rounded(.down)
            f.replace(with: Float(0), where: .!(f .== f))   // NaN
            f = f.clamped(lowerBound: SIMD3<Float>(repeating: 0), upperBound: SIMD3<Float>(dims &- 1))
            return SIMD3<Int32>(f)
        }
    }

    let elementIds: [String]
    let meshes: [Mesh]
    private let meshByName: [String: Int]
    private let data: Data
    private let lock = NSLock()
    private var grids: [Int: Grid] = [:]

    /// Whether a downloaded package carries pick data (older downloads need an Update).
    static func isPresent(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(binPath).path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent(jsonPath).path)
    }

    /// Reads and checks the pick data of an opened package (off the main actor).
    static func load(folder: URL, package: AVQPackage) async throws -> QuantityPickIndex {
        try await Task.detached(priority: .userInitiated) {
            try QuantityPickIndex(folder: folder, package: package)
        }.value
    }

    private init(folder: URL, package: AVQPackage) throws {
        let stale = AVQPackageError("This project needs an Update from your PC (tap data is missing or from another revision).")
        guard Self.isPresent(in: folder) else { throw stale }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: folder.appendingPathComponent(Self.jsonPath)))
        let bytes = try Data(contentsOf: folder.appendingPathComponent(Self.binPath), options: .alwaysMapped)
        guard file.schemaVersion == 1, file.packageId == package.packageId,
              let context = package.contextSHA256, file.contextSHA256.lowercased() == context,
              file.byteLength == bytes.count
        else { throw stale }
        var byName: [String: Int] = [:]
        for (index, mesh) in file.meshes.enumerated() {
            func fits(_ offset: Int, _ count: Int, _ stride: Int) -> Bool {
                offset >= 0 && offset % 4 == 0 && count >= 0 && offset <= bytes.count
                    && count <= (bytes.count - offset) / stride
            }
            guard mesh.indexSize == 2 || mesh.indexSize == 4,
                  fits(mesh.positionOffset, mesh.vertexCount, 12),
                  fits(mesh.indexOffset, mesh.triangleCount * 3, mesh.indexSize),
                  fits(mesh.elementOffset, mesh.triangleCount, 4),
                  mesh.bounds.count == 2, mesh.bounds.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
            else { throw AVQPackageError("Invalid tap data for " + mesh.name) }
            if byName[mesh.name] == nil { byName[mesh.name] = index }
        }
        elementIds = file.elementIds
        meshes = file.meshes
        meshByName = byName
        data = bytes
    }

    // MARK: - Query

    /// The element under a model-space point: the named hit mesh first, then any mesh whose
    /// bounds hold the point. nil when nothing lies within `tolerance` metres.
    func element(meshNames: [String], point: SIMD3<Float>, tolerance: Float = 0.05) -> String? {
        var best: (distance: Float, element: UInt32)? = nil
        func consider(_ index: Int) {
            guard let found = nearest(in: index, to: point) else { return }
            if best == nil || found.distance < best!.distance { best = found }
        }
        for name in meshNames {
            if let index = meshByName[name] {
                consider(index)
                break
            }
        }
        if best == nil || best!.distance > 0.002 {
            let pad = SIMD3<Float>(repeating: tolerance)
            for (index, mesh) in meshes.enumerated()
            where all(point .>= mesh.lower - pad) && all(point .<= mesh.upper + pad) {
                consider(index)
            }
        }
        guard let best, best.distance <= tolerance, best.element != UInt32.max,
              Int(best.element) < elementIds.count else { return nil }
        return elementIds[Int(best.element)]
    }

    private func nearest(in index: Int, to p: SIMD3<Float>) -> (distance: Float, element: UInt32)? {
        let mesh = meshes[index]
        guard mesh.triangleCount > 0 else { return nil }
        let grid = self.lookupGrid(index)
        return data.withUnsafeBytes { raw -> (distance: Float, element: UInt32)? in
            var bestD = Float.greatestFiniteMagnitude
            var bestT = -1
            func test(_ t: Int) {
                let (a, b, c) = triangle(raw, mesh, t)
                let d = Self.distanceSquared(p, a, b, c)
                if d < bestD { bestD = d; bestT = t }
            }
            // The point's cell, then rings of neighbours until a found triangle is provably nearest.
            let centre = grid.cellOf(p)
            let maxRing = Int32(grid.dims.max())
            var ring: Int32 = 0
            while ring <= maxRing {
                let lo = pointwiseMax(centre &- ring, SIMD3<Int32>(repeating: 0))
                let hi = pointwiseMin(centre &+ ring, grid.dims &- 1)
                for z in lo.z...hi.z {
                    for y in lo.y...hi.y {
                        for x in lo.x...hi.x {
                            let onShell = abs(x - centre.x) == ring || abs(y - centre.y) == ring || abs(z - centre.z) == ring
                            guard onShell else { continue }
                            let cell = grid.cellIndex(SIMD3(x, y, z))
                            for k in Int(grid.start[cell])..<Int(grid.start[cell + 1]) { test(Int(grid.items[k])) }
                        }
                    }
                }
                // Everything outside the searched block is at least `ring * min cell size` away.
                let reach = Float(ring) * grid.cell.min()
                if bestT >= 0, bestD <= reach * reach { break }
                ring += 1
            }
            guard bestT >= 0 else { return nil }
            let element = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: mesh.elementOffset + 4 * bestT, as: UInt32.self))
            return (distance: bestD.squareRoot(), element: element)
        }
    }

    private func triangle(_ raw: UnsafeRawBufferPointer, _ mesh: Mesh, _ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        func vertex(_ corner: Int) -> SIMD3<Float> {
            let i = 3 * t + corner
            let v: Int
            if mesh.indexSize == 2 {
                v = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: mesh.indexOffset + 2 * i, as: UInt16.self)))
            } else {
                v = Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: mesh.indexOffset + 4 * i, as: UInt32.self)))
            }
            let o = mesh.positionOffset + 12 * min(v, mesh.vertexCount - 1)
            func f(_ k: Int) -> Float {
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: o + 4 * k, as: UInt32.self)))
            }
            return SIMD3(f(0), f(1), f(2))
        }
        return (vertex(0), vertex(1), vertex(2))
    }

    // MARK: - Grid (built on a mesh's first tap)

    private func lookupGrid(_ index: Int) -> Grid {
        lock.lock()
        if let cached = grids[index] { lock.unlock(); return cached }
        lock.unlock()
        let built = makeGrid(meshes[index])
        lock.lock()
        grids[index] = built
        lock.unlock()
        return built
    }

    private func makeGrid(_ mesh: Mesh) -> Grid {
        let lower = mesh.lower - 0.001
        let extent = simd_max(mesh.upper + 0.001 - lower, SIMD3<Float>(repeating: 0.01))
        // About 4 triangles per cell, at most 64 cells per axis.
        let target = Float(max(1, mesh.triangleCount / 4))
        let side = max(cbrt(extent.x * extent.y * extent.z / target), 0.005)
        let dims = SIMD3<Int32>((extent / side).rounded(.up)
            .clamped(lowerBound: SIMD3<Float>(repeating: 1), upperBound: SIMD3<Float>(repeating: 64)))
        let cell = extent / SIMD3<Float>(dims)
        let cellCount = Int(dims.x) * Int(dims.y) * Int(dims.z)
        var shell = Grid(lower: lower, cell: cell, dims: dims, start: [], items: [])
        var ranges: [(SIMD3<Int32>, SIMD3<Int32>)] = []
        ranges.reserveCapacity(mesh.triangleCount)
        var counts = [Int32](repeating: 0, count: cellCount + 1)
        data.withUnsafeBytes { raw in
            for t in 0..<mesh.triangleCount {
                let (a, b, c) = triangle(raw, mesh, t)
                let lo = shell.cellOf(simd_min(simd_min(a, b), c))
                let hi = shell.cellOf(simd_max(simd_max(a, b), c))
                ranges.append((lo, hi))
                for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x {
                    counts[shell.cellIndex(SIMD3(x, y, z)) + 1] += 1
                } } }
            }
        }
        for i in 0..<cellCount { counts[i + 1] += counts[i] }
        var fill = counts
        var items = [Int32](repeating: 0, count: Int(counts[cellCount]))
        for (t, (lo, hi)) in ranges.enumerated() {
            for z in lo.z...hi.z { for y in lo.y...hi.y { for x in lo.x...hi.x {
                let cellIndex = shell.cellIndex(SIMD3(x, y, z))
                items[Int(fill[cellIndex])] = Int32(t)
                fill[cellIndex] += 1
            } } }
        }
        shell = Grid(lower: lower, cell: cell, dims: dims, start: counts, items: items)
        return shell
    }

    /// Squared distance from p to triangle abc (closest point on triangle, Ericson 5.1.5).
    static func distanceSquared(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
        let ab = b - a, ac = c - a, ap = p - a
        let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return simd_length_squared(ap) }
        let bp = p - b
        let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return simd_length_squared(bp) }
        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            let v = d1 / (d1 - d3)
            return simd_length_squared(p - (a + v * ab))
        }
        let cp = p - c
        let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return simd_length_squared(cp) }
        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            let w = d2 / (d2 - d6)
            return simd_length_squared(p - (a + w * ac))
        }
        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return simd_length_squared(p - (b + w * (c - b)))
        }
        let denom = 1 / (va + vb + vc)
        guard denom.isFinite else {   // degenerate triangle: nearest corner
            return min(simd_length_squared(ap), simd_length_squared(bp), simd_length_squared(cp))
        }
        let v = vb * denom, w = vc * denom
        return simd_length_squared(p - (a + ab * v + ac * w))
    }
}
