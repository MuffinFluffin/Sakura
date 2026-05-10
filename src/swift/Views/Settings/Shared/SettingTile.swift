// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import Observation

private enum SettingsHeadingFont {
    static func pointSize(labelLength n: Int, base: CGFloat) -> CGFloat {
        if n <= 12 { return base }
        if n <= 20 { return max(9, base - 1.5) }
        if n <= 32 { return max(8.5, base - 2.25) }
        return max(7.5, base - 3)
    }
}

// MARK: - Focus bus (controller / D-pad)

@Observable
@MainActor
final class TileFocus: @unchecked Sendable {
    static let shared = TileFocus()

    private struct TilePosition {
        let section: Int
        let indexInSection: Int
        let row: Int
        let column: Int
    }

    enum Region {
        case topBar
        case content
    }

    var region: Region = .topBar

    var focusedID: String? = nil

    private(set) var orderedIDs: [String] = []
    private var sectionIDs: [[String]] = []
    private var positions: [String: TilePosition] = [:]

    private var currentPageKey: String = ""
    private var focusedIDByPage: [String: String] = [:]

    private var sectionColumnCounts: [Int] = []

    private var fallbackColumnHint: Int = 3

    var triggerID: String? = nil
    var triggerTick: UInt = 0

    var isCapturing: Bool = false

    var isEditingSlider: Bool = false

    var nudgeTick: UInt = 0
    var nudgeDelta: Int = 0

    func requestSliderNudge(_ delta: Int) {
        guard region == .content, focusedID != nil, delta != 0 else { return }
        nudgeDelta = delta
        nudgeTick &+= 1
    }

    func setPage(ids: [String], columnHint: Int = 3) {
        setPage(sections: ids.isEmpty ? [] : [ids], columnHint: columnHint)
    }

    func setPage(sections: [[String]], columnHint: Int = 3) {
        if !currentPageKey.isEmpty,
           let focusedID,
           orderedIDs.contains(focusedID) {
            focusedIDByPage[currentPageKey] = focusedID
        }

        fallbackColumnHint = max(1, columnHint)
        sectionIDs = sections
            .map { $0.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
        orderedIDs = sectionIDs.flatMap { $0 }
        sectionColumnCounts = Array(repeating: fallbackColumnHint, count: sectionIDs.count)
        isEditingSlider = false
        rebuildPositions()

        let newPageKey = orderedIDs.joined(separator: "|")
        currentPageKey = newPageKey

        if let savedID = focusedIDByPage[newPageKey], orderedIDs.contains(savedID) {
            focusedID = savedID
        } else if focusedID == nil || !(orderedIDs.contains(focusedID ?? "")) {
            focusedID = orderedIDs.first
        }

        rememberCurrentFocus()
    }

    func reportColumnCount(_ count: Int, forTileID id: String) {
        guard let sectionIndex = positions[id]?.section else { return }
        let clamped = max(1, count)
        guard sectionColumnCounts.indices.contains(sectionIndex) else { return }
        guard sectionColumnCounts[sectionIndex] != clamped else { return }
        sectionColumnCounts[sectionIndex] = clamped
        rebuildPositions()
    }

    func columnCount(forTileID id: String) -> Int {
        guard let sectionIndex = positions[id]?.section,
              sectionColumnCounts.indices.contains(sectionIndex) else {
            return fallbackColumnHint
        }
        return sectionColumnCounts[sectionIndex]
    }

    private func rebuildPositions() {
        positions = [:]
        for (sectionIndex, ids) in sectionIDs.enumerated() {
            let cols = sectionColumnCounts.indices.contains(sectionIndex)
                ? sectionColumnCounts[sectionIndex]
                : fallbackColumnHint
            let safeCols = max(1, cols)
            for (indexInSection, id) in ids.enumerated() {
                positions[id] = TilePosition(
                    section: sectionIndex,
                    indexInSection: indexInSection,
                    row: indexInSection / safeCols,
                    column: indexInSection % safeCols
                )
            }
        }
    }

    private func rememberCurrentFocus() {
        guard !currentPageKey.isEmpty,
              let focusedID,
              orderedIDs.contains(focusedID) else { return }
        focusedIDByPage[currentPageKey] = focusedID
    }

    func move(_ delta: Int) {
        guard !isCapturing, region == .content, !orderedIDs.isEmpty, delta != 0 else { return }
        let fallbackID = focusedID ?? orderedIDs.first
        guard let currentID = fallbackID,
              let pos = positions[currentID] else { return }
        let ids = sectionIDs[pos.section]
        guard !ids.isEmpty else { return }
        let safeCols = max(1, sectionColumnCounts.indices.contains(pos.section)
            ? sectionColumnCounts[pos.section]
            : fallbackColumnHint)

        let rowStart = pos.row * safeCols
        let rowEnd = min(rowStart + safeCols, ids.count)
        let rowLength = rowEnd - rowStart
        guard rowLength > 0 else { return }

        let colInRow = pos.indexInSection - rowStart
        let nextColInRow = ((colInRow + delta) % rowLength + rowLength) % rowLength
        let targetIndex = rowStart + nextColInRow
        let nextID = ids[targetIndex]

        guard nextID != focusedID else { return }
        focusedID = nextID
        rememberCurrentFocus()
        SFXManager.shared.play(.navigate)
    }

    @discardableResult
    func moveRow(_ delta: Int) -> Bool {
        guard !isCapturing, region == .content, !orderedIDs.isEmpty, delta != 0 else { return false }
        let fallbackID = focusedID ?? orderedIDs.first
        guard let currentID = fallbackID,
              let start = positions[currentID] else { return false }

        var current = start
        var targetID = currentID
        let stepCount = abs(delta)

        for _ in 0..<stepCount {
            let nextID: String?
            if delta > 0 {
                nextID = nextRowDown(from: current)
            } else {
                nextID = nextRowUp(from: current)
            }
            guard let nextID, let nextPosition = positions[nextID] else {
                return false
            }
            targetID = nextID
            current = nextPosition
        }

        guard targetID != focusedID else { return false }
        focusedID = targetID
        rememberCurrentFocus()
        SFXManager.shared.play(.navigate)
        return true
    }

    func enterContent() {
        guard !isCapturing else { return }
        region = .content
        if focusedID == nil { focusedID = orderedIDs.first }
        rememberCurrentFocus()
    }

    func exitToTopBar() {
        guard !isCapturing else { return }
        isEditingSlider = false
        region = .topBar
        SFXManager.shared.play(.back)
    }

    func confirm() {
        guard !isCapturing, region == .content, let id = focusedID else { return }
        triggerID = id
        triggerTick &+= 1
    }

    func focusFromTouch(id: String) {
        guard !isCapturing else { return }
        var moved = false
        if region != .content {
            region = .content
            moved = true
        }
        if focusedID != id {
            focusedID = id
            moved = true
        }
        rememberCurrentFocus()
        if moved {
            SFXManager.shared.play(.navigate)
        }
    }

    private func nextRowDown(from position: TilePosition) -> String? {
        let ids = sectionIDs[position.section]
        let safeCols = max(1, sectionColumnCounts.indices.contains(position.section)
            ? sectionColumnCounts[position.section]
            : fallbackColumnHint)
        let rowCount = (ids.count + safeCols - 1) / safeCols
        if position.row + 1 < rowCount {
            let targetIndex = min((position.row + 1) * safeCols + position.column, ids.count - 1)
            return ids[targetIndex]
        }

        let nextSection = position.section + 1
        guard nextSection < sectionIDs.count else { return nil }
        let nextIDs = sectionIDs[nextSection]
        let nextCols = max(1, sectionColumnCounts.indices.contains(nextSection)
            ? sectionColumnCounts[nextSection]
            : fallbackColumnHint)
        let landingColumn = min(position.column, nextCols - 1)
        let landingIndex = min(landingColumn, nextIDs.count - 1)
        return nextIDs[landingIndex]
    }

    private func nextRowUp(from position: TilePosition) -> String? {
        let ids = sectionIDs[position.section]
        let safeCols = max(1, sectionColumnCounts.indices.contains(position.section)
            ? sectionColumnCounts[position.section]
            : fallbackColumnHint)
        if position.row > 0 {
            let targetIndex = (position.row - 1) * safeCols + position.column
            return ids[min(targetIndex, ids.count - 1)]
        }

        let previousSection = position.section - 1
        guard previousSection >= 0 else { return nil }
        let prevIDs = sectionIDs[previousSection]
        let prevCols = max(1, sectionColumnCounts.indices.contains(previousSection)
            ? sectionColumnCounts[previousSection]
            : fallbackColumnHint)
        let prevRowCount = (prevIDs.count + prevCols - 1) / prevCols
        let lastRow = max(0, prevRowCount - 1)
        let lastRowStart = lastRow * prevCols
        let landingColumn = min(position.column, prevCols - 1)
        let landingIndex = min(lastRowStart + landingColumn, prevIDs.count - 1)
        return prevIDs[landingIndex]
    }
}


struct SettingTile: View {
    let id: String
    let icon: String
    let title: String
    let value: String
    var valueTint: Color? = nil
    let action: () -> Void

    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    private var isFocused: Bool {
        focus.focusedID == id && focus.region == .content
    }

    private var tileMinHeight: CGFloat {
        theme.largerTouchTargets ? 140 : 112
    }

    private var strokeColor: Color {
        theme.glassTileStroke(colorScheme, isFocused: isFocused)
    }

    private var strokeWidth: CGFloat {
        if theme.highContrastOutlines {
            return isFocused ? 3 : 2
        }
        if theme.increaseContrast {
            return isFocused ? 3 : 1.5
        }
        return isFocused ? 2.5 : 1
    }

    var body: some View {
        Button(action: {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            action()
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(theme.increaseContrast ? 0.95 : 0.9))
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                Text(title.uppercased())
                    .font(.system(
                        size: SettingsHeadingFont.pointSize(labelLength: title.count, base: 11),
                        weight: .bold,
                        design: .rounded
                    ))
                    .tracking(1.05)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)

                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(valueTint ?? theme.glassTextPrimary(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.52)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: tileMinHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
            .shadow(
                color: isFocused ? theme.glassTileShadow(colorScheme, isFocused: true) : .clear,
                radius: isFocused ? 10 : 0
            )
            .compositingGroup()
            .scaleEffect(isFocused && !theme.reduceMotion ? 1.02 : 1.0)
            .animation(
                theme.reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7),
                value: isFocused
            )
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityHint(SakuraL10n.tr("accessibility.double_tap_change"))
        .accessibilityAddTraits(.isButton)
        .background(TileColumnReporter(id: id))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                SFXManager.shared.play(.confirm)
                action()
            }
        }
    }
}

struct ToggleTile: View {
    let id: String
    let icon: String
    let title: String
    @Binding var isOn: Bool
    var showsSettingNotification: Bool = true

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingTile(
            id: id,
            icon: icon,
            title: title,
            value: isOn ? SakuraL10n.tr("common.on") : SakuraL10n.tr("common.off"),
            valueTint: isOn ? theme.color(forKey: "green") : theme.glassTextSecondary(colorScheme)
        ) {
            isOn.toggle()
            if showsSettingNotification {
                let onStr = SakuraL10n.tr("common.on")
                let offStr = SakuraL10n.tr("common.off")
                SakuraNotificationCenter.shared.postSettingChange(title: title, detail: isOn ? onStr : offStr)
            }
        }
        .accessibilityValue(isOn ? SakuraL10n.tr("common.on") : SakuraL10n.tr("common.off"))
        .accessibilityAddTraits(.isToggle)
    }
}

struct SliderTile: View {
    let id: String
    let icon: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared
    @State private var inEditMode = false
    @Environment(\.colorScheme) private var colorScheme

    private var isFocused: Bool {
        focus.focusedID == id && focus.region == .content
    }

    private var strokeColor: Color {
        theme.glassTileStroke(colorScheme, isFocused: isFocused)
    }

    private var strokeWidth: CGFloat {
        if theme.highContrastOutlines {
            return isFocused ? 3 : 2
        }
        if theme.increaseContrast {
            return isFocused ? 3 : 1.5
        }
        return isFocused ? 2.5 : 1
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                Spacer(minLength: 0)
                if inEditMode {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.color(forKey: "gold"))
                }
            }

            Spacer(minLength: 0)

            Text(title.uppercased())
                .font(.system(
                    size: SettingsHeadingFont.pointSize(labelLength: title.count, base: 11),
                    weight: .bold,
                    design: .rounded
                ))
                .tracking(1.05)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .tint(theme.accentColor())
                Text(format(value))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: theme.largerTouchTargets ? 140 : 112, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                .fill(theme.glassTileBackground(colorScheme, isFocused: isFocused))
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.tileCornerRadius, style: .continuous)
                .stroke(strokeColor, lineWidth: strokeWidth)
        )
        .shadow(
            color: isFocused ? theme.glassTileShadow(colorScheme, isFocused: true) : .clear,
            radius: isFocused ? 10 : 0
        )
        .compositingGroup()
        .scaleEffect(isFocused && !theme.reduceMotion ? 1.02 : 1.0)
        .animation(
            theme.reduceMotion ? .none : .spring(response: 0.3, dampingFraction: 0.7),
            value: isFocused
        )
        .contentShape(Rectangle())
        .onTapGesture {
            focus.focusFromTouch(id: id)
            setEditMode(!inEditMode)
        }
        .accessibilityLabel("\(title), \(format(value))")
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(range.upperBound, value + step)
            case .decrement:
                value = max(range.lowerBound, value - step)
            @unknown default:
                break
            }
        }
        .background(TileColumnReporter(id: id))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                setEditMode(!inEditMode)
            }
        }
        .onChange(of: focus.nudgeTick) { _, _ in
            guard isFocused, inEditMode else { return }
            let delta = Double(focus.nudgeDelta)
            guard delta != 0 else { return }
            let raw = value + delta * step
            let clamped = min(range.upperBound, max(range.lowerBound, raw))
            if clamped != value {
                value = clamped
                SFXManager.shared.play(.toggle)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { setEditMode(false) }
        }
        .id(id)
    }

    private func setEditMode(_ on: Bool) {
        inEditMode = on
        focus.isEditingSlider = on && isFocused
    }
}

struct CycleTile<Value: Hashable>: View {
    let id: String
    let icon: String
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var showsSettingNotification: Bool = true

    var body: some View {
        let fallback = SakuraL10n.tr("common.emdash")
        let label = options.first(where: { $0.value == selection })?.label ?? fallback
        SettingTile(
            id: id,
            icon: icon,
            title: title,
            value: label
        ) {
            advance()
        }
    }

    private func advance() {
        guard !options.isEmpty else { return }
        let currentIndex = options.firstIndex(where: { $0.value == selection }) ?? -1
        let next = options[(currentIndex + 1) % options.count]
        selection = next.value
        if showsSettingNotification {
            let fallback = SakuraL10n.tr("common.emdash")
            let subtitle = options.first(where: { $0.value == selection })?.label ?? fallback
            SakuraNotificationCenter.shared.postSettingChange(title: title, detail: subtitle)
        }
    }
}

struct DestructiveTile: View {
    let id: String
    let icon: String
    let title: String
    let action: () -> Void

    @State private var focus = TileFocus.shared

    private var isFocused: Bool {
        focus.focusedID == id && focus.region == .content
    }

    var body: some View {
        Button(action: {
            focus.focusFromTouch(id: id)
            SFXManager.shared.play(.confirm)
            action()
        }) {
            HStack {
                Image(systemName: icon)
                Text(title)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.red.opacity(isFocused ? 0.22 : 0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        isFocused ? Color.red : Color.red.opacity(0.4),
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            .scaleEffect(isFocused ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
        }
        .buttonStyle(.plain)
        .id(id)
        .background(TileColumnReporter(id: id))
        .onChange(of: focus.triggerTick) { _, _ in
            if focus.triggerID == id && focus.region == .content {
                SFXManager.shared.play(.confirm)
                action()
            }
        }
    }
}

struct SettingSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    @State private var theme = ThemeManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(
                    size: SettingsHeadingFont.pointSize(labelLength: title.count, base: 12),
                    weight: .bold,
                    design: .rounded
                ))
                .tracking(title.count <= 18 ? 1.35 : (title.count <= 28 ? 0.95 : 0.55))
                .foregroundStyle(theme.glassTextSecondary(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.52)
                .multilineTextAlignment(.leading)
                .accessibilityAddTraits(.isHeader)

            content()

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsScroll<Content: View>: View {
    /// Bottom inset for list end; shell pages reserve the action row outside the scroll.
    var bottomPadding: CGFloat = 24
    @ViewBuilder let content: () -> Content

    @State private var focus = TileFocus.shared
    @State private var theme = ThemeManager.shared

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    content()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, bottomPadding)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: focus.focusedID) { _, newID in
                scrollToFocus(proxy: proxy, id: newID)
            }
            .onChange(of: focus.region) { _, newRegion in
                guard newRegion == .content, let id = focus.focusedID else { return }
                scrollToFocus(proxy: proxy, id: id)
            }
            .onAppear {
                guard focus.region == .content, let id = focus.focusedID else { return }
                scrollToFocus(proxy: proxy, id: id)
            }
        }
    }

    private func scrollToFocus(proxy: ScrollViewProxy, id: String?) {
        guard focus.region == .content, let id, !id.isEmpty else { return }
        if theme.reduceMotion {
            proxy.scrollTo(id, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

struct TileGrid<Content: View>: View {
    var minTileWidth: CGFloat?
    var spacing: CGFloat = 14
    @ViewBuilder let content: () -> Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var columnCount: Int = 3

    private var resolvedMinTileWidth: CGFloat {
        if let minTileWidth { return minTileWidth }
        return horizontalSizeClass == .compact ? 148 : 170
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: resolvedMinTileWidth), spacing: spacing)],
            spacing: spacing
        ) {
            content()
        }
        .environment(\.sakuraGridColumnCount, columnCount)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            let minW = resolvedMinTileWidth
            let measured = max(
                1,
                Int(floor((width + spacing) / (minW + spacing)))
            )
            if measured != columnCount {
                columnCount = measured
            }
        }
    }
}

private struct SakuraGridColumnCountKey: EnvironmentKey {
    static let defaultValue: Int = 3
}

extension EnvironmentValues {
    var sakuraGridColumnCount: Int {
        get { self[SakuraGridColumnCountKey.self] }
        set { self[SakuraGridColumnCountKey.self] = newValue }
    }
}

struct TileColumnReporter: View {
    let id: String

    @Environment(\.sakuraGridColumnCount) private var gridColumns: Int
    @State private var focus = TileFocus.shared

    var body: some View {
        Color.clear
            .onAppear { focus.reportColumnCount(gridColumns, forTileID: id) }
            .onChange(of: gridColumns) { _, new in
                focus.reportColumnCount(new, forTileID: id)
            }
    }
}
