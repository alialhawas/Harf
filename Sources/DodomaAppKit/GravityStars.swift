import SwiftUI

/// The gravity-stars background, ported from Animate UI.
///
/// Animate UI ships React components, which cannot be dropped into an AppKit
/// app — but the simulation behind this one is a few lines of arithmetic and
/// carries over exactly. Constants, force curve, glow easing, drift damping and
/// edge wrapping are all the upstream values, so the motion matches the web
/// original rather than merely resembling it.
///
/// Credit: Animate UI (imskyleen), `components/backgrounds/gravity-stars`.
struct GravityStarsBackground: View {
    var starCount: Int = 75
    var starSize: CGFloat = 2
    var starOpacity: Double = 0.75
    var glowIntensity: CGFloat = 15
    var movementSpeed: CGFloat = 0.3
    var mouseInfluence: CGFloat = 100
    var gravityStrength: CGFloat = 75
    var starColor: Color = .white

    @State private var field = StarField()
    @State private var pointer: CGPoint? = nil

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                field.advance(
                    in: size, pointer: pointer, at: timeline.date,
                    influence: mouseInfluence, gravity: gravityStrength,
                    speed: movementSpeed, baseOpacity: starOpacity, maxSize: starSize)

                for star in field.stars {
                    // Two passes stand in for the canvas shadow the web version
                    // leans on: a wide, faint disc for the bloom and the star
                    // itself on top. `glow` rises as the pointer nears, so the
                    // field brightens under the cursor exactly as upstream.
                    let bloom = star.size * (2.5 + glowIntensity * 0.08 * star.glow)
                    let halo = Path(ellipseIn: CGRect(
                        x: star.x - bloom, y: star.y - bloom,
                        width: bloom * 2, height: bloom * 2))
                    context.fill(
                        halo,
                        with: .color(starColor.opacity(star.opacity * 0.10 * star.glow)))

                    let disc = Path(ellipseIn: CGRect(
                        x: star.x - star.size, y: star.y - star.size,
                        width: star.size * 2, height: star.size * 2))
                    context.fill(disc, with: .color(starColor.opacity(star.opacity)))
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): pointer = location
            case .ended: pointer = nil
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The simulation itself, kept out of the view so the maths stays readable.
///
/// A reference type on purpose: `Canvas` re-renders many times a second and the
/// field has to be mutated in place rather than copied per frame.
private final class StarField {
    struct Star {
        var x: CGFloat, y: CGFloat
        var vx: CGFloat, vy: CGFloat
        var size: CGFloat
        var opacity: Double
        var baseOpacity: Double
        var glow: CGFloat
    }

    private(set) var stars: [Star] = []
    private var bounds: CGSize = .zero
    private var lastTick: Date?

    func advance(
        in size: CGSize, pointer: CGPoint?, at now: Date,
        influence: CGFloat, gravity: CGFloat, speed: CGFloat,
        baseOpacity: Double, maxSize: CGFloat
    ) {
        if stars.isEmpty || bounds != size {
            seed(in: size, speed: speed, baseOpacity: baseOpacity, maxSize: maxSize)
            bounds = size
        }
        guard size.width > 0, size.height > 0 else { return }

        // Upstream runs per animation frame; scaling by elapsed time keeps the
        // drift the same speed on a 120 Hz display as on a 60 Hz one.
        let elapsed = lastTick.map { now.timeIntervalSince($0) } ?? (1.0 / 60.0)
        lastTick = now
        let step = CGFloat(min(max(elapsed, 1.0 / 240.0), 1.0 / 20.0) * 60.0)

        for index in stars.indices {
            var star = stars[index]

            if let pointer {
                let dx = pointer.x - star.x
                let dy = pointer.y - star.y
                let distance = (dx * dx + dy * dy).squareRoot()
                if distance < influence, distance > 0 {
                    let force = (influence - distance) / influence
                    let pull = force * (gravity * 0.001) * step
                    star.vx += (dx / distance) * pull
                    star.vy += (dy / distance) * pull
                    star.opacity = min(1, star.baseOpacity + Double(force) * 0.4)
                    star.glow += (1 + force * 2 - star.glow) * 0.15 * step
                } else {
                    star.opacity = max(star.baseOpacity * 0.3, star.opacity - 0.02 * Double(step))
                    star.glow = max(1, star.glow + (1 - star.glow) * 0.08 * step)
                }
            } else {
                star.opacity = max(star.baseOpacity * 0.3, star.opacity - 0.02 * Double(step))
                star.glow = max(1, star.glow + (1 - star.glow) * 0.08 * step)
            }

            star.x += star.vx * step
            star.y += star.vy * step
            star.vx += CGFloat.random(in: -0.0005...0.0005) * step
            star.vy += CGFloat.random(in: -0.0005...0.0005) * step
            star.vx *= pow(0.999, step)
            star.vy *= pow(0.999, step)

            if star.x < 0 { star.x = size.width }
            if star.x > size.width { star.x = 0 }
            if star.y < 0 { star.y = size.height }
            if star.y > size.height { star.y = 0 }

            stars[index] = star
        }
    }

    private func seed(in size: CGSize, speed: CGFloat, baseOpacity: Double, maxSize: CGFloat) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        stars = (0..<75).map { _ in
            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let velocity = speed * CGFloat.random(in: 0.5...1.0)
            return Star(
                x: .random(in: 0...width), y: .random(in: 0...height),
                vx: cos(angle) * velocity, vy: sin(angle) * velocity,
                size: .random(in: 1...(maxSize + 1)),
                opacity: baseOpacity, baseOpacity: baseOpacity, glow: 1)
        }
    }
}
