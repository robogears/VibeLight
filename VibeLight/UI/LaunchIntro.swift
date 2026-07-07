import SwiftUI

/// The launch "deal-in" intro. On the FIRST time the home screen appears, the UI
/// assembles itself top-to-bottom over ~2 s — the header drops in, the hero name
/// rises, then the shelf cascades in left-to-right and the focus ring lands on
/// the first card. Cold-launch-only (an app-lifetime flag), skippable on any
/// input, and a no-op on every later appearance (returning from a stream, a TV
/// connecting mid-session) so it never re-deals.
///
/// Views reveal by beat: each element passes its beat to `arrived(_:)` and shows
/// once that beat has fired. `withAnimation(Theme.focusSpring)` wraps each beat
/// bump, so the reveal rides the app's one spring. `arrived` short-circuits to
/// true once `finished`, so any surface that renders the home AFTER the sequence
/// (a late TV mirror) shows the settled UI with no re-deal.
@MainActor
@Observable
final class LaunchIntro {
    /// How many beats have fired.
    private(set) var beat = 0
    /// True once the sequence completes or is skipped — everything is visible.
    private(set) var finished = false
    /// True from the moment the sequence begins.
    private(set) var started = false

    @ObservationIgnored private var task: Task<Void, Never>?

    // Beat map: header, hero, then shelf tiles (index i on `tileBase + min(i,
    // tileCap)`), then the focus ring + hint bar + preset rail on `late`.
    static let header = 1, hero = 2, tileBase = 3, tileCap = 5, late = 9

    /// Absolute ms from start for beats 1…late — front-loaded header/hero, a
    /// paced shelf cascade, then a beat of settle before the focus ring lands.
    @ObservationIgnored private let schedule = [150, 430, 660, 790, 910, 1020, 1120, 1210, 1650]

    /// Start the sequence. Idempotent — only the first call does anything.
    func begin() {
        guard !started else { return }
        started = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var prev = 0
            for (i, ms) in self.schedule.enumerated() {
                try? await Task.sleep(for: .milliseconds(ms - prev)); prev = ms
                if Task.isCancelled { return }
                withAnimation(Theme.focusSpring) { self.beat = i + 1 }
            }
            try? await Task.sleep(for: .milliseconds(280))
            if !Task.isCancelled { self.finished = true }
        }
    }

    /// Any input during the intro snaps the remainder in fast — never a jarring
    /// cut, and a returning power-user is never held hostage by the animation.
    func skip() {
        guard started, !finished else { return }
        task?.cancel(); task = nil
        withAnimation(.easeOut(duration: 0.2)) {
            beat = Self.late
            finished = true
        }
    }

    func arrived(_ b: Int) -> Bool { finished || beat >= b }
    /// The shelf tile at `index` reveals on its (capped) cascade beat.
    func tileArrived(_ index: Int) -> Bool { arrived(Self.tileBase + min(index, Self.tileCap)) }
    /// The focus ring "lands" only after the cascade has settled.
    var focusReady: Bool { arrived(Self.late) }
}

/// Reveals a view for the launch deal-in: it starts blurred, transparent, and
/// offset, and settles to its resting state when `visible` flips. Uses only
/// render transforms (opacity / blur / offset) — no layout change — so the
/// spatial focus engine's geometry is untouched.
struct IntroReveal: ViewModifier {
    let visible: Bool
    var y: CGFloat = 20
    var blur: CGFloat = 6
    func body(content: Content) -> some View {
        content
            .blur(radius: visible ? 0 : blur)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : y)
    }
}

extension View {
    func introReveal(_ visible: Bool, y: CGFloat = 20, blur: CGFloat = 6) -> some View {
        modifier(IntroReveal(visible: visible, y: y, blur: blur))
    }
}
