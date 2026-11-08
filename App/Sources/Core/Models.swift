import Foundation
import RealityKit
import simd

// Shared data model (orchestrator-owned). Everything here is Codable and persisted
// as Documents/Projects/<id>/project.json.

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case mixed   // passthrough: models in your real room
    case full    // fully immersive: generated environment only

    var id: String { rawValue }
    var title: String { self == .mixed ? "Mixed" : "Immersive" }
    var systemImage: String { self == .mixed ? "eye" : "mountain.2" }
}

enum EnvironmentPreset: String, Codable, CaseIterable, Identifiable {
    case studio, daylight, sunset, night

    var id: String { rawValue }
    var title: String {
        switch self {
        case .studio: return "Studio"
        case .daylight: return "Daylight"
        case .sunset: return "Sunset"
        case .night: return "Night"
        }
    }
}

/// RealityKit `Transform` in a Codable form. Rotation is stored as quaternion (ix, iy, iz, r).
struct StoredTransform: Codable, Hashable {
    var position: SIMD3<Float>
    var rotation: SIMD4<Float>
    var scale: SIMD3<Float>

    static let identity = StoredTransform(position: .zero, rotation: [0, 0, 0, 1], scale: .one)

    init(position: SIMD3<Float>, rotation: SIMD4<Float>, scale: SIMD3<Float>) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    init(_ t: Transform) {
        position = t.translation
        rotation = t.rotation.vector
        scale = t.scale
    }

    var transform: Transform {
        Transform(scale: scale, rotation: simd_quatf(vector: rotation), translation: position)
    }
}

struct Layer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var isVisible: Bool = true
    var isLocked: Bool = false
}

struct ProjectItem: Codable, Identifiable, Hashable {
    enum Primitive: String, Codable { case cube }

    var id: UUID = UUID()
    var name: String
    /// File name inside the project's Assets folder (nil for primitives).
    var assetFileName: String?
    var primitive: Primitive?
    var layerID: UUID
    var transform: StoredTransform = .identity
    /// Where the item was first placed; "Reset scene" returns here.
    var initialTransform: StoredTransform = .identity
    var isHidden: Bool = false
    /// Internal parts (USD hierarchy paths) the user hid in Inspect mode. Optional for old JSON.
    var hiddenPartPaths: [String]? = nil

    var hiddenParts: Set<String> { Set(hiddenPartPaths ?? []) }
}

struct Project: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()
    var viewMode: ViewMode = .mixed
    var environment: EnvironmentPreset = .studio
    var layers: [Layer]
    var items: [ProjectItem] = []
    // v0.3 settings. Optional so projects saved by v0.2 still decode.
    var sceneScalePercent: Double? = nil   // 1...100, nil = 100 (real scale)
    var isTabletop: Bool? = nil            // lift scaled content to table height
    var snapToFloor: Bool? = nil           // nil = true

    var scenePercent: Double { min(max(sceneScalePercent ?? 100, 1), 100) }
    var tabletop: Bool { isTabletop ?? false }
    var snapsToFloor: Bool { snapToFloor ?? true }

    static func new(name: String) -> Project {
        Project(name: name, layers: [Layer(name: "Default")])
    }

    /// First layer; new items go here. A project always has at least one layer.
    var defaultLayerID: UUID { layers.first?.id ?? UUID() }

    func layer(_ id: UUID) -> Layer? { layers.first { $0.id == id } }
}

// MARK: - v0.3: interaction + inspection

enum InteractionMode: String, CaseIterable, Identifiable {
    case edit      // move / scale / rotate
    case inspect   // nothing moves; tap shows information

    var id: String { rawValue }
    var title: String { self == .edit ? "Edit" : "Inspect" }
    var systemImage: String { self == .edit ? "hand.draw" : "info.circle" }
}

/// One node of a model's internal hierarchy (the "layers inside the USDZ").
struct PartInfo: Identifiable, Hashable {
    let id: String              // path, e.g. "Building/Floor_2/Wall_12"
    let name: String
    let depth: Int              // 0 = top-level child of the model
    let isMesh: Bool
    let triangleCount: Int      // this node + descendants
    let vertexCount: Int
    let materialCount: Int
    let size: SIMD3<Float>      // world-scale meters (incl. item scale, excl. scene scale)
    var isHidden: Bool
}

struct InspectionInfo: Equatable {
    let itemID: UUID
    let itemName: String
    let fileName: String?
    let fileSizeBytes: Int64?
    let size: SIMD3<Float>      // real meters (incl. item scale, excl. scene scale)
    let triangleCount: Int
    let vertexCount: Int
    let meshCount: Int
    let materialCount: Int
    let animationCount: Int
    let parts: [PartInfo]       // depth-first order
    let selectedPartID: String?
}
