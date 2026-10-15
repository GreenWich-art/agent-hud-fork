import AppKit
import QuartzCore
import AgentHUDCore

/// Plays a grid glow effect by redrawing the glow bitmap from the host view's display link at the design's
/// 24 fps. The link pauses by itself while the display sleeps. Starting and stopping ease the effect
/// over `fadeDuration`, so the glow never jumps between its resting frame and the running effect.
@MainActor
final class GlowAnimator {
    static let framesPerSecond: Float = 24
    static let fadeDuration: CFTimeInterval = 0.6
    /// The design's rate is for the working period. A resting HUD runs the same effect several times slower,
    /// and sampling slow motion at the full rate buys nothing but CPU, so the rate follows the period down to
    /// this floor.
    static let idleFramesPerSecond: Float = 8
    /// The link may still fire at the display's full refresh rate; frames closer than this are skipped.
    private var frameInterval: CFTimeInterval {
        let rate = max(Self.idleFramesPerSecond,
                       Self.framesPerSecond * Float(GlowMotion.breathePeriod / max(0.5, breathSeconds)))
        return 1 / CFTimeInterval(min(Self.framesPerSecond, rate)) - 0.002
    }
    /// Frames are spaced at least this many times their own drawing time, so a large glow such as the one
    /// around an expanded panel lowers its frame rate instead of spending more than its share of a core.
    private static let frameCostSpacing: CFTimeInterval = 12

    /// Ask the display link for the rate we can actually draw, rather than waking at 24 fps and discarding
    /// most callbacks for a slow idle effect or an expensive multi-screen frame.
    static func requestedFrameRate(breathSeconds: Double, frameCost: CFTimeInterval, activeGlows: Int) -> Float {
        let nominal = min(Self.framesPerSecond, max(Self.idleFramesPerSecond,
            Self.framesPerSecond * Float(GlowMotion.breathePeriod / max(0.5, breathSeconds))))
        let budget = frameCost > 0 ? Float(1 / (frameCost * Self.frameCostSpacing * Double(max(1, activeGlows)))) : nominal
        return max(1, min(nominal, budget).rounded(.down))
    }

    /// How many glows are running. The budget is the HUD's, not each screen's: spacing every glow at a tenth
    /// of a core would cost a third of one on three displays. They divide the same tenth instead, so a second
    /// display costs frames rather than CPU.
    static var activeGlows = 1 {
        didSet { activeGlows = max(1, activeGlows) }
    }

    private var costSpacing: CFTimeInterval { Self.frameCostSpacing * CFTimeInterval(Self.activeGlows) }

    private let host: NSView
    private let layer: CALayer
    private var link: CADisplayLink?
    private var renderer: GlowFrameRenderer?
    private var breathSeconds = 3.0
    private var breathAmplitude = 0.6
    /// The rhythm eases from a faster period to `breathSeconds` one cycle at a time when work just ended, so the
    /// glow reads as slowing down rather than switching. `phase` is the cycle count the effect stood at (its warped
    /// time over its period) when the ease began, kept absolute so the wave continues rather than restarts.
    private var windDown: (from: Double, at: CFTimeInterval, phase: Double)?
    private var startTime: CFTimeInterval = 0
    private var fadeStart: CFTimeInterval = 0
    private var fadeFrom = 0.0
    private var fadeTo = 0.0
    private var lastFrame: CFTimeInterval = 0
    /// Recent drawing time per frame, smoothed.
    private var frameCost: CFTimeInterval = 0
    private var onRest: (() -> Void)?

    /// How much longer each cycle of a wind-down is than the one before.
    nonisolated static let windDownStep: Double = 0.5

    init(host: NSView, layer: CALayer) {
        self.host = host
        self.layer = layer
    }

    var isRunning: Bool { link != nil }

    /// Starts the effect, or keeps it running with new geometry or colours without restarting its clock.
    /// A period that grows while the effect runs eases into the new one cycle by cycle; one that shrinks takes
    /// effect at once, as work resuming should.
    func play(_ renderer: GlowFrameRenderer, breathSeconds: Double, breathAmplitude: Double) {
        let now = CACurrentMediaTime()
        if link != nil, breathSeconds > self.breathSeconds + 0.05 {
            let current = rhythm(at: now)
            windDown = (from: self.breathSeconds, at: now, phase: current.time / current.period)
        } else if breathSeconds < self.breathSeconds - 0.05 {
            windDown = nil
        }
        self.renderer = renderer
        self.breathSeconds = breathSeconds
        self.breathAmplitude = breathAmplitude
        onRest = nil
        if link == nil {
            startTime = now
            fade(from: 0, to: 1, at: now)
            start()
        } else if fadeTo != 1 {
            fade(from: blend(at: now), to: 1, at: now)
        }
        updateFrameRate()
    }

    /// Eases the running effect back to the resting frame, then stops and calls `completion`.
    func settle(_ renderer: GlowFrameRenderer, completion: @escaping () -> Void) {
        self.renderer = renderer
        guard link != nil else { return completion() }
        onRest = completion
        guard fadeTo != 0 else { return }
        let now = CACurrentMediaTime()
        fade(from: blend(at: now), to: 0, at: now)
    }

    func stop() {
        link?.invalidate()
        link = nil
        onRest = nil
    }

    private func fade(from: Double, to: Double, at time: CFTimeInterval) {
        fadeFrom = from
        fadeTo = to
        fadeStart = time
    }

    private func blend(at time: CFTimeInterval) -> Double {
        let progress = min(1, max(0, (time - fadeStart) / Self.fadeDuration))
        return fadeFrom + (fadeTo - fadeFrom) * progress * progress * (3 - 2 * progress)
    }

    private func start() {
        let target = DisplayLinkTarget { [weak self] in self?.step() }
        let link = host.displayLink(target: target, selector: #selector(DisplayLinkTarget.fire(_:)))
        self.link = link
        updateFrameRate()
        link.add(to: .main, forMode: .common)
    }

    private func updateFrameRate() {
        guard let link else { return }
        let rate = Self.requestedFrameRate(breathSeconds: breathSeconds, frameCost: frameCost, activeGlows: Self.activeGlows)
        guard link.preferredFrameRateRange.preferred != rate else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(Self.idleFramesPerSecond, rate), maximum: rate, preferred: rate)
    }

    private func step() {
        guard let renderer else { return }
        let now = CACurrentMediaTime()
        let rested = fadeTo == 0 && now - fadeStart >= Self.fadeDuration
        guard rested || now - lastFrame >= max(frameInterval, frameCost * costSpacing) else { return }
        lastFrame = now
        let rhythm = rhythm(at: now)
        let frame = renderer.render(time: rhythm.time, blend: blend(at: now),
                                    breathSeconds: rhythm.period, breathAmplitude: breathAmplitude)
        let cost = CACurrentMediaTime() - now
        frameCost = frameCost == 0 ? cost : frameCost * 0.8 + cost * 0.2
        updateFrameRate()
        if let frame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = frame.image
            CATransaction.commit()
        }
        guard rested else { return }
        let completion = onRest
        stop()
        completion?()
    }

    /// The effect's warped clock: the seconds a constant period would need to stand where the glow stands now.
    /// While a wind-down runs, cycle k since the ease began lasts `from + (k-1) * windDownStep` seconds — the
    /// first one still at the working period, each later one longer — until the target period is reached. The wave
    /// stays continuous because only whole cycles are inserted: `time / period` never jumps.
    private func rhythm(at now: CFTimeInterval) -> (time: Double, period: Double) {
        let elapsed = now - startTime
        guard elapsed > 0 else { return (0, breathSeconds) }
        guard let ease = windDown else { return (elapsed, breathSeconds) }
        let state = Self.woundDown(phase: ease.phase, from: ease.from, to: breathSeconds, since: now - ease.at)
        return (state.phase * state.period, state.period)
    }

    /// Where a wind-down stands `since` seconds after it began: the cycle count it has reached and the period it
    /// is now in. Pure math, so a test can walk it second by second.
    /// - phase: the cycle count (fractional) the effect stood at when the ease began.
    /// - from: the period it began from; `to`: the period it eases to.
    nonisolated static func woundDown(phase: Double, from: Double, to: Double, since: Double) -> (phase: Double, period: Double) {
        guard since > 0, from < to - 0.01 else { return (phase, max(from, to)) }
        var consumed = 0.0, completed = 0
        while true {
            let next = min(to, from + Double(completed) * Self.windDownStep)
            if consumed + next > since { break }
            consumed += next
            completed += 1
        }
        let period = min(to, from + Double(completed) * Self.windDownStep)
        return (phase + Double(completed) + (since - consumed) / period, period)
    }
}

/// The display link retains its target; this relay holds the animator weakly so invalidating breaks the loop.
/// The link runs on the main run loop.
@MainActor
private final class DisplayLinkTarget: NSObject {
    private let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @objc func fire(_ link: CADisplayLink) {
        handler()
    }
}
