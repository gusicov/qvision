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

    static func new(name: String) -> Project {
        Project(name: name, layers: [Layer(name: "Default")])
    }

    /// First layer; new items go here. A project always has at least one layer.
    var defaultLayerID: UUID { layers.first?.id ?? UUID() }

    func layer(_ id: UUID) -> Layer? { layers.first { $0.id == id } }
}
