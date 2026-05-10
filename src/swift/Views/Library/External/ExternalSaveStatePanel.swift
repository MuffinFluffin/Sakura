// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

// compact save-state strip for the AirConsole library. no preview thumbnails,
// just the slot number and a short "when saved" caption. frees the right
// column for the media strips.
struct ExternalSaveStatePanel: View {
    let game: GameItem?
    @Binding var focusedSlot: Int
    var isFocused: Bool
    var refreshToken: Int
    var onLoadSlot: (Int) -> Void

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    // 10 across: the whole strip is one line, so it only eats ~48pt of
    // vertical space instead of a two-row thumbnail grid.
    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 6, alignment: .topLeading),
        count: 10
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let game {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                    ForEach(1...10, id: \.self) { slot in
                        slotChip(for: game, slot: slot)
                    }
                }
                .id(refreshToken)
            } else {
                emptyState
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.accentColor())
            Text(SakuraL10n.tr("library.external.section.saves"))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        Text(SakuraL10n.tr("library.external.saves.empty"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(theme.glassTextTertiary(colorScheme))
            .padding(.vertical, 8)
    }

    @ViewBuilder
    private func slotChip(for game: GameItem, slot: Int) -> some View {
        let exists = SakuraBridge.hasSaveState(inSlot: Int32(slot), forISOFileName: game.fileName)
        let date = SakuraBridge.saveStateDate(forSlot: Int32(slot), forISOFileName: game.fileName)
        let slotFocus = isFocused && focusedSlot == slot
        let accent = theme.accentColor()

        Button {
            SFXManager.shared.play(exists ? .confirm : .error)
            if exists { onLoadSlot(slot) }
        } label: {
            VStack(spacing: 2) {
                // square tiles. aspectRatio 1 lets the LazyVGrid pick the
                // width from the available column slot and the height follows.
                // no fixed height = no long-rectangle look.
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(exists
                            ? accent.opacity(slotFocus ? 0.55 : 0.38)
                            : theme.glassTileBackground(colorScheme, isFocused: slotFocus))
                    Text("\(slot)")
                        .font(.system(size: 18, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(exists
                            ? .white
                            : theme.glassTextTertiary(colorScheme).opacity(0.6))
                }
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(exists
                            ? accent.opacity(0.8)
                            : theme.glassTileStroke(colorScheme, isFocused: slotFocus),
                            lineWidth: exists ? 1.2 : 1)
                )
                .sakuraFocusRing(isFocused: slotFocus, controllerActive: true, cornerRadius: 8)

                Text(shortCaption(for: date, exists: exists))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(exists
                        ? theme.glassTextSecondary(colorScheme)
                        : theme.glassTextTertiary(colorScheme).opacity(0.6))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .buttonStyle(.plain)
    }

    private func shortCaption(for date: Date?, exists: Bool) -> String {
        guard exists else { return "—" }
        guard let date else { return SakuraL10n.tr("library.external.saves.slotSaved") }
        return PlaytimeStore.formatLastPlayed(date)
    }
}
