import SwiftUI

enum Theme {
    static let window = Color(red: 0.102, green: 0.098, blue: 0.094)
    static let canvas = Color(red: 0.067, green: 0.065, blue: 0.062)
    static let panel = Color(red: 0.145, green: 0.138, blue: 0.128)
    static let primary = Color(red: 0.93, green: 0.91, blue: 0.86)
    static let secondary = Color(red: 0.73, green: 0.69, blue: 0.62)
    static let tertiary = Color(red: 0.55, green: 0.51, blue: 0.45)
    static let accent = Color(red: 0.86, green: 0.64, blue: 0.40)
    static let hairline = Color.white.opacity(0.08)
    static let fill = Color.white.opacity(0.05)
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.15)
                .foregroundStyle(Theme.tertiary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PercentSlider: View {
    let title: String
    let hint: String
    @Binding var percent: Double
    var range: ClosedRange<Double> = 0...100

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Text("\(Int(percent.rounded()))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, alignment: .trailing)
            }
            Slider(value: $percent, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
            Text(hint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
