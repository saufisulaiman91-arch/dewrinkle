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
    var noise: NoiseReductionParameters

    static func background() -> EditLayer {
        EditLayer(
            id: UUID(),
            name: "Background",
            isBackground: true,
            visible: true,
            opacity: 1,
            mask: MaskDocument(),
            dewrinkleOn: false,
            dewrinkle: .standard,
            noise: .off
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
            dewrinkle: .standard,
            noise: .off
        )
    }
}

struct EditSnapshot: Equatable {
    var turns: [PictureTurn]
    var layers: [EditLayer]
    var selectedLayerID: UUID
    var brush: BrushSettings
}

enum CanvasTool: String, Equatable {
    case brush
    case clickSelect
}
