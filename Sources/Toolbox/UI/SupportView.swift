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
    @Published var copiedNote = false
    @Published var copiedShareLink = false
}

@MainActor
private final class SupportFuelCardHoverState: ObservableObject {
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
                    fuelSection
                    freeWaysSection
                }
                .padding(22)
            }

            ConfettiBurstOverlay(bursts: uiState.bursts)
        }
    }

    private var heroCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
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
                                .font(.title2)
                                .foregroundStyle(.pink)
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
                                .font(.title3.weight(.semibold))

                            if supportState.isSupporterUnlocked {
                                StatusBadge(text: "Supporter ★", color: .pink)
                            }
                        }

                        Text("Built & maintained by one indie developer — free, local-first, with zero ads or tracking. If Toolbox saves you time, you can keep it fueled below.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .textSelection(.enabled)

                    Spacer(minLength: 10)

                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            triggerHighFive(origin: UnitPoint(x: 0.84, y: 0.16))
                        } label: {
                            Label(
                                supportState.highFiveCount > 0
                                    ? "High-Five · \(supportState.highFiveCount)"
                                    : "High-Five",
                                systemImage: "hands.clap.fill"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                LinearGradient(
                                    colors: [Color.pink, Color.pink.opacity(0.84)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .scaleEffect(uiState.highFivePulse ? 1.06 : 1.0)
                        .pointerCursor()

                        Button {
                            let willUnlock = !supportState.isSupporterUnlocked
                            supportState.toggleSupporterBadge()
                            if willUnlock {
                                launchConfetti(at: UnitPoint(x: 0.84, y: 0.22), count: 38)
                                HUDToast.shared.show(
                                    title: "Thank you for supporting Toolbox!",
                                    symbol: "heart.fill",
                                    tint: .pink
                                )
                            }
                        } label: {
                            Label(
                                supportState.isSupporterUnlocked ? "Supporter Badge On" : "I Supported!",
                                systemImage: supportState.isSupporterUnlocked ? "checkmark.seal.fill" : "sparkles"
                            )
                            .font(.caption2.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Honor-system supporter badge — unlocks a thank-you badge in the sidebar.")
                        .pointerCursor()
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                if supportState.highFiveStatusMessage != nil || supportState.isSupporterUnlocked {
                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: supportState.isSupporterUnlocked ? "sparkles" : "hand.raised.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                        Text(
                            supportState.highFiveStatusMessage
                                ?? "Thank you for helping keep Toolbox free, signed, and open-source."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    private var fuelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FUEL THE TOOLKIT")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text("Pick what you'd like to power, optionally copy a checkout note, and choose your preferred platform.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .textSelection(.enabled)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    ForEach(SupportFuelTier.allCases) { tier in
                        SupportFuelCard(
                            tier: tier,
                            isSelected: supportState.selectedFuel == tier,
                            onSelect: {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                                    supportState.selectedFuel = tier
                                    uiState.copiedNote = false
                                }
                            }
                        )
                    }
                }
            }

            SectionCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        HStack(spacing: 7) {
                            Image(systemName: supportState.selectedFuel.symbolName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(supportState.selectedFuel.accentColor)
                            Text(supportState.selectedFuel.devReaction)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .textSelection(.enabled)

                        Spacer(minLength: 8)

                        Button {
                            SupportLinks.copyToPasteboard(supportState.selectedFuel.checkoutNote)
                            setCopiedFlag(\.copiedNote, toastTitle: "Copied checkout note", tint: supportState.selectedFuel.accentColor)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: uiState.copiedNote ? "checkmark.circle.fill" : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(uiState.copiedNote ? .green : .secondary)
                                Text(
                                    uiState.copiedNote
                                        ? "Copied note!"
                                        : "Copy note: \"\(supportState.selectedFuel.checkoutNote)\""
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .fixedSize(horizontal: true, vertical: false)
                        .help("Copy this optional message to paste on Ko-fi or GitHub Sponsors.")
                        .pointerCursor()
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 14) {
                        Text("GitHub Sponsors takes 0% fees · Ko-fi accepts Apple Pay, cards, or PayPal with no GitHub account needed.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        Spacer(minLength: 12)

                        HStack(spacing: 8) {
                            checkoutButton(
                                title: "Sponsor on GitHub",
                                symbol: "heart.fill",
                                tint: .pink,
                                url: SupportLinks.githubSponsors,
                                origin: UnitPoint(x: 0.68, y: 0.52),
                                toastTitle: "Opening GitHub Sponsors — thank you!"
                            )
                            checkoutButton(
                                title: "Support on Ko-fi",
                                symbol: "cup.and.saucer.fill",
                                tint: .orange,
                                url: SupportLinks.koFi,
                                origin: UnitPoint(x: 0.86, y: 0.52),
                                toastTitle: "Opening Ko-fi — thank you!"
                            )
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private var freeWaysSection: some View {
        FeatureSection(
            "Free Ways to Help",
            subtitle: "No budget right now? Stars, shares, and feedback help Toolbox grow just as much."
        ) {
            SettingRow(
                "Star Toolbox on GitHub",
                subtitle: "Stars help other Mac users discover the project."
            ) {
                Button {
                    SupportLinks.open(SupportLinks.githubRepo)
                } label: {
                    Label {
                        Text("Star on GitHub")
                    } icon: {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }

            Divider()

            SettingRow(
                "Tell a Mac Friend",
                subtitle: "Copy the project link to drop into Slack, Discord, or group chat."
            ) {
                Button {
                    SupportLinks.copyToPasteboard(SupportLinks.githubRepo.absoluteString)
                    setCopiedFlag(\.copiedShareLink, toastTitle: "Copied Toolbox GitHub link", tint: .blue)
                } label: {
                    Label {
                        Text(uiState.copiedShareLink ? "Copied!" : "Copy Link")
                    } icon: {
                        Image(systemName: uiState.copiedShareLink ? "checkmark.circle.fill" : "link")
                            .foregroundStyle(uiState.copiedShareLink ? .green : .blue)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }

            Divider()

            SettingRow(
                "Suggest a Module or Report a Bug",
                subtitle: "Have an idea for a new macOS utility or spotted an edge case?"
            ) {
                Button {
                    SupportLinks.open(SupportLinks.githubIssues)
                } label: {
                    Label {
                        Text("Open Issues")
                    } icon: {
                        Image(systemName: "exclamationmark.bubble.fill")
                            .foregroundStyle(.purple)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }
        }
    }

    private func checkoutButton(
        title: String,
        symbol: String,
        tint: Color,
        url: URL,
        origin: UnitPoint,
        toastTitle: String
    ) -> some View {
        Button {
            launchConfetti(at: origin, count: 26)
            SupportLinks.open(url)
            HUDToast.shared.show(title: toastTitle, symbol: symbol, tint: tint)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .pointerCursor()
    }

    private func setCopiedFlag(
        _ keyPath: ReferenceWritableKeyPath<SupportViewUIState, Bool>,
        toastTitle: String,
        tint: Color
    ) {
        uiState[keyPath: keyPath] = true
        HUDToast.shared.show(title: toastTitle, symbol: "doc.on.doc.fill", tint: tint)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            uiState[keyPath: keyPath] = false
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

private struct SupportFuelCard: View {
    let tier: SupportFuelTier
    let isSelected: Bool
    let onSelect: () -> Void

    @StateObject private var hoverState = SupportFuelCardHoverState()

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(tier.accentColor.opacity(isSelected ? 0.22 : 0.14))
                            .frame(width: 34, height: 34)
                        Image(systemName: tier.symbolName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(tier.accentColor)
                    }

                    Spacer(minLength: 6)

                    if isSelected {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption2)
                            Text("Selected")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(tier.accentColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tier.accentColor.opacity(0.14), in: Capsule())
                    } else {
                        Text(tier.badgeText)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(tier.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(tier.description)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                            .fill(
                                isSelected
                                    ? tier.accentColor.opacity(0.08)
                                    : (hoverState.isHovered ? Color.primary.opacity(0.03) : Color.clear)
                            )
                    )
            }
            .overlay(
                RoundedRectangle(cornerRadius: ToolboxTheme.cardCornerRadius)
                    .strokeBorder(
                        isSelected
                            ? tier.accentColor.opacity(0.72)
                            : (hoverState.isHovered ? Color.primary.opacity(0.22) : Color.primary.opacity(0.11)),
                        lineWidth: isSelected ? 1.5 : 1
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
