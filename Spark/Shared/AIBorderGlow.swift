import SwiftUI

struct AIBorderGlow: View {
    let isActive: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !isActive || reduceMotion)) { timeline in
            let colors: [Color] = [.teal, .blue, .purple, .pink, .orange, .teal]
            let phase =
                reduceMotion
                ? 0
                : timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 18) / 18 * 360
            let gradient = AngularGradient(
                colors: colors, center: .center, angle: .degrees(phase))
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(gradient, lineWidth: 4)
                    .blur(radius: 6)
                    .opacity(0.42)
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(gradient, lineWidth: 1.2)
                    .opacity(0.9)
            }
        }
        .opacity(isActive ? 1 : 0)
        .animation(.easeInOut(duration: reduceMotion ? 0.15 : 0.45), value: isActive)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
