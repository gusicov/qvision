import Foundation
import Metal
import RealityKit
import simd
import UIKit

// Keep this object for the lifetime of one loaded project.
@available(visionOS 2.0, *)
@MainActor
final class ArchViewerQuantities {
    let package: AVQPackage
    let placement: Entity
    let building: Entity
    private let reviewContext: Entity?
    private let overlayRoot = Entity()
    private let hatch: UnlitMaterial
    private let ink: UnlitMaterial
    private var savedOpacity: OpacityComponent?
    private var ghosted = false
    private var contextOpacity: Float = 0.20
    private let reviewSortGroup = ModelSortGroup(depthPass: .postPass)
    private weak var sortedContext: Entity?
    private var previousSort: [(Entity, ModelSortGroupComponent?)] = []
    private var generation: UInt64 = 0
    private var preparation: Task<AVQPrepared, Error>?
    private(set) var selection: AVQSelection?
    private(set) var visibleParts: [AVQPart] = []
    private(set) var thinTrimLocatorCount = 0
    private var binding: [String: String] = [:]

    init(package: AVQPackage, building: Entity, placement: Entity, reviewContext: Entity? = nil) async throws {
        guard building.parent === placement else {
            throw AVQPackageError("Attach the imported building directly to the movable placement entity first")
        }
        guard reviewContext?.parent == nil else {
            throw AVQPackageError("Supply the optional batched context as a newly loaded, unattached entity")
        }
        self.package = package
        self.building = building
        self.placement = placement
        self.reviewContext = reviewContext
        let texture = try await TextureResource(contentsOf: package.hatchURL,
                                               withName: package.packageId + "-hatch",
                                               options: .init(semantic: .color))
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        var field = UnlitMaterial()
        field.color = .init(tint: .white, texture: .init(texture, sampler: .init(descriptor)))
        field.faceCulling = .none
        hatch = field
        var stroke = UnlitMaterial(color: UIColor(red: 0.0, green: 0.34, blue: 0.38, alpha: 1))
        stroke.faceCulling = .none
        ink = stroke
        overlayRoot.name = "ArchViewerQuantitySelection"
        overlayRoot.transform = building.transform
        placement.addChild(overlayRoot)
        if let reviewContext {
            reviewContext.isEnabled = false
            placement.addChild(reviewContext)
        }
    }

    /// Full amount and unit stay in package.articles. visibleParts reports this display filter only.
    func show(_ requested: AVQSelection, visibility: AVQVisibility = .init(),
              hatchSpacingM: Float = 0.32, lineRadiusM: Float = 0.024,
              pointRadiusM: Float = 0.095, enableOverlayPicking: Bool = true,
              useBatchedContext: Bool = false) async throws {
        guard hatchSpacingM.isFinite && hatchSpacingM > 0,
              lineRadiusM.isFinite && lineRadiusM > 0, pointRadiusM.isFinite && pointRadiusM > 0
        else { throw AVQPackageError("Display sizes must be positive, finite metres") }
        generation &+= 1
        let token = generation
        preparation?.cancel()
        clearDisplay(keepSort: true)
        let data = package
        let work = Task.detached(priority: .userInitiated) {
            try AVQPrepared.make(package: data, selection: requested, visibility: visibility,
                                 spacing: hatchSpacingM, lineRadius: lineRadiusM, pointRadius: pointRadiusM)
        }
        preparation = work
        defer {
            if token == generation {
                preparation = nil
                if !ghosted { setSortedContext(nil) }
            }
        }
        let prepared = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try check(token)
        let staging = Entity()
        var idByName: [String: String] = [:]
        var occlusion = OcclusionMaterial()
        occlusion.faceCulling = .back
        for (name, batch, material) in [
            ("Pane depth", prepared.depth, occlusion as any Material),
            ("Quantity faces", prepared.faces, hatch as any Material),
            ("Paths and items", prepared.markers, ink as any Material)
        ] {
            guard !batch.indices.isEmpty else { continue }
            let resource = try batch.mesh(name)
            let node = ModelEntity(mesh: resource, materials: [material])
            node.name = name
            if package.drawSelectionThroughContext {
                node.components.set(ModelSortGroupComponent(group: reviewSortGroup, order: 1))
            }
            if name != "Pane depth", enableOverlayPicking {
                let shape = try await ShapeResource.generateStaticMesh(from: resource)
                try check(token)
                node.components.set(CollisionComponent(shapes: [shape]))
                node.components.set(InputTargetComponent())
            }
            staging.addChild(node)
        }
        try check(token)
        if !prepared.faces.indices.isEmpty || !prepared.markers.indices.isEmpty {
            overlayRoot.transform = building.transform
            savedOpacity = building.components[OpacityComponent.self]
            if useBatchedContext, visibility == AVQVisibility(), let context = reviewContext {
                // The fully detailed model retains its input components for normal element hit tests.
                building.components.set(OpacityComponent(opacity: 0))
                context.transform = building.transform
                context.components.set(OpacityComponent(opacity: contextOpacity))
                context.isEnabled = true
                setSortedContext(package.drawSelectionThroughContext ? context : nil)
            } else {
                building.components.set(OpacityComponent(opacity: contextOpacity))
                setSortedContext(package.drawSelectionThroughContext ? building : nil)
            }
            ghosted = true
            overlayRoot.addChild(staging)
            // Exact owner lookup is unambiguous for a single selected element.
            if let first = prepared.parts.first, prepared.parts.allSatisfy({ $0.elementId == first.elementId }) {
                idByName["Quantity faces"] = first.elementId
                idByName["Paths and items"] = first.elementId
            }
        }
        binding = idByName
        selection = requested
        visibleParts = prepared.parts
        thinTrimLocatorCount = prepared.thinTrimLocatorCount
    }

    func normalView() {
        generation &+= 1
        preparation?.cancel()
        preparation = nil
        clearDisplay()
    }

    func setContextOpacity(_ value: Float) {
        guard value.isFinite else { return }
        contextOpacity = min(max(value, 0), 1)
        guard ghosted else { return }
        if let context = reviewContext, context.isEnabled {
            context.components.set(OpacityComponent(opacity: contextOpacity))
        } else {
            building.components.set(OpacityComponent(opacity: contextOpacity))
        }
    }

    func detach() {
        normalView()
        overlayRoot.removeFromParent()
        reviewContext?.removeFromParent()
    }

    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func setSortedContext(_ root: Entity?) {
        guard sortedContext !== root else { return }
        for (node, previous) in previousSort {
            if let previous { node.components.set(previous) }
            else { node.components.remove(ModelSortGroupComponent.self) }
        }
        previousSort.removeAll(keepingCapacity: true)
        sortedContext = root
        guard let root else { return }
        let drawFirst = ModelSortGroupComponent(group: reviewSortGroup, order: 0)
        var stack = [root]
        while let node = stack.popLast() {
            if node.components[ModelComponent.self] != nil {
                previousSort.append((node, node.components[ModelSortGroupComponent.self]))
                node.components.set(drawFirst)
            }
            stack.append(contentsOf: node.children)
        }
    }

    private func clearDisplay(keepSort: Bool = false) {
        if !keepSort { setSortedContext(nil) }
        for child in Array(overlayRoot.children) { child.removeFromParent() }
        reviewContext?.isEnabled = false
        if ghosted {
            if let prior = savedOpacity { building.components.set(prior) }
            else { building.components.remove(OpacityComponent.self) }
        }
        ghosted = false
        savedOpacity = nil
        binding = [:]
        selection = nil
        visibleParts = []
        thinTrimLocatorCount = 0
    }

    /// For a USDZ model tap, walk back up through its child mesh to the actual Rhino owner.
    func element(forHit entity: Entity) -> AVQElement? {
        var node: Entity? = entity
        while let current = node, current !== placement {
            if let id = package.elementByEntityName[current.name] { return package.elements[id] }
            if current.parent?.parent === overlayRoot, let id = binding[current.name] { return package.elements[id] }
            node = current.parent
        }
        return nil
    }

    /// Accepts a hit position in the asset's metre coordinate system. Returns ties if several register parts
    /// own the same geometry. Use the returned elementId with package.usesByElement to populate the article menu.
    func parts(atProjectPoint p: SIMD3<Float>, toleranceM: Float = 0.12) async throws -> [AVQPart] {
        guard selection != nil, toleranceM.isFinite, toleranceM > 0 else { return [] }
        let token = generation, data = package, candidates = visibleParts
        let found = try await Task.detached(priority: .userInitiated) {
            try AVQPicker.nearest(point: p, tolerance: toleranceM, parts: candidates, package: data)
        }.value
        try check(token)
        return found
    }
}

private typealias V3 = SIMD3<Float>

private struct AVQMesh: Sendable {
    var positions: [V3] = []
    var uv: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    mutating func triangle(_ a: V3, _ b: V3, _ c: V3, spacing: Float? = nil) {
        let normal = simd_cross(b - a, c - a)
        guard simd_length_squared(normal) > 0 else { return }
        let index = UInt32(positions.count)
        positions.append(contentsOf: [a, b, c])
        indices.append(contentsOf: [index, index + 1, index + 2])
        if let spacing {
            let n = simd_abs(normal)
            for p in [a, b, c] {
                let diagonal: Float
                if n.y >= n.x && n.y >= n.z { diagonal = p.x + p.z }
                else if n.x >= n.z { diagonal = p.z + p.y }
                else { diagonal = p.x + p.y }
                uv.append([diagonal / (sqrt(2.0) * spacing), 0.5])
            }
        }
    }

    // Mesh markers have a visible thickness. The quantity still uses the original installed path or point.
    mutating func tube(from a: V3, to b: V3, radius: Float) {
        let d = b - a
        guard simd_length_squared(d) > 1e-12 else { return }
        let axis = simd_normalize(d)
        let helper: V3 = abs(axis.y) < 0.85 ? [0, 1, 0] : [1, 0, 0]
        let u = simd_normalize(simd_cross(axis, helper)) * radius
        let v = simd_cross(axis, u)
        let sides = 6
        func ring(_ i: Int) -> V3 {
            let angle = Float(i) * 2 * .pi / Float(sides)
            return cos(angle) * u + sin(angle) * v
        }
        for i in 0..<sides {
            let r = ring(i), s = ring(i + 1)
            triangle(a + r, a + s, b + s)
            triangle(a + r, b + s, b + r)
            triangle(a, a + s, a + r)
            triangle(b, b + r, b + s)
        }
    }

    mutating func dot(at center: V3, radius: Float) {
        let ring: [V3] = [[radius, 0, 0], [0, 0, radius], [-radius, 0, 0], [0, 0, -radius]]
        let up = V3(0, radius, 0)
        for i in ring.indices {
            let a = center + ring[i], b = center + ring[(i + 1) % ring.count]
            triangle(center + up, b, a)
            triangle(center - up, a, b)
        }
    }

    @MainActor func mesh(_ name: String) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.primitives = .triangles(indices)
        if !uv.isEmpty { descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uv) }
        return try MeshResource.generate(from: [descriptor])
    }
}

private struct AVQReader {
    let raw: UnsafeRawBufferPointer
    func word(_ offset: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    func position(_ shape: AVQShape, _ i: Int) -> V3 {
        let p = shape.positionOffset + 12 * i
        return [Float(bitPattern: word(p)), Float(bitPattern: word(p + 4)), Float(bitPattern: word(p + 8))]
    }
    func triangles(_ shape: AVQShape, _ visit: (V3, V3, V3) -> Void) throws {
        guard let start = shape.indexOffset else { throw AVQPackageError("Missing triangle indices") }
        for i in stride(from: 0, to: shape.indexCount, by: 3) {
            let base = start + 4 * i
            let a = Int(word(base)), b = Int(word(base + 4)), c = Int(word(base + 8))
            guard max(a, max(b, c)) < shape.vertexCount else { throw AVQPackageError("Triangle references an absent vertex") }
            visit(position(shape, a), position(shape, b), position(shape, c))
        }
    }
    // The longest actual indexed source edge locates a trim below display precision.
    func thinEdge(_ source: AVQShape.Source) throws -> (V3, V3) {
        func value(_ start: Int) -> Double {
            Double(bitPattern: UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: start, as: UInt64.self)))
        }
        func vertex(_ i: Int) throws -> SIMD3<Double> {
            guard i < source.vertexCount else { throw AVQPackageError("Invalid source triangle vertex") }
            let start = source.positionOffset + i * 24
            return [value(start), value(start + 8), value(start + 16)]
        }
        var best = -Double.infinity
        var ends = (SIMD3<Double>.zero, SIMD3<Double>.zero)
        for i in stride(from: 0, to: source.indexCount, by: 3) {
            let start = source.indexOffset + i * 4
            let a = try vertex(Int(word(start))), b = try vertex(Int(word(start + 4))), c = try vertex(Int(word(start + 8)))
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let d = simd_length_squared(q - p)
                if d > best { best = d; ends = (p, q) }
            }
        }
        return (V3(ends.0), V3(ends.1))
    }
}

private struct AVQPrepared: Sendable {
    var faces = AVQMesh()
    var markers = AVQMesh()
    var depth = AVQMesh()
    var parts: [AVQPart] = []
    var thinTrimLocatorCount = 0

    static func make(package: AVQPackage, selection: AVQSelection, visibility: AVQVisibility,
                     spacing: Float, lineRadius: Float, pointRadius: Float) throws -> Self {
        var output = Self()
        output.parts = try package.displayParts(for: selection, using: visibility)
        return try package.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Self in
            let reader = AVQReader(raw: bytes)
            var seen: Set<String> = []
            for part in output.parts {
                try Task.checkCancellation()
                for id in part.shapeIds where seen.insert(id).inserted {
                    guard let shape = package.shapes[id] else { throw AVQPackageError("Unknown shape " + id) }
                    switch shape.primitive {
                    case .triangles:
                        let facesBefore = output.faces.indices.count
                        try reader.triangles(shape) { a, b, c in output.faces.triangle(a, b, c, spacing: spacing) }
                        if selection.partId != nil, facesBefore == output.faces.indices.count,
                           shape.renderAreaBelowWorldFloat32Precision == true, let source = shape.sourceFloat64 {
                            let (a, b) = try reader.thinEdge(source)
                            if simd_length_squared(b - a) > 1e-12 { output.markers.tube(from: a, to: b, radius: lineRadius) }
                            else { output.markers.dot(at: a, radius: pointRadius) }
                            output.thinTrimLocatorCount += 1
                        }
                    case .polyline:
                        for i in 1..<shape.vertexCount {
                            output.markers.tube(from: reader.position(shape, i - 1), to: reader.position(shape, i), radius: lineRadius)
                        }
                    case .point:
                        for i in 0..<shape.vertexCount { output.markers.dot(at: reader.position(shape, i), radius: pointRadius) }
                    }
                }
            }
            if selection.partId == nil && selection.reviewId == nil && package.maskArticles.contains(selection.articleId) {
                for cap in package.masks where package.isVisible(cap.elementId, using: visibility) {
                    try Task.checkCancellation()
                    for id in cap.shapeIds {
                        guard let shape = package.shapes[id] else { throw AVQPackageError("Unknown pane mask " + id) }
                        try reader.triangles(shape) { a, b, c in output.depth.triangle(a, b, c) }
                    }
                }
            }
            return output
        }
    }
}

private enum AVQPicker {
    static func segmentSquared(_ p: V3, _ a: V3, _ b: V3) -> Float {
        let ab = b - a, d = simd_length_squared(ab)
        guard d > 1e-18 else { return simd_length_squared(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / d))
        return simd_length_squared(p - (a + t * ab))
    }

    static func triangleSquared(_ p: V3, _ a: V3, _ b: V3, _ c: V3) -> Float {
        let n = simd_cross(b - a, c - a), squared = simd_length_squared(n)
        if squared > 1e-18 {
            let signed = simd_dot(p - a, n)
            let q = p - (signed / squared) * n
            if simd_dot(simd_cross(b - a, q - a), n) >= 0,
               simd_dot(simd_cross(c - b, q - b), n) >= 0,
               simd_dot(simd_cross(a - c, q - c), n) >= 0 { return signed * signed / squared }
        }
        return min(segmentSquared(p, a, b), min(segmentSquared(p, b, c), segmentSquared(p, c, a)))
    }

    static func nearest(point: V3, tolerance: Float, parts: [AVQPart], package: AVQPackage) throws -> [AVQPart] {
        try package.bytes.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [AVQPart] in
            let reader = AVQReader(raw: bytes)
            var cache: [String: Float] = [:]
            var results: [(AVQPart, Float)] = []
            var best = tolerance
            for part in parts {
                try Task.checkCancellation()
                var distance: Float = .infinity
                for id in part.shapeIds {
                    if let known = cache[id] { distance = min(known, distance); continue }
                    guard let s = package.shapes[id] else { continue }
                    let a = s.bounds[0], b = s.bounds[1]
                    guard point.x >= a[0] - tolerance && point.x <= b[0] + tolerance,
                          point.y >= a[1] - tolerance && point.y <= b[1] + tolerance,
                          point.z >= a[2] - tolerance && point.z <= b[2] + tolerance
                    else { continue }
                    var d: Float = .infinity
                    switch s.primitive {
                    case .triangles:
                        try reader.triangles(s) { a, b, c in d = min(d, triangleSquared(point, a, b, c)) }
                    case .polyline:
                        for i in 1..<s.vertexCount { d = min(d, segmentSquared(point, reader.position(s, i-1), reader.position(s, i))) }
                    case .point:
                        for i in 0..<s.vertexCount { d = min(d, simd_length_squared(point - reader.position(s, i))) }
                    }
                    let metres = sqrt(d)
                    cache[id] = metres
                    distance = min(distance, metres)
                }
                if distance <= tolerance {
                    best = min(best, distance)
                    results.append((part, distance))
                }
            }
            // One-millimetre ties let the caller offer multiple co-located source roles.
            return results.compactMap { $0.1 <= best + 0.001 ? $0.0 : nil }
        }
    }
}
