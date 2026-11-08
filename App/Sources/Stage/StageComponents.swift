import Foundation
import RealityKit

/// Marks the root entity of a project item on the stage. Gestures walk up the
/// parent chain until they find this component to resolve which item was hit.
struct ItemComponent: Component {
    var id: UUID
}

/// Registers the stage's custom RealityKit components. Called once from `QVisionApp.init()`.
enum StageComponents {
    private static var isRegistered = false

    static func register() {
        guard !isRegistered else { return }
        isRegistered = true
        ItemComponent.registerComponent()
    }
}
