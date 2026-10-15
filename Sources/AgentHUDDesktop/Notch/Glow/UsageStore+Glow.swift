import AgentHUDCore

@MainActor
public extension UsageStore {
    /// - screen: which display's glow to resolve; nothing asks for the default one.
    /// - preview: the settings' previews resolve without live approvals, so they keep showing the configured glow.
    func glowAppearance(light: Bool, on screen: String? = nil, preview: Bool = false) -> GlowAppearance {
        let appearance = GlowAppearance.resolve(
            levels: levels,
            paused: isPaused || !isAccessAllowed,
            anyAgentActive: hasLiveSession,
            awaitingApproval: !preview && hasPendingApproval,
            glow: settings.settings.glow(on: screen),
            light: light
        )
        guard glowHidden else { return appearance }
        return GlowAppearance(
            stops: appearance.stops, peakOpacity: appearance.peakOpacity, troughOpacity: appearance.troughOpacity,
            breathing: appearance.breathing, breathSeconds: appearance.breathSeconds, hidden: true
        )
    }
}
