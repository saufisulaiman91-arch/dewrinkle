import Foundation

public enum SourceContainer: String, Equatable, Sendable {
    case jpeg
    case tiff
    case png
    case other

    public init(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            self = .jpeg
        case "tif", "tiff":
            self = .tiff
        case "png":
            self = .png
        default:
            self = .other
        }
    }
}

public enum ExportContainer: String, Equatable, Sendable, CaseIterable {
    case tiff16
    case jpeg
    case png16

    public var fileExtension: String {
        switch self {
        case .tiff16: return "tif"
        case .jpeg: return "jpg"
        case .png16: return "png"
        }
    }

    public var menuTitle: String {
        switch self {
        case .tiff16: return "16-bit TIFF"
        case .jpeg: return "JPEG"
        case .png16: return "16-bit PNG"
        }
    }
}

public struct ExportSettings: Equatable, Sendable {
    public var container: ExportContainer
    /// 0...1, used for JPEG only. 0.92 is the default a client file should leave with.
    public var jpegQuality: Float

    public static let defaultJPEGQuality: Float = 0.92

    public init(container: ExportContainer, jpegQuality: Float = ExportSettings.defaultJPEGQuality) {
        self.container = container
        self.jpegQuality = min(max(jpegQuality, 0.01), 1)
    }

    /// JPEG in defaults to JPEG out. TIFF in defaults to 16-bit TIFF out.
    public static func matching(source: SourceContainer) -> ExportSettings {
        switch source {
        case .jpeg:
            return ExportSettings(container: .jpeg)
        case .tiff:
            return ExportSettings(container: .tiff16)
        case .png:
            return ExportSettings(container: .png16)
        case .other:
            return ExportSettings(container: .tiff16)
        }
    }
}
