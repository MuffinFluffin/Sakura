// SPDX-License-Identifier: GPL-3.0+

import SwiftUI

struct MusicFirstBootPrompt: View {
    @Binding var isPresented: Bool
    @State private var selected: Set<String> = Set(MusicCatalog.allCatalog.map { $0.slug })
    @State private var isDownloading = false
    @State private var downloadStatus: [String: DownloadStatus] = [:]
    @State private var errorMessage: String?

    enum DownloadStatus: Equatable {
        case pending
        case downloading
        case done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(SakuraL10n.tr("musicFirstBoot.navTitle"))
                    .font(.title2.weight(.semibold))
                    .padding(.top, 8)

                Text(SakuraL10n.tr("musicFirstBoot.intro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                List {
                    ForEach(MusicCatalog.allCatalog) { track in
                        HStack {
                            Button {
                                guard !isDownloading else { return }
                                if selected.contains(track.slug) {
                                    selected.remove(track.slug)
                                } else {
                                    selected.insert(track.slug)
                                }
                            } label: {
                                Image(systemName: selected.contains(track.slug) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(track.slug) ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.body.weight(.semibold))
                                Text(track.artist).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusView(for: track.slug)
                        }
                        .contentShape(Rectangle())
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 260)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button(SakuraL10n.tr("musicFirstBoot.dontAskAgain")) {
                        UserDefaults.standard.set(true, forKey: "sakura.music.firstBoot.skipped")
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDownloading)

                    Spacer()

                    Button(SakuraL10n.tr("musicFirstBoot.notNow")) {
                        isPresented = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDownloading)

                    Button {
                        Task { await runDownload() }
                    } label: {
                        if isDownloading {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(SakuraL10n.tr("common.download"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading || selected.isEmpty)
                }
                .padding(.top, 4)

                Text(SakuraL10n.tr("musicFirstBoot.footerCredits"))
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.8))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func statusView(for slug: String) -> some View {
        switch downloadStatus[slug] {
        case .downloading:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }

    private func runDownload() async {
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }

        let picks = MusicCatalog.allCatalog.filter { selected.contains($0.slug) }
        for track in picks {
            downloadStatus[track.slug] = .downloading
            do {
                _ = try await MusicCatalog.download(track)
                downloadStatus[track.slug] = .done
            } catch {
                downloadStatus[track.slug] = .failed(error.localizedDescription)
                errorMessage = "\(track.title): \(error.localizedDescription)"
            }
        }

        MusicPlayer.shared.refreshPlaylist()

        UserDefaults.standard.set(true, forKey: "sakura.music.firstBoot.done")
        if downloadStatus.values.contains(where: { if case .done = $0 { return true } else { return false } }) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            isPresented = false
        }
    }
}
