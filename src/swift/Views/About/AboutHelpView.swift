// SPDX-License-Identifier: GPL-3.0+

import Observation
import StoreKit
import SwiftUI

private struct FAQPaneSpec {
    let sectionTitleKey: String
    let rowKeys: [(q: String, a: String)]
}

private let helpFAQSpec: [FAQPaneSpec] = [
    FAQPaneSpec(sectionTitleKey: "help.section.basics", rowKeys: [
        ("help.faq.0.0.q", "help.faq.0.0.a"),
        ("help.faq.0.1.q", "help.faq.0.1.a"),
    ]),
    FAQPaneSpec(sectionTitleKey: "help.section.files", rowKeys: [
        ("help.faq.1.0.q", "help.faq.1.0.a"),
        ("help.faq.1.1.q", "help.faq.1.1.a"),
        ("help.faq.1.2.q", "help.faq.1.2.a"),
        ("help.faq.1.3.q", "help.faq.1.3.a"),
    ]),
    FAQPaneSpec(sectionTitleKey: "help.section.settingsPerf", rowKeys: [
        ("help.faq.2.0.q", "help.faq.2.0.a"),
        ("help.faq.2.1.q", "help.faq.2.1.a"),
    ]),
    FAQPaneSpec(sectionTitleKey: "help.section.ingame", rowKeys: [
        ("help.faq.3.0.q", "help.faq.3.0.a"),
        ("help.faq.3.1.q", "help.faq.3.1.a"),
    ]),
]

struct AboutHelpView: View {
    @State private var expandedFAQSlots: Set<String> = []
    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @Bindable private var tipPurchase = TipPurchase.shared
    @State private var showThankYou = false
    @State private var showPurchaseError = false
    @State private var purchaseErrorMessage = ""

    private func faqFocusID(section: Int, item: Int) -> String {
        "help.faq.\(section).\(item)"
    }

    private func faqExpandKey(section: Int, item: Int) -> String { "\(section).\(item)" }

    private func creditMusicFocusID(index: Int) -> String { "help.focus.credits.music.\(index)" }

    private func creditSfxFocusID(index: Int) -> String { "help.focus.credits.sfx.\(index)" }

    private func licenseFocusID(idKey: String) -> String { "help.license.focus.\(idKey)" }

    private let discordID = "help.discord"
    private let tipID = "help.tip"
    private let aboutVersionID = "help.about.focus.version"
    private let aboutDeviceID = "help.about.focus.device"
    private let aboutCpuID = "help.about.focus.cpu"
    private let aboutGpuID = "help.about.focus.gpu"
    private let aboutRamID = "help.about.focus.ram"

    private var navigationSections: [[String]] {
        var sections: [[String]] = []
        for (sectionIndex, pane) in helpFAQSpec.enumerated() {
            let ids = pane.rowKeys.indices.map { faqFocusID(section: sectionIndex, item: $0) }
            if !ids.isEmpty { sections.append(ids) }
        }
        sections.append([
            aboutVersionID, aboutDeviceID, aboutCpuID, aboutGpuID, aboutRamID,
        ])
        sections.append([discordID, tipID])
        let musicIDs = MusicCatalog.attributionLines.indices.map { creditMusicFocusID(index: $0) }
        if !musicIDs.isEmpty { sections.append(musicIDs) }
        let sfxIDs = SFXManager.attributionLines.indices.map { creditSfxFocusID(index: $0) }
        if !sfxIDs.isEmpty { sections.append(sfxIDs) }
        for licenseSection in LicenseCatalog.sections {
            let ids = licenseSection.entries.map { licenseFocusID(idKey: $0.idKey) }
            if !ids.isEmpty { sections.append(ids) }
        }
        return sections
    }

    var body: some View {
        SettingsScroll {
            ForEach(Array(helpFAQSpec.enumerated()), id: \.offset) { sectionIndex, pane in
                SettingSection(title: SakuraL10n.tr(pane.sectionTitleKey)) {
                    VStack(spacing: 8) {
                        ForEach(Array(pane.rowKeys.enumerated()), id: \.offset) { itemIndex, row in
                            helpCard(
                                question: SakuraL10n.tr(row.q),
                                answer: SakuraL10n.tr(row.a),
                                expandKey: faqExpandKey(section: sectionIndex, item: itemIndex),
                                focusID: faqFocusID(section: sectionIndex, item: itemIndex)
                            )
                        }
                    }
                }
            }

            SettingSection(title: SakuraL10n.tr("help.section.thisDevice")) {
                VStack(spacing: 10) {
                    aboutRow(
                        icon: "info.circle.fill",
                        label: SakuraL10n.tr("help.aboutRow.version"),
                        value: SakuraBridge.buildVersion(),
                        focusID: aboutVersionID
                    )
                    aboutRow(
                        icon: "iphone",
                        label: SakuraL10n.tr("help.aboutRow.device"),
                        value: DeviceInfo.modelName,
                        focusID: aboutDeviceID
                    )
                    aboutRow(
                        icon: "cpu",
                        label: SakuraL10n.tr("help.aboutRow.cpu"),
                        value: DeviceInfo.cpuName,
                        focusID: aboutCpuID
                    )
                    aboutRow(
                        icon: "square.3.layers.3d",
                        label: SakuraL10n.tr("help.aboutRow.gpu"),
                        value: DeviceInfo.gpuName,
                        focusID: aboutGpuID
                    )
                    aboutRow(
                        icon: "memorychip",
                        label: SakuraL10n.tr("help.aboutRow.ram"),
                        value: DeviceInfo.totalRAMString,
                        focusID: aboutRamID
                    )
                }
            }

            SettingSection(title: SakuraL10n.tr("help.section.community")) {
                VStack(spacing: 10) {
                    discordButton
                    tipButton
                }
            }

            SettingSection(title: SakuraL10n.tr("help.section.musicCredits")) {
                VStack(spacing: 6) {
                    ForEach(Array(MusicCatalog.attributionLines.enumerated()), id: \.offset) { idx, line in
                        creditRow(
                            line.artist,
                            detail: line.license,
                            items: line.description,
                            focusID: creditMusicFocusID(index: idx)
                        )
                    }
                }
            }

            SettingSection(title: SakuraL10n.tr("help.section.sfxCredits")) {
                VStack(spacing: 6) {
                    ForEach(Array(SFXManager.attributionLines.enumerated()), id: \.offset) { idx, line in
                        creditRow(
                            line.artist,
                            detail: line.license,
                            items: line.description,
                            focusID: creditSfxFocusID(index: idx)
                        )
                    }
                }
            }

            SettingSection(title: SakuraL10n.tr("help.section.opensource")) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(LicenseCatalog.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            legalSubheading(SakuraL10n.tr(section.titleKey))
                            VStack(spacing: 6) {
                                ForEach(section.entries) { entry in
                                    licenseCard(entry, focusID: licenseFocusID(idKey: entry.idKey))
                                }
                            }
                        }
                    }
                }
            }

        }
        .onAppear {
            focus.setPage(sections: navigationSections, columnHint: 1)
            Task { await tipPurchase.loadProducts() }
        }
        .alert(SakuraL10n.tr("help.alert.thankYouTitle"), isPresented: $showThankYou) {
            Button(SakuraL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(SakuraL10n.tr("help.alert.thankYouBody"))
        }
        .alert(SakuraL10n.tr("help.alert.purchaseFailTitle"), isPresented: $showPurchaseError) {
            Button(SakuraL10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(purchaseErrorMessage)
        }
    }

    private func legalSubheading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.5)
            .foregroundStyle(theme.glassTextSecondary(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func licenseCard(_ entry: LicenseEntry, focusID: String) -> some View {
        let isFocused = focus.focusedID == focusID && focus.region == .content
        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.localizedName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            Text(entry.localizedLicense)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
            Text(entry.localizedCopyright)
                .font(.caption2)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.glassCardFill(colorScheme, isFocused: isFocused))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    theme.glassCardStroke(colorScheme, isFocused: isFocused),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .scaleEffect(isFocused ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .id(focusID)
    }

    private var discordButton: some View {
        let isFocused = focus.focusedID == discordID && focus.region == .content
        let tap: () -> Void = {
            CommunityLink.openDiscordInvite()
        }
        return Button {
            focus.focusFromTouch(id: discordID)
            SFXManager.shared.play(.confirm)
            tap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(SakuraL10n.tr("help.discord.button"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
            }
            .foregroundStyle(theme.glassTextPrimary(colorScheme))
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.glassCardFill(colorScheme, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        theme.glassCardStroke(colorScheme, isFocused: isFocused),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(discordID)
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == discordID && focus.region == .content {
                SFXManager.shared.play(.confirm)
                tap()
            }
        }
    }

    private var tipButton: some View {
        let isFocused = focus.focusedID == tipID && focus.region == .content
        let priceLabel = tipPurchase.tipProduct?.displayPrice ?? "…"
        let isBusy = tipPurchase.isPurchasing
        return Button {
            focus.focusFromTouch(id: tipID)
            SFXManager.shared.play(.confirm)
            Task { await runTipFlow() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.pink.opacity(0.95))
                VStack(alignment: .leading, spacing: 2) {
                    Text(SakuraL10n.trf("help.tip.buttonFmt", priceLabel))
                        .font(.subheadline.weight(.semibold))
                    Text(SakuraL10n.tr("help.tip.subtitle"))
                        .font(.caption2)
                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                }
                Spacer()
                if tipPurchase.isPurchasing {
                    ProgressView()
                        .tint(theme.glassTextPrimary(colorScheme))
                } else {
                    Image(systemName: "cart")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                }
            }
            .foregroundStyle(theme.glassTextPrimary(colorScheme))
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(theme.glassCardFill(colorScheme, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        theme.glassCardStroke(colorScheme, isFocused: isFocused),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .id(tipID)
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == tipID && focus.region == .content, !isBusy {
                SFXManager.shared.play(.confirm)
                Task { await runTipFlow() }
            }
        }
    }

    private func runTipFlow() async {
        if tipPurchase.tipProduct == nil {
            await tipPurchase.loadProducts()
        }
        guard tipPurchase.tipProduct != nil else {
            purchaseErrorMessage = {
                let err = tipPurchase.loadError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return err.isEmpty ? SakuraL10n.tr("help.tip.unavailable") : err
            }()
            showPurchaseError = true
            return
        }
        let ok = await tipPurchase.purchaseTip()
        if ok {
            showThankYou = true
        } else if let err = tipPurchase.lastPurchaseError, !err.isEmpty {
            purchaseErrorMessage = err
            showPurchaseError = true
        }
    }

    private func faqAnswerText(_ raw: String) -> some View {
        Group {
            if let attributed = try? AttributedString(markdown: raw) {
                Text(attributed)
            } else {
                Text(raw)
            }
        }
        .font(.caption)
        .foregroundStyle(theme.glassTextSecondary(colorScheme))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func helpCard(question: String, answer: String, expandKey: String, focusID: String) -> some View {
        let isExpanded = expandedFAQSlots.contains(expandKey)
        let isFocused = focus.focusedID == focusID && focus.region == .content
        let toggleExpansion: () -> Void = {
            withAnimation(theme.helpAccordionAnimation) {
                if expandedFAQSlots.contains(expandKey) {
                    expandedFAQSlots.remove(expandKey)
                } else {
                    expandedFAQSlots.insert(expandKey)
                }
            }
        }
        Button {
            focus.focusFromTouch(id: focusID)
            SFXManager.shared.play(.confirm)
            toggleExpansion()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text(question)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .fixedSize()
                }
                if isExpanded {
                    faqAnswerText(answer)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.glassCardFill(colorScheme, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        theme.glassCardStroke(colorScheme, isFocused: isFocused),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(focusID)
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == focusID && focus.region == .content {
                SFXManager.shared.play(.confirm)
                toggleExpansion()
            }
        }
    }

    private func aboutRow(icon: String, label: String, value: String, focusID: String) -> some View {
        let isFocused = focus.focusedID == focusID && focus.region == .content
        return HStack {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
                .frame(width: 20)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            Spacer()
            Text(value)
                .font(.subheadline)
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
                .lineLimit(1)
                .truncationMode(.head)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.glassCardFill(colorScheme, isFocused: isFocused))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    theme.glassCardStroke(colorScheme, isFocused: isFocused),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .scaleEffect(isFocused ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .id(focusID)
    }

    private func creditRow(_ artist: String, detail: String, items: String, focusID: String) -> some View {
        let isFocused = focus.focusedID == focusID && focus.region == .content
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(artist)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                Spacer()
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
            }
            Text(items)
                .font(.caption)
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.glassCardFill(colorScheme, isFocused: isFocused))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    theme.glassCardStroke(colorScheme, isFocused: isFocused),
                    lineWidth: isFocused ? 2 : 1
                )
        )
        .scaleEffect(isFocused ? 1.01 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        .id(focusID)
    }
}

@MainActor
@Observable
final class TipPurchase: @unchecked Sendable {
    static let shared = TipPurchase()

    static let tip1ProductID = "Com.Chronic.Sakura.tip.1"

    private(set) var tipProduct: Product?
    private(set) var loadError: String?
    private(set) var lastPurchaseError: String?
    private(set) var isPurchasing = false

    @ObservationIgnored private var transactionUpdatesTask: Task<Void, Never>?

    private init() {}

    func startListeningForTransactionUpdates() {
        guard transactionUpdatesTask == nil else { return }
        transactionUpdatesTask = Task { @MainActor in
            for await update in Transaction.updates {
                guard case .verified(let transaction) = update else { continue }
                await transaction.finish()
            }
        }
    }

    func loadProducts() async {
        loadError = nil
        do {
            var products = try await Product.products(for: [Self.tip1ProductID])
            if products.isEmpty {
                try await AppStore.sync()
                products = try await Product.products(for: [Self.tip1ProductID])
            }
            tipProduct = products.first
            if tipProduct == nil {
                loadError = SakuraL10n.tr("help.tip.unavailable")
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func purchaseTip() async -> Bool {
        guard let tipProduct else { return false }
        lastPurchaseError = nil
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await tipProduct.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                return true
            case .userCancelled:
                return false
            case .pending:
                lastPurchaseError = SakuraL10n.tr("help.tip.pending")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastPurchaseError = error.localizedDescription
            return false
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
}
