import SwiftUI

private struct ConfettiParticle: Identifiable {
    enum ShapeKind {
        case pill
        case circle
        case heart
        case sparkle
    }

    let id = UUID()
    let angle: Double
    let speed: Double
    let spin: Double
    let size: CGFloat
    let color: Color
    let kind: ShapeKind
}

private struct ConfettiBurst: Identifiable {
    let id = UUID()
    let createdAt: Date
    let origin: UnitPoint
    let particles: [ConfettiParticle]
    let duration: TimeInterval = 1.65

    static func make(at origin: UnitPoint, count: Int = 28) -> ConfettiBurst {
        let palette: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .purple, .blue]
        let kinds: [ConfettiParticle.ShapeKind] = [.pill, .circle, .heart, .sparkle]
        let particles = (0..<count).map { idx in
            let spread = Double.random(in: -Double.pi * 0.92 ... -Double.pi * 0.08)
            return ConfettiParticle(
                angle: spread,
                speed: Double.random(in: 170...420),
                spin: Double.random(in: -8...8),
                size: CGFloat.random(in: 5...9.5),
                color: palette[idx % palette.count],
                kind: kinds[idx % kinds.count]
            )
        }
        return ConfettiBurst(createdAt: Date(), origin: origin, particles: particles)
    }
}

private struct ConfettiBurstOverlay: View {
    let bursts: [ConfettiBurst]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: bursts.isEmpty)) { timeline in
            Canvas { context, size in
                let now = timeline.date
                for burst in bursts {
                    let age = now.timeIntervalSince(burst.createdAt)
                    guard age >= 0, age <= burst.duration else { continue }
                    let progress = age / burst.duration
                    let alpha = max(0, 1.0 - pow(progress, 2.2))
                    let originX = size.width * burst.origin.x
                    let originY = size.height * burst.origin.y
                    let gravity = 560.0

                    for p in burst.particles {
                        let vx = cos(p.angle) * p.speed
                        let vy = sin(p.angle) * p.speed
                        let x = originX + vx * age
                        let y = originY + vy * age + 0.5 * gravity * age * age
                        let rot = Angle.radians(p.spin * age)

                        var particleCtx = context
                        particleCtx.opacity = alpha
                        particleCtx.translateBy(x: x, y: y)
                        particleCtx.rotate(by: rot)

                        switch p.kind {
                        case .pill:
                            let rect = CGRect(x: -p.size * 0.65, y: -p.size * 0.28, width: p.size * 1.3, height: p.size * 0.56)
                            particleCtx.fill(Path(roundedRect: rect, cornerRadius: p.size * 0.28), with: .color(p.color))
                        case .circle:
                            let rect = CGRect(x: -p.size * 0.45, y: -p.size * 0.45, width: p.size * 0.9, height: p.size * 0.9)
                            particleCtx.fill(Path(ellipseIn: rect), with: .color(p.color))
                        case .heart:
                            if let heart = particleCtx.resolveSymbol(id: "heart") {
                                particleCtx.draw(heart, at: .zero)
                            }
                        case .sparkle:
                            if let sparkle = particleCtx.resolveSymbol(id: "sparkle") {
                                particleCtx.draw(sparkle, at: .zero)
                            }
                        }
                    }
                }
            } symbols: {
                Image(systemName: "heart.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.pink)
                    .tag("heart")
                Image(systemName: "sparkle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.yellow)
                    .tag("sparkle")
            }
        }
        .allowsHitTesting(false)
    }
}

@MainActor
private final class SupportViewUIState: ObservableObject {
    @Published var bursts: [ConfettiBurst] = []
    @Published var highFivePulse = false
    @Published var copiedShareLink = false
}

@MainActor
private final class SupportCardHoverState: ObservableObject {
    @Published var isHovered = false
}

struct SupportView: View {
    @ObservedObject private var supportState = SupportState.shared
    @StateObject private var uiState = SupportViewUIState()

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    heroCard
                    donateSection
                    freeWaysSection
                }
                .padding(22)
            }

            ConfettiBurstOverlay(bursts: uiState.bursts)
        }
    }

    private var heroCard: some View {
        let pinkFill = ToolboxProminentTone.pink.fillColor
        let pinkText = ToolboxTheme.readableAccentText(for: .pink)

        return SectionCard(accentTint: .pink) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    Button {
                        triggerHighFive(origin: UnitPoint(x: 0.14, y: 0.18))
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    supportState.isSupporterUnlocked
                                        ? LinearGradient(
                                            colors: [Color.pink.opacity(0.26), Color.orange.opacity(0.22)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        : LinearGradient(
                                            colors: [Color.pink.opacity(0.16), Color.pink.opacity(0.12)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                )
                                .frame(width: 48, height: 48)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(
                                            supportState.isSupporterUnlocked ? Color.pink.opacity(0.45) : Color.pink.opacity(0.25),
                                            lineWidth: 1
                                        )
                                )
                            Image(systemName: supportState.isSupporterUnlocked ? "heart.circle.fill" : "heart.fill")
                                .toolboxFont(.title2)
                                .foregroundStyle(pinkText)
                                .scaleEffect(uiState.highFivePulse ? 1.22 : 1.0)
                        }
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Tap for a high-five!")
                    .pointerCursor()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Support Toolbox")
                                .toolboxFont(.title3.weight(.semibold))

                            if supportState.isSupporterUnlocked {
                                StatusBadge(text: "Supporter ♥", color: .pink)
                            }
                        }

                        Text("Built & maintained by one indie developer: free, local-first, with zero ads or tracking. If Toolbox saves you time every day, consider supporting its ongoing development.")
                            .toolboxFont(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Button {
                            triggerHighFive(origin: UnitPoint(x: 0.24, y: 0.26))
                        } label: {
                            Label(
                                supportState.highFiveCount > 0
                                    ? "High-Five · \(supportState.highFiveCount)"
                                    : "Send a High-Five",
                                systemImage: "hands.clap.fill"
                            )
                            .toolboxFont(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                LinearGradient(
                                    colors: [pinkFill, pinkFill.opacity(0.90)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .scaleEffect(uiState.highFivePulse ? 1.05 : 1.0)
                        .pointerCursor()

                        Button {
                            let willUnlock = !supportState.isSupporterUnlocked
                            supportState.toggleSupporterBadge()
                            if willUnlock {
                                launchConfetti(at: UnitPoint(x: 0.45, y: 0.26), count: 38)
                                HUDToast.shared.show(
                                    title: "Thank you for supporting Toolbox!",
                                    symbol: "heart.fill",
                                    tint: .pink
                                )
                            }
                        } label: {
                            Label(
                                supportState.isSupporterUnlocked ? "Supporter Badge Active" : "I Supported Toolbox!",
                                systemImage: supportState.isSupporterUnlocked ? "checkmark.seal.fill" : "sparkles"
                            )
                            .toolboxFont(.callout.weight(.medium))
                            .foregroundStyle(supportState.isSupporterUnlocked ? pinkText : .primary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                supportState.isSupporterUnlocked
                                    ? Color.pink.opacity(0.16)
                                    : Color.primary.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        supportState.isSupporterUnlocked
                                            ? Color.pink.opacity(0.48)
                                            : Color.primary.opacity(0.14),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Honor-system supporter badge: unlocks a thank-you badge in the sidebar.")
                        .pointerCursor()

                        Spacer(minLength: 0)
                    }

                    if let status = supportState.highFiveStatusMessage {
                        Text(status)
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    } else if supportState.isSupporterUnlocked {
                        Text("Thank you for keeping Toolbox free & open-source!")
                            .toolboxFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var donateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureSectionHeader(
                title: "Support Development",
                subtitle: "Every contribution helps cover Apple Developer notarization ($99/yr) and keeps Toolbox free for everyone."
            )

            Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    SupportActionCard(
                        title: "Sponsor on GitHub",
                        subtitle: "Best for developers: 0% platform or card fees for personal sponsorships, so 100% reaches the developer.",
                        badge: "0% fees",
                        actionTitle: "Sponsor on GitHub",
                        symbolName: "heart.fill",
                        accentColor: .pink,
                        action: {
                            launchConfetti(at: UnitPoint(x: 0.36, y: 0.52), count: 28)
                            SupportLinks.open(SupportLinks.githubSponsors)
                            HUDToast.shared.show(
                                title: "Opening GitHub Sponsors. Thank you!",
                                symbol: "heart.fill",
                                tint: .pink
                            )
                        }
                    )

                    SupportActionCard(
                        title: "Support on Ko-fi",
                        subtitle: "Quick one-time tip with Apple Pay, cards, or PayPal. No GitHub account needed (0% Ko-fi fee on tips).",
                        badge: "Apple Pay · PayPal",
                        actionTitle: "Support on Ko-fi",
                        symbolName: "cup.and.saucer.fill",
                        accentColor: .orange,
                        action: {
                            launchConfetti(at: UnitPoint(x: 0.78, y: 0.52), count: 28)
                            SupportLinks.open(SupportLinks.koFi)
                            HUDToast.shared.show(
                                title: "Opening Ko-fi. Thank you!",
                                symbol: "cup.and.saucer.fill",
                                tint: .orange
                            )
                        }
                    )
                }
            }
        }
    }

    private var freeWaysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureSectionHeader(
                title: "Free Ways to Help",
                subtitle: "No budget right now? Stars, shares, and feedback help Toolbox grow just as much."
            )

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    SupportActionCard(
                        title: "Star on GitHub",
                        subtitle: "Stars help other Mac power users discover Toolbox.",
                        actionTitle: "Star Repo",
                        symbolName: "star.fill",
                        accentColor: .yellow,
                        isCompact: true,
                        action: {
                            SupportLinks.open(SupportLinks.githubRepo)
                        }
                    )

                    SupportActionCard(
                        title: "Tell a Mac Friend",
                        subtitle: "Copy the project link to share in Slack, Discord, or chat.",
                        actionTitle: uiState.copiedShareLink ? "Copied!" : "Copy Link",
                        actionSymbol: uiState.copiedShareLink ? "checkmark.circle.fill" : "doc.on.doc",
                        symbolName: "link",
                        accentColor: uiState.copiedShareLink ? .green : .blue,
                        isCompact: true,
                        action: {
                            SupportLinks.copyToPasteboard(SupportLinks.githubRepo.absoluteString)
                            uiState.copiedShareLink = true
                            HUDToast.shared.show(
                                title: "Copied Toolbox GitHub link",
                                symbol: "link",
                                tint: .blue
                            )
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(2))
                                uiState.copiedShareLink = false
                            }
                        }
                    )

                    SupportActionCard(
                        title: "Ideas & Bug Reports",
                        subtitle: "Suggest a new macOS utility or report an edge case.",
                        actionTitle: "Open Issues",
                        symbolName: "exclamationmark.bubble.fill",
                        accentColor: .purple,
                        isCompact: true,
                        action: {
                            SupportLinks.open(SupportLinks.githubIssues)
                        }
                    )
                }
            }
        }
    }

    private func triggerHighFive(origin: UnitPoint) {
        supportState.sendHighFive()
        launchConfetti(at: origin, count: 28)
        withAnimation(.spring(response: 0.22, dampingFraction: 0.45)) {
            uiState.highFivePulse = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                uiState.highFivePulse = false
            }
        }
    }

    private func launchConfetti(at origin: UnitPoint, count: Int) {
        let burst = ConfettiBurst.make(at: origin, count: count)
        uiState.bursts.append(burst)
        let burstID = burst.id
        let duration = burst.duration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            uiState.bursts.removeAll { $0.id == burstID }
        }
    }
}

private struct SupportActionCard: View {
    let title: String
    let subtitle: String
    var badge: String? = nil
    let actionTitle: String
    var actionSymbol: String = "arrow.up.right"
    let symbolName: String
    let accentColor: Color
    var isCompact: Bool = false
    let action: () -> Void

    @StateObject private var hoverState = SupportCardHoverState()

    private var readableAccent: Color {
        ToolboxTheme.readableAccentText(for: accentColor)
    }

    private var prominentButtonFill: Color {
        if accentColor == .pink {
            return ToolboxProminentTone.pink.fillColor
        }
        if accentColor == .orange {
            return ToolboxProminentTone.orange.fillColor
        }
        return accentColor
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: isCompact ? 10 : 12) {
                HStack(alignment: .center) {
                    ZStack {
                        RoundedRectangle(cornerRadius: isCompact ? 9 : 10)
                            .fill(accentColor.opacity(hoverState.isHovered ? 0.22 : 0.15))
                            .frame(width: isCompact ? 34 : 40, height: isCompact ? 34 : 40)
                        Image(systemName: symbolName)
                            .toolboxFont(isCompact ? .body.weight(.semibold) : .title3.weight(.semibold))
                            .foregroundStyle(readableAccent)
                    }

                    Spacer(minLength: 8)

                    if let badge {
                        Text(badge)
                            .toolboxFont(.caption2.weight(.semibold))
                            .foregroundStyle(readableAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accentColor.opacity(0.14), in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .toolboxFont(isCompact ? .headline : .title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(subtitle)
                        .toolboxFont(.system(size: isCompact ? 12 : 12.5))
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Text(actionTitle)
                        .toolboxFont((isCompact ? ToolboxFont.caption : ToolboxFont.callout).weight(.semibold))
                    Image(systemName: actionSymbol)
                        .toolboxFont((isCompact ? ToolboxFont.caption2 : ToolboxFont.caption).weight(.semibold))
                }
                .foregroundStyle(isCompact ? readableAccent : .white)
                .padding(.horizontal, isCompact ? 10 : 14)
                .padding(.vertical, isCompact ? 5 : 7)
                .background(
                    isCompact
                        ? accentColor.opacity(hoverState.isHovered ? 0.22 : 0.14)
                        : prominentButtonFill.opacity(hoverState.isHovered ? 0.90 : 1.0),
                    in: RoundedRectangle(cornerRadius: 7)
                )
            }
            .padding(isCompact ? 14 : 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.58))
                    .overlay(
                        RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                            .fill(hoverState.isHovered ? accentColor.opacity(0.055) : Color.clear)
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                    .strokeBorder(
                        hoverState.isHovered ? accentColor.opacity(0.45) : Color.primary.opacity(0.11),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            hoverState.isHovered = hovering
        }
        .pointerCursor()
    }
}
