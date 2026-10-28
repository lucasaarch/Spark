import SwiftUI

// Adapted from ThinkingOrbsKit 0.3.1 (MIT), copyright 2026 Jakub Antalik.
// Only the working/orbits 20pt preset is included. See ThirdPartyNotices.txt.
struct WorkingOrb: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        Group {
            if reduceMotion {
                canvas(time: 0.6 * 3.9)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !visible)) { clock in
                    canvas(time: clock.date.timeIntervalSinceReferenceDate * 3.9)
                }
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)  // The adjacent status label describes the state.
    }

    private func canvas(time: Double) -> some View {
        Canvas { context, size in
            var context = context
            context.scaleBy(x: size.width / 20, y: size.height / 20)
            for dot in WorkingOrbGeometry.frame(at: time) {
                let rect = CGRect(
                    x: dot.x - dot.radius, y: dot.y - dot.radius,
                    width: dot.radius * 2, height: dot.radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color.opacity(dot.opacity)))
            }
        }
    }
}

/// The selected preset has three orbits, ten ghost dots and three moving particles
/// per orbit. Its fixed geometry is cached; only projection and particle motion vary.
enum WorkingOrbGeometry {
    struct Dot: Equatable {
        let x: Double, y: Double, depth: Double, radius: Double, opacity: Double
    }

    private struct Orbit {
        let radius: Double
        let basisUX: Double, basisUY: Double, basisVX: Double, basisVY: Double, basisVZ: Double
        let speed: Double, phase: Double
    }

    private static func hash(_ a: Double, _ b: Double) -> Double {
        let value = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return value - floor(value)
    }

    private static let orbits: [Orbit] = (0..<3).map { index in
        let radiusSeed = hash(Double(index), 1.7), phaseSeed = hash(Double(index), 5.2),
            speedSeed = hash(Double(index), 8.9)
        let theta = radiusSeed * 2 * Double.pi, phi = acos(2 * phaseSeed - 1)
        let normalX = sin(phi) * cos(theta), normalY = cos(phi), normalZ = sin(phi) * sin(theta)
        let length = max(1e-6, sqrt(normalY * normalY + normalX * normalX))
        let basisUX = -normalY / length, basisUY = normalX / length
        return Orbit(
            radius: 8.2 * (0.45 + 0.52 * radiusSeed), basisUX: basisUX, basisUY: basisUY,
            basisVX: -normalZ * basisUY, basisVY: normalZ * basisUX, basisVZ: normalX * basisUY - normalY * basisUX,
            speed: (0.25 + 0.55 * speedSeed) * (speedSeed > 0.5 ? 1 : -1), phase: phaseSeed * 6)
    }
    private static let radiusScale = pow(20.0 / 300, 0.6) * 2.4

    static func frame(at time: Double) -> [Dot] {
        let sinYaw = sin(time * 0.12), cosYaw = cos(time * 0.12)
        let sinTilt = sin(0.3), cosTilt = cos(0.3)
        var dots: [Dot] = []
        dots.reserveCapacity(39)
        for orbit in orbits {
            func dot(angle: Double, particle: Bool) -> Dot {
                let cosAngle = cos(angle), sinAngle = sin(angle)
                let x = (orbit.basisUX * cosAngle + orbit.basisVX * sinAngle) * orbit.radius
                let y = (orbit.basisUY * cosAngle + orbit.basisVY * sinAngle) * orbit.radius
                let depth = orbit.basisVZ * sinAngle * orbit.radius
                let rotatedX = x * cosYaw + depth * sinYaw, rotatedZ = -x * sinYaw + depth * cosYaw
                let projectedY = y * cosTilt - rotatedZ * sinTilt, projectedZ = y * sinTilt + rotatedZ * cosTilt
                let normalizedDepth = (projectedZ / orbit.radius + 1) / 2
                let radius = (particle ? 1.2 + 1.6 * normalizedDepth : 0.9) * radiusScale
                let opacity = particle ? 0.7 + 0.22 * normalizedDepth : 0.28 * 0.5 * (0.4 + 0.6 * normalizedDepth)
                return Dot(
                    x: 10 + rotatedX, y: 10 - projectedY, depth: projectedZ, radius: max(0.3, radius), opacity: opacity)
            }
            for index in 0..<10 { dots.append(dot(angle: Double(index) / 10 * 2 * .pi, particle: false)) }
            for index in 0..<3 {
                dots.append(dot(angle: time * orbit.speed + Double(index) / 3 * 2 * .pi + orbit.phase, particle: true))
            }
        }
        return dots.enumerated().sorted {
            $0.element.depth == $1.element.depth ? $0.offset < $1.offset : $0.element.depth < $1.element.depth
        }.map(\.element)
    }
}
