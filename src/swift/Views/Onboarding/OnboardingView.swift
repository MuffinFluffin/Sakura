// SPDX-License-Identifier: GPL-3.0+

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var theme = ThemeManager.shared
    @State private var gamepad = GamepadNavigation.shared
    @State private var currentPage = 0
    private let totalPages = 4
    @AppStorage(AppLocale.appStorageKey) private var localeOverrideRaw = ""
    @State private var showLanguagePicker = false
    @State private var pickerLocaleOverrideRaw = ""
    @Environment(\.colorScheme) private var colorScheme

    @State private var showBackdropImageSourceDialog = false
    @State private var showBackdropVideoSourceDialog = false
    @State private var showBackdropImageImporter = false
    @State private var showBackdropVideoImporter = false
    @State private var showBackdropImageFileImporter = false
    @State private var showBackdropVideoFileImporter = false
    @State private var backdropImageSelection: PhotosPickerItem?
    @State private var backdropVideoSelection: PhotosPickerItem?

    @State private var showOnboardingMusicFileImporter = false
    @State private var musicImportError: String?

    private enum OnboardingMusicPack: CaseIterable, Hashable {
        case featured
        case all
        case none

        var localizationKey: String {
            switch self {
            case .featured: return "onboarding.musicPack.featured"
            case .all: return "onboarding.musicPack.all"
            case .none: return "onboarding.musicPack.skip"
            }
        }
    }

    @State private var selectedMusicPack: OnboardingMusicPack = .featured

    private static let backdropImageFileTypes: [UTType] = [
        .image, .jpeg, .png, .heic, .webP, .gif, .tiff,
    ]
    private static let backdropVideoFileTypes: [UTType] = [
        .movie, .mpeg4Movie, .quickTimeMovie,
        UTType(filenameExtension: "avi") ?? .movie,
    ]
    private static let onboardingMusicFileTypes: [UTType] = {
        let exts = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf"]
        var types = exts.compactMap { UTType(filenameExtension: $0) }
        if !types.contains(.audio) { types.append(.audio) }
        return types
    }()

    var body: some View {
        onboardingWithPhotoBindings
    }

    private var onboardingCore: some View {
        ZStack {
            AppBackdrop()

            VStack(spacing: 0) {
                pageIndicator
                    .padding(.top, 16)

                TabView(selection: $currentPage) {
                    languagePage.tag(0)
                    welcomePage.tag(1)
                    devicePage.tag(2)
                    setupPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(theme.onboardingPageTransitionAnimation, value: currentPage)

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            MusicPlayer.shared.startOnboardingMusic()
        }
        .onChange(of: gamepad.actionID) { _, _ in
            handleGamepadAction(gamepad.lastAction)
        }
        .confirmationDialog(
            SakuraL10n.tr("ui.dialog.backgroundImageTitle"),
            isPresented: $showBackdropImageSourceDialog,
            titleVisibility: .visible
        ) {
            onboardingBackdropImageDialogActions
        }
        .confirmationDialog(
            SakuraL10n.tr("ui.dialog.backgroundVideoTitle"),
            isPresented: $showBackdropVideoSourceDialog,
            titleVisibility: .visible
        ) {
            onboardingBackdropVideoDialogActions
        }
        .sheet(isPresented: $showLanguagePicker) {
            languagePickerSheet
        }
        .fileImporter(
            isPresented: $showBackdropImageFileImporter,
            allowedContentTypes: Self.backdropImageFileTypes,
            allowsMultipleSelection: false
        ) { result in
            onboardingBackdropImageFileImport(result)
        }
        .fileImporter(
            isPresented: $showBackdropVideoFileImporter,
            allowedContentTypes: Self.backdropVideoFileTypes,
            allowsMultipleSelection: false
        ) { result in
            onboardingBackdropVideoFileImport(result)
        }
        .fileImporter(
            isPresented: $showOnboardingMusicFileImporter,
            allowedContentTypes: Self.onboardingMusicFileTypes,
            allowsMultipleSelection: true
        ) { result in
            onboardingMusicFileImport(result)
        }
        .photosPicker(
            isPresented: $showBackdropImageImporter,
            selection: $backdropImageSelection,
            matching: .images
        )
        .photosPicker(
            isPresented: $showBackdropVideoImporter,
            selection: $backdropVideoSelection,
            matching: .videos
        )
    }

    private var onboardingWithPhotoBindings: some View {
        onboardingCore
            .onChange(of: backdropImageSelection) { _, newValue in
                guard let item = newValue else { return }
                Task { await handlePhotosBackdrop(item, type: "image") }
            }
            .onChange(of: backdropVideoSelection) { _, newValue in
                guard let item = newValue else { return }
                Task { await handlePhotosBackdrop(item, type: "video") }
            }
    }

    @ViewBuilder
    private var onboardingBackdropImageDialogActions: some View {
        Button(SakuraL10n.tr("common.photoLibrary")) { showBackdropImageImporter = true }
        Button(SakuraL10n.tr("common.files")) { showBackdropImageFileImporter = true }
        if theme.bgMediaType == "image" {
            Button(SakuraL10n.tr("common.remove"), role: .destructive) {
                clearCustomBackdropMedia()
            }
        }
        Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
    }

    @ViewBuilder
    private var onboardingBackdropVideoDialogActions: some View {
        Button(SakuraL10n.tr("common.photoLibrary")) { showBackdropVideoImporter = true }
        Button(SakuraL10n.tr("common.files")) { showBackdropVideoFileImporter = true }
        if theme.bgMediaType == "video" {
            Button(SakuraL10n.tr("common.remove"), role: .destructive) {
                clearCustomBackdropMedia()
            }
        }
        Button(SakuraL10n.tr("common.cancel"), role: .cancel) {}
    }

    private func onboardingBackdropImageFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            handleFilesBackdrop(url, type: "image")
        case .failure(let err):
            SakuraLogUnified("Theme", "Warning", "Onboarding image import: \(err.localizedDescription)")
        }
    }

    private func onboardingBackdropVideoFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            handleFilesBackdrop(url, type: "video")
        case .failure(let err):
            SakuraLogUnified("Theme", "Warning", "Onboarding video import: \(err.localizedDescription)")
        }
    }

    private func onboardingMusicFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            handleOnboardingMusicFileURLs(urls)
        case .failure(let err):
            musicImportError = err.localizedDescription
        }
    }

    private func handleGamepadAction(_ action: GamepadAction?) {
        guard let action else { return }
        switch action {
        case .moveLeft, .shoulderLeft:
            if currentPage > 0 { withAnimation(theme.onboardingPageTransitionAnimation) { currentPage -= 1 } }
        case .moveRight, .shoulderRight:
            if currentPage < totalPages - 1 { withAnimation(theme.onboardingPageTransitionAnimation) { currentPage += 1 } }
        case .confirm:
            if currentPage < totalPages - 1 {
                withAnimation(theme.onboardingPageTransitionAnimation) { currentPage += 1 }
            } else {
                onFinish()
            }
        case .back:
            if currentPage > 0 { withAnimation(theme.onboardingPageTransitionAnimation) { currentPage -= 1 } }
        default:
            break
        }
    }


    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalPages, id: \.self) { i in
                Capsule()
                    .fill(i == currentPage ? theme.accentColor() : theme.glassTextTertiary(colorScheme).opacity(0.4))
                    .frame(width: i == currentPage ? 24 : 8, height: 8)
                    .animation(theme.onboardingDotsAnimation, value: currentPage)
            }
        }
    }


    private var bottomBar: some View {
        HStack {
            if currentPage > 0 {
                Button {
                    withAnimation(theme.onboardingPageTransitionAnimation) { currentPage -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(SakuraL10n.tr("onboarding.back"))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if currentPage < totalPages - 1 {
                Button {
                    withAnimation(theme.onboardingPageTransitionAnimation) { currentPage += 1 }
                } label: {
                    HStack(spacing: 4) {
                        Text(SakuraL10n.tr("onboarding.next"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.accentColor())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.accentColor().opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    onFinish()
                } label: {
                    HStack(spacing: 4) {
                        Text(SakuraL10n.tr("onboarding.start"))
                        Image(systemName: "arrow.right")
                    }
                    .font(.headline.weight(.bold))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(theme.accentColor())
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }


    private var languagePage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                Spacer().frame(height: 12)

                Text(SakuraL10n.tr("onboarding.lang.title"))
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(SakuraL10n.tr("onboarding.lang.note"))
                    .font(.caption)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)

                onboardCard(icon: "globe", title: SakuraL10n.tr("onboarding.card.appLanguage")) {
                    languagePickerButton
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }

    private var languagePickerButton: some View {
        Button {
            openLanguagePicker()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(theme.accentColor())
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SakuraL10n.tr("general.tile.appLanguage"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                    Text(selectedLanguageLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.glassCardFill(colorScheme, isFocused: false).opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.glassCardStroke(colorScheme, isFocused: false), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                openLanguagePicker()
            }
        )
    }

    private var languagePickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker(SakuraL10n.tr("general.tile.appLanguage"), selection: $pickerLocaleOverrideRaw) {
                    ForEach(AppLocale.options) { opt in
                        Text(AppLocale.localizedLanguageLabel(for: opt, overrideRaw: pickerLocaleOverrideRaw))
                            .tag(opt.id)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .navigationTitle(SakuraL10n.tr("onboarding.card.appLanguage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(SakuraL10n.tr("common.done")) {
                        localeOverrideRaw = pickerLocaleOverrideRaw
                        showLanguagePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private var selectedLanguageLabel: String {
        let option = AppLocale.options.first { $0.id == localeOverrideRaw } ?? AppLocale.options[0]
        return AppLocale.localizedLanguageLabel(for: option, overrideRaw: localeOverrideRaw)
    }

    private func openLanguagePicker() {
        pickerLocaleOverrideRaw = localeOverrideRaw
        showLanguagePicker = true
    }


    private var welcomePage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
                Spacer().frame(height: 12)

                onboardCard(icon: "arrow.down.circle.fill", title: SakuraL10n.tr("onboarding.card.gettingStarted")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(SakuraL10n.tr("onboarding.gettingStarted.body1"))
                            .font(.subheadline)
                            .foregroundStyle(theme.glassTextPrimary(colorScheme))

                        Text(SakuraL10n.tr("onboarding.gettingStarted.body2"))
                            .font(.caption)
                            .foregroundStyle(theme.glassTextSecondary(colorScheme))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(SakuraL10n.tr("onboarding.gettingStarted.supported"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.glassTextSecondary(colorScheme))
                            Text(SakuraL10n.tr("onboarding.gettingStarted.formatsLine"))
                                .font(.caption)
                                .foregroundStyle(theme.glassTextTertiary(colorScheme))
                        }
                        .padding(.top, 4)
                    }
                }

                onboardCard(icon: "gamecontroller.fill", title: SakuraL10n.tr("onboarding.card.supportedSystem")) {
                    Text(SakuraL10n.tr("onboarding.supportedSystem.console"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                }

                onboardCard(icon: "heart.fill", title: SakuraL10n.tr("onboarding.card.thankYouTitle"), iconTint: .pink) {
                    Text(SakuraL10n.tr("onboarding.thankYou.purchase"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                    Text(SakuraL10n.tr("onboarding.thankYou.whereHelp"))
                        .font(.caption)
                        .foregroundStyle(theme.glassTextSecondary(colorScheme))
                        .padding(.top, 4)
                }

                discordCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }


    private var devicePage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                Spacer().frame(height: 12)

                deviceInfoCard

                deviceCapabilitiesCard

                onboardCard(icon: "gauge.with.dots.needle.67percent", title: SakuraL10n.tr("onboarding.performance.title")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SakuraL10n.tr("onboarding.performance.body1"))
                            .font(.caption)
                            .foregroundStyle(theme.glassTextSecondary(colorScheme))

                        Text(SakuraL10n.tr("onboarding.performance.body2"))
                            .font(.caption)
                            .foregroundStyle(theme.glassTextSecondary(colorScheme))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }



    private var setupPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 20) {
                Spacer().frame(height: 12)

                Text(SakuraL10n.tr("onboarding.quickSetup.title"))
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))

                Text(SakuraL10n.tr("onboarding.quickSetup.subtitle"))
                    .font(.caption)
                    .foregroundStyle(theme.glassTextTertiary(colorScheme))

                onboardCard(icon: "photo.on.rectangle.angled", title: SakuraL10n.tr("onboarding.bg.cardTitle")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(SakuraL10n.tr("onboarding.bg.subtitle"))
                            .font(.caption)
                            .foregroundStyle(theme.glassTextSecondary(colorScheme))

                        HStack(spacing: 8) {
                            backgroundPresetButton(SakuraL10n.tr("theme.backdrop.sakura"), selected: theme.backdropKey == "sakura") {
                                theme.backdropKey = "sakura"
                            }
                            backgroundPresetButton(SakuraL10n.tr("theme.backdrop.onyx"), selected: theme.backdropKey == "onyx") {
                                theme.backdropKey = "onyx"
                            }
                            backgroundPresetButton(SakuraL10n.tr("theme.backdrop.whiteout"), selected: theme.backdropKey == "whiteout") {
                                theme.backdropKey = "whiteout"
                            }
                        }

                        Button {
                            showBackdropImageSourceDialog = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "photo.fill")
                                    .foregroundStyle(theme.bgMediaType == "image" ? theme.accentColor() : theme.glassTextTertiary(colorScheme))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SakuraL10n.tr("onboarding.bg.imageRowTitle"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                                    Text(onboardingBackgroundMediaCaption(for: "image"))
                                        .font(.caption2)
                                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            showBackdropVideoSourceDialog = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "film.fill")
                                    .foregroundStyle(theme.bgMediaType == "video" ? theme.accentColor() : theme.glassTextTertiary(colorScheme))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SakuraL10n.tr("onboarding.bg.videoRowTitle"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                                    Text(onboardingBackgroundMediaCaption(for: "video"))
                                        .font(.caption2)
                                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.glassTextTertiary(colorScheme))
                            }
                        }
                        .buttonStyle(.plain)

                        if theme.bgMediaType != "none" {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(SakuraL10n.tr("onboarding.bg.mediaStrength"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(theme.glassTextSecondary(colorScheme))
                                    Spacer()
                                    Text(String(format: "%.0f%%", theme.bgMediaOpacity * 100))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                                }
                                Slider(value: Binding(
                                    get: { theme.bgMediaOpacity },
                                    set: { theme.bgMediaOpacity = $0 }
                                ), in: 0...1, step: 0.05)
                                    .tint(theme.accentColor())
                            }
                            .padding(.top, 4)
                        }
                    }
                }

                onboardCard(icon: "music.note.list", title: SakuraL10n.tr("onboarding.menuMusic.cardTitle")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(SakuraL10n.tr("onboarding.menuMusic.intro"))
                            .font(.caption)
                            .foregroundStyle(theme.glassTextSecondary(colorScheme))

                        ForEach(OnboardingMusicPack.allCases, id: \.self) { pack in
                            Button {
                                selectedMusicPack = pack
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedMusicPack == pack ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedMusicPack == pack ? theme.accentColor() : theme.glassTextTertiary(colorScheme).opacity(0.5))
                                    Text(SakuraL10n.tr(pack.localizationKey))
                                        .font(.subheadline)
                                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            musicImportError = nil
                            showOnboardingMusicFileImporter = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "square.and.arrow.down.fill")
                                    .foregroundStyle(theme.accentColor())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(SakuraL10n.tr("onboarding.music.importRowTitle"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                                    Text(SakuraL10n.tr("onboarding.music.importRowSubtitle"))
                                        .font(.caption2)
                                        .foregroundStyle(theme.glassTextTertiary(colorScheme))
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)

                        if let musicImportError {
                            Text(musicImportError)
                                .font(.caption2)
                                .foregroundStyle(.orange.opacity(0.95))
                        }
                    }
                }

                accessibilityCard

                themeCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .onDisappear {
            triggerMusicDownloadIfNeeded()
        }
    }

    private func backgroundPresetButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(selected ? theme.accentColor() : theme.glassTextTertiary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selected ? theme.accentColor().opacity(0.12) : theme.glassCardFill(colorScheme, isFocused: false).opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? theme.accentColor().opacity(0.35) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func handlePhotosBackdrop(_ item: PhotosPickerItem, type: String) async {
        defer {
            if type == "image" { backdropImageSelection = nil }
            else { backdropVideoSelection = nil }
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                SakuraLogUnified("Theme", "Warning", "Onboarding backdrop photos load nil")
                return
            }
            let ext: String = {
                if type == "video" { return "mov" }
                if data.count >= 4 {
                    let b = [UInt8](data.prefix(4))
                    if b[0] == 0x89 && b[1] == 0x50 { return "png" }
                    if b[0] == 0xFF && b[1] == 0xD8 { return "jpg" }
                }
                return "jpg"
            }()
            let stamp = Int(Date().timeIntervalSince1970)
            let safeName = "\(stamp)-photos.\(ext)"
            let dest = ThemeManager.backgroundMediaDir.appendingPathComponent(safeName)
            try? FileManager.default.createDirectory(at: ThemeManager.backgroundMediaDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try data.write(to: dest)
            theme.bgMediaFilename = safeName
            theme.bgMediaType = type
            if type == "image" { BackgroundVideo.shared.teardown() }
            SakuraLogUnified("Theme", "Info", "Onboarding backdrop \(type): \(safeName)")
        } catch {
            SakuraLogUnified("Theme", "Warning", "Onboarding Photos backdrop: \(error.localizedDescription)")
        }
    }

    private func handleFilesBackdrop(_ url: URL, type: String) {
        do {
            let safeName = try ThemeManager.importBackdropFromFilesPicker(url, type: type)
            theme.bgMediaFilename = safeName
            theme.bgMediaType = type
            if type == "image" { BackgroundVideo.shared.teardown() }
            SakuraLogUnified("Theme", "Info", "Onboarding backdrop \(type) from Files: \(safeName)")
        } catch {
            SakuraLogUnified("Theme", "Warning", "Onboarding Files backdrop: \(error.localizedDescription)")
        }
    }

    private func clearCustomBackdropMedia() {
        if let url = theme.backgroundMediaURL(),
           ThemeManager.isUnderBackdropSandbox(url) {
            try? FileManager.default.removeItem(at: url)
        }
        theme.bgMediaType = "none"
        theme.bgMediaFilename = ""
        BackgroundVideo.shared.teardown()
    }

    private func onboardingBackgroundMediaCaption(for type: String) -> String {
        guard theme.bgMediaType == type else {
            return SakuraL10n.tr("onboarding.bg.caption.placeholder")
        }
        let name = theme.bgMediaFilename
        if ThemeManager.isCherryBlossomsBackdrop(name) {
            return SakuraL10n.tr("onboarding.bg.caption.cherryBlossoms")
        }
        let logical = ThemeManager.normalizedBackdropFilename(name)
        if let dash = logical.firstIndex(of: "-") {
            return String(logical[logical.index(after: dash)...])
        }
        let placeholder = SakuraL10n.tr("onboarding.bg.caption.placeholder")
        return name.isEmpty ? placeholder : ThemeManager.normalizedBackdropFilename(name)
    }

    private func handleOnboardingMusicFileURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let userRoot = MusicCatalog.musicRoot.appendingPathComponent("user")
        try? FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        var lastImportedURL: URL?
        for url in urls {
            guard MusicCatalog.isSupportedAudio(url) else { continue }
            let dest = userRoot.appendingPathComponent(url.lastPathComponent)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                lastImportedURL = dest
                SakuraLogUnified("Music", "Info", "Onboarding import: \(url.lastPathComponent)")
            } catch {
                musicImportError = error.localizedDescription
                SakuraLogUnified("Music", "Warning", "Onboarding import: \(error.localizedDescription)")
            }
        }
        MusicPlayer.shared.refreshPlaylist()
        if let u = lastImportedURL {
            MusicPlayer.shared.setOnboardingLoopPlayback(url: u)
        }
    }

    private func triggerMusicDownloadIfNeeded() {
        switch selectedMusicPack {
        case .featured:
            Task {
                _ = await MusicCatalog.downloadAll(MusicCatalog.featured)
            }
        case .all:
            Task {
                _ = await MusicCatalog.downloadAll(MusicCatalog.allCatalog)
            }
        case .none:
            break
        }
    }


    private var accessibilityCard: some View {
        onboardCard(icon: "accessibility", title: SakuraL10n.tr("onboarding.accessibility.cardTitle")) {
            VStack(alignment: .leading, spacing: 14) {
                accessibilityToggle(
                    SakuraL10n.tr("ui.theme.reduceMotion"),
                    icon: "tortoise.fill",
                    isOn: Binding(
                        get: { theme.reduceMotion },
                        set: { theme.reduceMotion = $0 }
                    ),
                    description: SakuraL10n.tr("onboarding.ax.reduceMotion.desc")
                )

                accessibilityToggle(
                    SakuraL10n.tr("ui.theme.reduceTransparency"),
                    icon: "square.fill",
                    isOn: Binding(
                        get: { theme.reduceTransparency },
                        set: { theme.reduceTransparency = $0 }
                    ),
                    description: SakuraL10n.tr("onboarding.ax.reduceTransparency.desc")
                )

                accessibilityToggle(
                    SakuraL10n.tr("ui.theme.increaseContrast"),
                    icon: "circle.lefthalf.filled",
                    isOn: Binding(
                        get: { theme.increaseContrast },
                        set: { theme.increaseContrast = $0 }
                    ),
                    description: SakuraL10n.tr("onboarding.ax.increaseContrast.desc")
                )

                accessibilityToggle(
                    SakuraL10n.tr("onboarding.soundEffects.title"),
                    icon: "speaker.wave.2.fill",
                    isOn: Binding(
                        get: { SFXManager.shared.enabled },
                        set: { SFXManager.shared.enabled = $0 }
                    ),
                    description: SakuraL10n.tr("onboarding.ax.soundEffects.desc")
                )
            }
        }
    }

    @ViewBuilder
    private func accessibilityToggle(
        _ title: String,
        icon: String,
        isOn: Binding<Bool>,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: isOn) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.accentColor())
                        .frame(width: 20)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme))
                }
            }
            .tint(theme.accentColor())

            Text(description)
                .font(.caption2)
                .foregroundStyle(theme.glassTextTertiary(colorScheme))
                .padding(.leading, 28)
        }
    }


    private var themeCard: some View {
        onboardCard(icon: "paintbrush.fill", title: SakuraL10n.tr("onboarding.theme.cardTitle")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(SakuraL10n.tr("onboarding.theme.subtitle"))
                    .font(.caption)
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))

                HStack(spacing: 12) {
                    themeButton(SakuraL10n.tr("onboarding.theme.scheme.dark"), icon: "moon.fill", selected: theme.colorSchemeKey == "dark") {
                        theme.colorSchemeKey = "dark"
                    }
                    themeButton(SakuraL10n.tr("onboarding.theme.scheme.light"), icon: "sun.max.fill", selected: theme.colorSchemeKey == "light") {
                        theme.colorSchemeKey = "light"
                    }
                    themeButton(SakuraL10n.tr("onboarding.theme.scheme.auto"), icon: "circle.lefthalf.filled", selected: theme.colorSchemeKey == "auto") {
                        theme.colorSchemeKey = "auto"
                    }
                }

                HStack(spacing: 12) {
                    themeButton(SakuraL10n.tr("onboarding.theme.shape.rounded"), icon: "app", selected: !theme.boxyCorners) {
                        theme.boxyCorners = false
                    }
                    themeButton(SakuraL10n.tr("onboarding.theme.shape.boxy"), icon: "rectangle", selected: theme.boxyCorners) {
                        theme.boxyCorners = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func themeButton(_ label: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(selected ? theme.accentColor() : theme.glassTextTertiary(colorScheme))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        selected
                            ? theme.accentColor().opacity(0.12)
                            : theme.glassCardFill(colorScheme, isFocused: false).opacity(0.7)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? theme.accentColor().opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }


    private var deviceCapabilitiesCard: some View {
        onboardCard(icon: "sparkles.rectangle.stack", title: SakuraL10n.tr("onboarding.capabilities.cardTitle")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(SakuraL10n.tr("onboarding.capabilities.intro"))
                    .font(.caption)
                    .foregroundStyle(theme.glassTextSecondary(colorScheme))

                ForEach(DeviceInfo.advancedGraphicsCapabilities) { cap in
                    capabilityRow(cap)
                }
            }
        }
    }

    @ViewBuilder
    private func capabilityRow(_ cap: DeviceInfo.Capability) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: cap.supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(
                    cap.supported
                        ? Color.green
                        : Color(red: 0.95, green: 0.45, blue: 0.4)
                )
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(cap.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.glassTextPrimary(colorScheme))
                Text(cap.requirement)
                    .font(.caption2)
                    .foregroundStyle(
                        cap.supported
                            ? theme.glassTextTertiary(colorScheme)
                            : theme.glassTextSecondary(colorScheme)
                    )
            }
            Spacer(minLength: 0)
            Text(SakuraL10n.tr(cap.supported
                ? "onboarding.capabilities.statusSupported"
                : "onboarding.capabilities.statusUnsupported"))
                .font(.caption2.weight(.bold))
                .foregroundStyle(
                    cap.supported
                        ? Color.green
                        : Color(red: 0.95, green: 0.45, blue: 0.4)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        (cap.supported
                            ? Color.green
                            : Color(red: 0.95, green: 0.45, blue: 0.4))
                            .opacity(0.12)
                    )
                )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.glassCardFill(colorScheme, isFocused: false).opacity(0.7))
        )
    }


    private var deviceInfoCard: some View {
        onboardCard(icon: "iphone", title: SakuraL10n.tr("onboarding.card.hardware")) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    deviceStat(label: SakuraL10n.tr("onboarding.device.model"), value: DeviceInfo.modelName)
                    deviceStat(label: SakuraL10n.tr("help.aboutRow.cpu"), value: DeviceInfo.cpuName)
                    deviceStat(label: SakuraL10n.tr("help.aboutRow.gpu"), value: DeviceInfo.gpuName)
                    deviceStat(label: SakuraL10n.tr("help.aboutRow.ram"), value: DeviceInfo.totalRAMString)
                    deviceStat(label: SakuraL10n.tr("onboarding.device.systemLabel"), value: DeviceInfo.iosVersion)
                        .gridCellColumns(2)
                }

                let tier = DeviceInfo.performanceTier
                HStack(spacing: 8) {
                    Circle()
                        .fill(tierColor(tier))
                        .frame(width: 10, height: 10)
                    Text(SakuraL10n.trf("onboarding.device.performanceFmt", tierLabel(tier)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))
                }
                .padding(.top, 4)
            }
        }
    }


    private var discordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.accentColor())
                Text(SakuraL10n.tr("onboarding.discord.cardTitle"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(theme.accentColor())
            }

            Text(SakuraL10n.tr("onboarding.discord.blurb"))
                .font(.subheadline)
                .foregroundStyle(theme.glassTextPrimary(colorScheme).opacity(0.9))

            Button {
                CommunityLink.openDiscordInvite()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(SakuraL10n.tr("onboarding.discord.button"))
                        .font(.headline.weight(.bold))
                }
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.accentColor())
                )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.glassCardFill(colorScheme, isFocused: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.glassCardStroke(colorScheme, isFocused: false), lineWidth: 1)
        )
    }


    @ViewBuilder
    private func onboardCard<Content: View>(
        icon: String,
        title: String,
        iconTint: Color? = nil,
        tintColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let tint = iconTint ?? tintColor ?? theme.accentColor()
        let borderColor = tintColor ?? theme.glassCardStroke(colorScheme, isFocused: false)
        let borderOpacity: Double = tintColor != nil ? 0.5 : 1.0

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(tint)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.glassCardFill(colorScheme, isFocused: false))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor.opacity(borderOpacity), lineWidth: 1)
        )
    }

    private func deviceStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(theme.accentColor())
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.glassTextPrimary(colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.glassCardFill(colorScheme, isFocused: false).opacity(0.85))
        )
    }

    private func tierColor(_ tier: DeviceInfo.PerformanceTier) -> Color {
        switch tier {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    private func tierLabel(_ tier: DeviceInfo.PerformanceTier) -> String {
        switch tier {
        case .good: return SakuraL10n.tr("onboarding.performance.tier.good")
        case .fair: return SakuraL10n.tr("onboarding.performance.tier.fair")
        case .poor: return SakuraL10n.tr("onboarding.performance.tier.poor")
        }
    }
}
