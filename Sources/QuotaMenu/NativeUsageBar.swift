import SwiftUI

/// A read-only quota bar, not an interactive slider. Two stock SwiftUI capsules
/// give used/remaining a predictable distinction on a translucent native menu.
/// No parent appearance, menu material, positioning or control sizing is changed.
struct NativeUsageBar: View {
    let used: Double
    let scheme: ColorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    static let height: CGFloat = 4

    var fraction: Double { used.isFinite ? min(1, max(0, used)) : 0 }
    private var ink: Color { scheme == .dark ? .white : .black }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(ink.opacity(contrast == .increased ? 0.15 : 0.10))
                Capsule().fill(ink.opacity(contrast == .increased ? 0.70 : 0.50))
                    .frame(width: geometry.size.width * fraction)
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: Self.height)
        .accessibilityLabel("Weekly quota used")
        .accessibilityValue("\(Int((fraction * 100).rounded()))% used")
    }
}
