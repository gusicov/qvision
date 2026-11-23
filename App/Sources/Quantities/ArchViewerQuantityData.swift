import CryptoKit
import Foundation

// Add this file and ArchViewerQuantities.swift to the same visionOS target.
struct AVQArticle: Decodable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable { case numeric, subtotal, shared, unresolved, sourceCount }
    enum Value: Decodable, Sendable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let number = try? value.decode(Double.self) { self = .number(number) }
            else { self = .text(try value.decode(String.self)) }
        }
    }
    struct Review: Decodable, Identifiable, Sendable {
        let reviewId, label, unit, displayQuantity: String
        let basis: Double
        let includedInPrimary: Bool
        var id: String { reviewId }
    }
    let articleId, stableId, title, zone, reference: String
    let code, sourceStatus, sourceBuilding: String?
    let row: Int
    let page, position: Int?
    let sourceUnit, displayUnit, measurementNote, workbookRule, status: String
    let quantityCell: String?
    let quantityKind: Kind
    let quantity: Value?
    let displayQuantity, sharedWithArticleId: String?
    let basis: Double?
    let basisUnit: String
    let reviews: [Review]
    var id: String { articleId }
}

struct AVQPart: Decodable, Identifiable, Sendable {
    let partId, elementId, group, section, level, facade, evidence, nativeSelection: String
    let rhinoGuid, role, geometryRepresentation, basisUnit: String?
    let basis: Double?
    var shapeIds: [String]
    var shapeElementIds: [String]?
    var id: String { partId }
}

struct AVQSelection: Equatable, Sendable {
    let articleId: String
    var reviewId: String? = nil
    var partId: String? = nil
    var level: String? = nil
}

struct AVQElement: Decodable, Identifiable, Sendable {
    let elementId, entityName, primPath, layerId, kind: String
    let rhinoGuid: String?
    let parentElementId: String?
    let defaultVisible: Bool
    var id: String { elementId }
}

struct AVQLayer: Decodable, Identifiable, Sendable {
    let layerId, name, fullPath, entityName, primPath: String
    let parentId: String?
    let defaultVisible, defaultEnabled: Bool
    var id: String { layerId }
}

struct AVQUses: Decodable, Sendable {
    struct Review: Decodable, Sendable { let articleId, reviewId: String }
    let primary, hostedPrimary, referenceOnly: [String]?
    let reviews: [Review]?
}

// Explicit browse-time overrides. A hidden source helper can carry a visible quantity.
struct AVQVisibility: Equatable, Sendable {
    var hiddenLayerIds: Set<String> = []
    var hiddenElementIds: Set<String> = []
}

struct AVQPackageError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct AVQShape: Decodable, Sendable {
    enum Primitive: String, Decodable, Sendable { case triangles, polyline, point }
    struct Source: Decodable, Sendable { let positionOffset, vertexCount, indexOffset, indexCount: Int }
    let primitive: Primitive
    let positionOffset, vertexCount, indexCount: Int
    let normalOffset, indexOffset: Int?
    let bounds: [[Float]]
    let sourceFloat64: Source?
    let renderAreaBelowWorldFloat32Precision: Bool?
}

struct AVQMask: Decodable, Sendable {
    let elementId: String
    let shapeIds: [String]
}

struct AVQPackage: Sendable {
    private struct Manifest: Decodable {
        struct Model: Decodable { let path: String; let contextPath: String? }
        struct File: Decodable { let sha256: String; let bytes: Int }
        struct Presentation: Decodable { let drawSelectionThroughContext: Bool? }
        let schemaVersion: Int
        let packageId: String
        let model: Model
        let presentation: Presentation?
        let files: [String: File]
    }
    private struct Catalogue: Decodable { let schemaVersion: Int; let packageId: String; let articles: [AVQArticle] }
    private struct Elements: Decodable { let schemaVersion: Int; let elements: [AVQElement]; let layers: [AVQLayer] }
    private struct Reverse: Decodable { let schemaVersion: Int; let elements: [String: AVQUses] }
    private struct Geometry: Decodable { let schemaVersion, byteLength: Int; let sha256: String; let shapes: [String: AVQShape] }
    private struct Masks: Decodable { let schemaVersion: Int; let articleIds: [String]; let masks: [AVQMask] }
    private struct Register: Decodable { let schemaVersion: Int; let articles: [String: Scopes] }
    private struct Scopes: Decodable, Sendable {
        struct Review: Decodable, Sendable { let reviewId: String; let parts: [AVQPart] }
        let primary: [AVQPart]
        let reviews: [Review]
    }

    let packageId: String
    let drawSelectionThroughContext: Bool
    let modelURL, hatchURL: URL
    let contextModelURL: URL?
    let articles: [AVQArticle]
    let elements: [String: AVQElement]
    let layers: [String: AVQLayer]
    let elementByEntityName: [String: String]
    let usesByElement: [String: AVQUses]
    let shapes: [String: AVQShape]
    let bytes: Data
    let maskArticles: Set<String>
    let masks: [AVQMask]
    private let scopes: [String: Scopes]

    static func open(at directory: URL) async throws -> Self {
        try await Task.detached(priority: .userInitiated) { try Self(directory: directory) }.value
    }

    private init(directory: URL) throws {
        let decoder = JSONDecoder()
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        func url(_ relative: String) throws -> URL {
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.contains(""), !parts.contains("."), !parts.contains(".."), !relative.contains("\\") else {
                throw AVQPackageError("Invalid package member " + relative)
            }
            let result = root.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
            guard result.path.hasPrefix(root.path + "/") else { throw AVQPackageError("Invalid package location") }
            return result
        }
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: url("manifest.json")))
        guard manifest.schemaVersion == 1 else { throw AVQPackageError("Unsupported package version") }
        func checked(_ path: String) throws -> Data {
            guard let record = manifest.files[path] else { throw AVQPackageError("Unlisted file " + path) }
            let data = try Data(contentsOf: url(path), options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == record.bytes, hash == record.sha256.lowercased() else {
                throw AVQPackageError("File does not match this project revision: " + path)
            }
            return data
        }
        func read<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            try decoder.decode(type, from: checked(path))
        }
        func unique<T>(_ values: [T], key: (T) -> String) throws -> [String: T] {
            var index: [String: T] = [:]
            for value in values {
                let id = key(value)
                guard index.updateValue(value, forKey: id) == nil else { throw AVQPackageError("Duplicate ID " + id) }
            }
            return index
        }
        let catalogue = try read(Catalogue.self, "Data/articles.json")
        let scene = try read(Elements.self, "Data/elements.json")
        let register = try read(Register.self, "Data/selections.json")
        let reverse = try read(Reverse.self, "Data/element-articles.json")
        let geometry = try read(Geometry.self, "Data/geometry.json")
        let windows = try read(Masks.self, "Data/windowDepthMasks.json")
        let buffer = try checked("Data/geometry.bin")
        let texturePath = "Integration/Hatch.png"
        _ = try checked(texturePath)
        _ = try checked(manifest.model.path)
        if let contextPath = manifest.model.contextPath {
            _ = try checked(contextPath)
            contextModelURL = try url(contextPath)
        } else { contextModelURL = nil }
        guard [catalogue.schemaVersion, scene.schemaVersion, register.schemaVersion,
               reverse.schemaVersion, geometry.schemaVersion, windows.schemaVersion].allSatisfy({ $0 == 1 }),
              catalogue.packageId == manifest.packageId,
              geometry.byteLength == buffer.count,
              geometry.sha256.lowercased() == manifest.files["Data/geometry.bin"]?.sha256.lowercased()
        else { throw AVQPackageError("The catalogue, model and geometry revisions do not match") }
        let articleIndex = try unique(catalogue.articles) { $0.articleId }
        let elementIndex = try unique(scene.elements) { $0.elementId }
        let layerIndex = try unique(scene.layers) { $0.layerId }
        let names = try unique(scene.elements) { $0.entityName }
        guard Set(register.articles.keys) == Set(articleIndex.keys) else { throw AVQPackageError("Incomplete article register") }
        for (key, scope) in register.articles {
            let reviewIds = Set(articleIndex[key]?.reviews.map(\.reviewId) ?? [])
            guard Set(scope.reviews.map(\.reviewId)) == reviewIds else { throw AVQPackageError("Review index mismatch for " + key) }
            for parts in [scope.primary] + scope.reviews.map(\.parts) {
                for part in parts {
                    guard elementIndex[part.elementId] != nil, part.shapeIds.allSatisfy({ geometry.shapes[$0] != nil })
                    else { throw AVQPackageError("Missing model or shape for " + part.partId) }
                    if let physical = part.shapeElementIds {
                        guard physical.count == part.shapeIds.count, physical.allSatisfy({ elementIndex[$0] != nil })
                        else { throw AVQPackageError("Missing source component for " + part.partId) }
                    }
                }
            }
        }
        for (id, shape) in geometry.shapes {
            func rangeFits(_ offset: Int, _ count: Int, stride: Int) -> Bool {
                offset >= 0 && offset % 4 == 0 && offset <= buffer.count &&
                count >= 0 && count <= (buffer.count - offset) / stride
            }
            guard rangeFits(shape.positionOffset, shape.vertexCount, stride: 12), shape.vertexCount > 0,
                  shape.bounds.count == 2, shape.bounds.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) })
            else { throw AVQPackageError("Invalid position range for " + id) }
            if let offset = shape.normalOffset, !rangeFits(offset, shape.vertexCount, stride: 12) {
                throw AVQPackageError("Invalid normal range for " + id)
            }
            if shape.primitive == .triangles {
                guard let offset = shape.indexOffset, shape.indexCount > 0, shape.indexCount % 3 == 0,
                      rangeFits(offset, shape.indexCount, stride: 4)
                else { throw AVQPackageError("Invalid triangle range for " + id) }
            }
            if let source = shape.sourceFloat64 {
                guard source.positionOffset % 8 == 0, source.vertexCount > 0,
                      rangeFits(source.positionOffset, source.vertexCount, stride: 24),
                      source.indexCount > 0, source.indexCount % 3 == 0,
                      rangeFits(source.indexOffset, source.indexCount, stride: 4)
                else { throw AVQPackageError("Invalid high-precision source range for " + id) }
            }
        }
        self.packageId = catalogue.packageId
        drawSelectionThroughContext = manifest.presentation?.drawSelectionThroughContext ?? false
        modelURL = try url(manifest.model.path)
        hatchURL = try url(texturePath)
        articles = catalogue.articles
        elements = elementIndex
        layers = layerIndex
        elementByEntityName = names.mapValues(\.elementId)
        usesByElement = reverse.elements
        shapes = geometry.shapes
        bytes = buffer
        maskArticles = Set(windows.articleIds)
        masks = windows.masks
        scopes = register.articles
    }

    func parts(for selection: AVQSelection) throws -> [AVQPart] {
        guard let scope = scopes[selection.articleId] else { throw AVQPackageError("Unknown article " + selection.articleId) }
        var parts = scope.primary
        if let id = selection.reviewId {
            guard let review = scope.reviews.first(where: { $0.reviewId == id }) else { throw AVQPackageError("Unknown review " + id) }
            parts = review.parts
        }
        if let level = selection.level { parts = parts.filter { $0.level == level } }
        if let id = selection.partId {
            guard let part = parts.first(where: { $0.partId == id }) else { throw AVQPackageError("Unknown part " + id) }
            return [part]
        }
        return parts
    }

    func displayParts(for selection: AVQSelection, using filter: AVQVisibility) throws -> [AVQPart] {
        let all = try parts(for: selection)
        if filter == AVQVisibility() { return all }
        return all.compactMap { part in
            guard isVisible(part.elementId, using: filter) else { return nil }
            guard let owners = part.shapeElementIds else { return part }
            let visible = zip(part.shapeIds, owners).filter { isVisible($0.1, using: filter) }
            guard !visible.isEmpty else { return nil }
            var result = part
            result.shapeIds = visible.map { $0.0 }
            result.shapeElementIds = visible.map { $0.1 }
            return result
        }
    }

    func isVisible(_ elementId: String, using filter: AVQVisibility) -> Bool {
        if filter.hiddenLayerIds.isEmpty && filter.hiddenElementIds.isEmpty { return true }
        var next: String? = elementId
        var visited: Set<String> = []
        while let id = next, let item = elements[id], visited.insert(id).inserted {
            if filter.hiddenElementIds.contains(id) { return false }
            var layer: String? = item.layerId
            var seenLayers: Set<String> = []
            while let key = layer, seenLayers.insert(key).inserted {
                if filter.hiddenLayerIds.contains(key) { return false }
                layer = layers[key]?.parentId
            }
            next = item.parentElementId
        }
        return true
    }
}
