import SwiftUI

/// System (SF Pro) type, sized for a compact desktop interface.
enum Typography {
    static let display = Font.system(size: 30, weight: .semibold)
    static let pageTitle = Font.system(size: 23, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let heading = Font.system(size: 16, weight: .semibold)
    static let nav = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let row = Font.system(size: 12)
    static let rowMedium = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .semibold)
    static let eyebrow = Font.system(size: 10, weight: .bold)
    static let mono = Font.system(size: 11, design: .monospaced)
    static let timestamp = Font.system(size: 10, design: .monospaced)
}
