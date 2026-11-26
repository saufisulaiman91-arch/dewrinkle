import Foundation
import DewrinkleCore

struct EditLayer: Identifiable, Equatable {
    var id: UUID
    var name: String
    var isBackground: Bool
    var visible: Bool
    var opacity: Float
    var mask: MaskDocument
    var dewrinkleOn: Bool
    var dewrinkle: DewrinkleParameters

    static func background() -> EditLayer {
        EditLayer(
            id: UUID(),
            name: "Background",
            isBackground: true,
            visible: true,
            opacity: 1,
            mask: MaskDocument(),
            dewrinkleOn: false,
            dewrinkle: .standard
        )
    }

    static func dewrinkle(index: Int) -> EditLayer {
        EditLayer(
            id: UUID(),
            name: index == 1 ? "De-wrinkle" : "De-wrinkle \(index)",
            isBackground: false,
            visible: true,
            opacity: 1,
            mask: MaskDocument(),
            dewrinkleOn: true,
            dewrinkle: .detected
        )
    }
}

struct EditSnapshot: Equatable {
    var turns: [PictureTurn]
    var layers: [EditLayer]
    var selectedLayerID: UUID
    var brush: BrushSettings
    var detectionSensitivity: Float
    var includeHijab: Bool
}

enum CanvasTool: String, Equatable {
    case brush
    case clickSelect
}
