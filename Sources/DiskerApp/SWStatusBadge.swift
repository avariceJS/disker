import SwiftUI

/// ShipSwift status-badge recipe adapted for Disker's native macOS palette.
/// The label is intentionally compact and carries meaning, not decoration.
enum SWStatusBadgeStyle {
    case info
    case success
    case warning
    case neutral

    var tint: Color {
        switch self {
        case .info: .blue
        case .success: .green
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

struct SWStatusBadge: View {
    let text: LocalizedStringKey
    let style: SWStatusBadgeStyle

    init(text: LocalizedStringKey, style: SWStatusBadgeStyle) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(style.tint)
            .background(Capsule().fill(style.tint.opacity(0.14)))
            .overlay(Capsule().stroke(style.tint.opacity(0.3), lineWidth: 0.5))
            .accessibilityAddTraits(.isStaticText)
    }
}
