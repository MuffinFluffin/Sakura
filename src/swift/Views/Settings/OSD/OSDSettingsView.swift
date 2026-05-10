// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

struct OSDSettingsView: View {
    @Bindable private var settings = SettingsStore.shared
    @State private var focus = TileFocus.shared
    @State private var notif = SakuraNotificationCenter.shared
    @AppStorage("sakura.hud.relOffsetX") private var hudRelOffsetX: Double = 0
    @AppStorage("sakura.hud.relOffsetY") private var hudRelOffsetY: Double = 0

    private var navigationSections: [[String]] {
        var sections: [[String]] = [[
            "emu.pauseOnMenu", "emu.keepSubmenus", "emu.preventSleep", "emu.autoHideBar", "emu.confirmStop",
        ]]
        sections.append(["hud.enable", "hud.refresh", "hud.resetPosition"])
        if settings.hudEnabled {
            sections.append([
                "hud.fps", "hud.speed", "hud.avgLow", "hud.frameTime",
                "hud.cpu", "hud.ram", "hud.gpu",
                "hud.resolution",
                "hud.thermal", "hud.battery", "hud.graphs",
            ])
        }
        sections.append([
            "notif.enable", "notif.position", "notif.max", "notif.duration",
            "notif.evt.controller", "notif.evt.save",
            "notif.evt.music", "notif.evt.import", "notif.evt.bios", "notif.evt.settings",
            "notif.test",
        ])
        return sections
    }

    var body: some View {
        SettingsScroll {
            emulationMenuSection
            hudCoreSection
            if settings.hudEnabled {
                hudMetricsSection
            }
            notificationsSection
        }
        .onAppear {
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.hudEnabled) { _, _ in
            focus.setPage(sections: navigationSections, columnHint: 3)
        }
        .onChange(of: settings.emuMenuPreventScreenSleep) { _, on in
            UIApplication.shared.isIdleTimerDisabled = on
        }
    }

    private var autoHideBarBinding: Binding<AutoHideBarOption> {
        Binding(
            get: { AutoHideBarOption(rawValue: settings.emuMenuAutoHideBarRaw) ?? .off },
            set: { settings.emuMenuAutoHideBarRaw = $0.rawValue }
        )
    }

    private var emulationMenuSection: some View {
        SettingSection(title: SakuraL10n.tr("osd.section.emulationMenu")) {
            TileGrid {
                ToggleTile(
                    id: "emu.pauseOnMenu",
                    icon: "pause.rectangle",
                    title: SakuraL10n.tr("emu.menu.pauseInMenu"),
                    isOn: $settings.pauseOnMenuEnabled
                )
                ToggleTile(
                    id: "emu.keepSubmenus",
                    icon: "list.bullet.indent",
                    title: SakuraL10n.tr("emu.menu.keepSubmenusOpen"),
                    isOn: $settings.emuMenuKeepSubmenusOpen
                )
                ToggleTile(
                    id: "emu.preventSleep",
                    icon: "sun.max.fill",
                    title: SakuraL10n.tr("emu.menu.keepScreenOn"),
                    isOn: $settings.emuMenuPreventScreenSleep
                )
                CycleTile(
                    id: "emu.autoHideBar",
                    icon: "eye.slash",
                    title: SakuraL10n.tr("osd.tile.autoHideTopBar"),
                    options: AutoHideBarOption.allCases.map { ($0, $0.localizedLabel) },
                    selection: autoHideBarBinding
                )
                ToggleTile(
                    id: "emu.confirmStop",
                    icon: "hand.raised.fill",
                    title: SakuraL10n.tr("emu.menu.confirmStop"),
                    isOn: $settings.emuMenuConfirmOnStop
                )
            }
        }
    }

    private var hudCoreSection: some View {
        SettingSection(title: SakuraL10n.tr("osd.section.hudOverlay")) {
            TileGrid {
                ToggleTile(
                    id: "hud.enable",
                    icon: "gauge.with.dots.needle.67percent",
                    title: SakuraL10n.tr("osd.tile.hudEnabled"),
                    isOn: Binding(
                        get: { settings.hudEnabled },
                        set: { settings.hudEnabled = $0 }
                    )
                )
                CycleTile(
                    id: "hud.refresh",
                    icon: "timer",
                    title: SakuraL10n.tr("osd.tile.hudRefreshRate"),
                    options: [
                        (3,  SakuraL10n.tr("osd.hudRefresh.3")),
                        (6,  SakuraL10n.tr("osd.hudRefresh.6")),
                        (10, SakuraL10n.tr("osd.hudRefresh.10")),
                        (15, SakuraL10n.tr("osd.hudRefresh.15")),
                        (30, SakuraL10n.tr("osd.hudRefresh.30")),
                    ],
                    selection: Binding(
                        get: { settings.hudRefreshRate },
                        set: { settings.hudRefreshRate = $0 }
                    )
                )
                SettingTile(
                    id: "hud.resetPosition",
                    icon: "arrow.counterclockwise.circle",
                    title: SakuraL10n.tr("emu.menu.resetHudPosition"),
                    value: SakuraL10n.tr("common.reset"),
                    action: {
                        hudRelOffsetX = 0
                        hudRelOffsetY = 0
                    }
                )
            }
        }
    }

    private var hudMetricsSection: some View {
        SettingSection(title: SakuraL10n.tr("osd.section.visibleMetrics")) {
            TileGrid {
                ToggleTile(id: "hud.fps", icon: "gauge.with.dots.needle.67percent",
                                 title: SakuraL10n.tr("osd.tile.hudFps"),
                                 isOn: $settings.hudShowFPS)
                ToggleTile(id: "hud.speed", icon: "gauge.medium",
                                 title: SakuraL10n.tr("osd.tile.hudSpeed"),
                                 isOn: $settings.hudShowSpeed)
                ToggleTile(id: "hud.avgLow", icon: "chart.bar.xaxis",
                                 title: SakuraL10n.tr("osd.tile.hudAvgLow"),
                                 isOn: $settings.hudShowAvgLow)
                ToggleTile(id: "hud.frameTime", icon: "waveform.path",
                                 title: SakuraL10n.tr("osd.tile.hudFrameTime"),
                                 isOn: $settings.hudShowFrameTime)
                ToggleTile(id: "hud.cpu", icon: "cpu",
                                 title: SakuraL10n.tr("osd.tile.hudCpu"),
                                 isOn: $settings.hudShowCPU)
                ToggleTile(id: "hud.ram", icon: "memorychip",
                                 title: SakuraL10n.tr("osd.tile.hudRam"),
                                 isOn: $settings.hudShowRAM)
                ToggleTile(id: "hud.gpu", icon: "square.stack.3d.up",
                                 title: SakuraL10n.tr("osd.tile.hudGpu"),
                                 isOn: $settings.hudShowGPU)
                ToggleTile(id: "hud.resolution", icon: "arrow.up.left.and.arrow.down.right",
                                 title: SakuraL10n.tr("osd.tile.hudResolution"),
                                 isOn: $settings.hudShowResolution)
                ToggleTile(id: "hud.thermal", icon: "thermometer.medium",
                                 title: SakuraL10n.tr("osd.tile.hudThermal"),
                                 isOn: $settings.hudShowTemperature)
                ToggleTile(id: "hud.battery", icon: "bolt.fill",
                                 title: SakuraL10n.tr("osd.tile.hudBattery"),
                                 isOn: $settings.hudShowBattery)
                ToggleTile(id: "hud.graphs", icon: "chart.xyaxis.line",
                                 title: SakuraL10n.tr("osd.tile.hudGraphs"),
                                 isOn: $settings.hudShowGraphs)
            }
        }
    }

    private var notificationsSection: some View {
        SettingSection(title: SakuraL10n.tr("osd.section.notificationCards")) {
            TileGrid {
                ToggleTile(
                    id: "notif.enable",
                    icon: "bell.fill",
                    title: SakuraL10n.tr("osd.tile.notificationCardsEnabled"),
                    isOn: Binding<Bool>(
                        get: { notif.enabled },
                        set: { v in notif.enabled = v }
                    ),
                    showsSettingNotification: false
                )
                CycleTile(
                    id: "notif.position",
                    icon: "square.grid.2x2",
                    title: SakuraL10n.tr("osd.tile.notificationsPosition"),
                    options: [
                        ("topLeading",     SakuraL10n.tr("osd.notifPosition.topLeading")),
                        ("topTrailing",    SakuraL10n.tr("osd.notifPosition.topTrailing")),
                        ("bottomLeading",  SakuraL10n.tr("osd.notifPosition.bottomLeading")),
                        ("bottomTrailing", SakuraL10n.tr("osd.notifPosition.bottomTrailing")),
                    ],
                    selection: Binding<String>(
                        get: { notif.positionKey },
                        set: { v in notif.positionKey = v }
                    ),
                    showsSettingNotification: false
                )
                CycleTile(
                    id: "notif.max",
                    icon: "square.stack.fill",
                    title: SakuraL10n.tr("osd.tile.notificationsMaxVisible"),
                    options: [
                        (1, SakuraL10n.tr("osd.notificationsMax.one")),
                        (2, SakuraL10n.tr("osd.notificationsMax.two")),
                        (3, SakuraL10n.tr("osd.notificationsMax.three")),
                        (4, SakuraL10n.tr("osd.notificationsMax.four")),
                    ],
                    selection: Binding<Int>(
                        get: { notif.maxVisible },
                        set: { v in notif.maxVisible = v }
                    ),
                    showsSettingNotification: false
                )
                CycleTile(
                    id: "notif.duration",
                    icon: "clock",
                    title: SakuraL10n.tr("osd.tile.notificationsAutoDismiss"),
                    options: [
                        (1.5, SakuraL10n.tr("osd.notifDuration.1_5s")),
                        (3.0, SakuraL10n.tr("osd.notifDuration.3s")),
                        (5.0, SakuraL10n.tr("osd.notifDuration.5s")),
                        (10.0, SakuraL10n.tr("osd.notifDuration.10s")),
                    ],
                    selection: Binding<TimeInterval>(
                        get: { notif.defaultDuration },
                        set: { v in notif.defaultDuration = v }
                    ),
                    showsSettingNotification: false
                )
                ToggleTile(
                    id: "notif.evt.controller",
                    icon: "gamecontroller",
                    title: SakuraL10n.tr("osd.tile.notificationsEvtController"),
                    isOn: Binding<Bool>(
                        get: { notif.eventController },
                        set: { v in notif.eventController = v }
                    ),
                    showsSettingNotification: false
                )
                ToggleTile(
                    id: "notif.evt.save",
                    icon: "sdcard",
                    title: SakuraL10n.tr("osd.tile.notificationsEvtSaveState"),
                    isOn: Binding<Bool>(
                        get: { notif.eventSaveState },
                        set: { v in notif.eventSaveState = v }
                    ),
                    showsSettingNotification: false
                )
                ToggleTile(
                    id: "notif.evt.music",
                    icon: "music.note",
                    title: SakuraL10n.tr("osd.tile.notificationsEvtMusic"),
                    isOn: Binding<Bool>(
                        get: { notif.eventMusic },
                        set: { v in notif.eventMusic = v }
                    ),
                    showsSettingNotification: false
                )
                ToggleTile(
                    id: "notif.evt.import",
                    icon: "tray.and.arrow.down",
                    title: SakuraL10n.tr("osd.tile.notificationsEvtImport"),
                    isOn: Binding<Bool>(
                        get: { notif.eventImport },
                        set: { v in notif.eventImport = v }
                    ),
                    showsSettingNotification: false
                )
                ToggleTile(
                    id: "notif.evt.bios",
                    icon: "cpu",
                    title: SakuraL10n.tr("osd.tile.notificationsEvtBios"),
                    isOn: Binding<Bool>(
                        get: { notif.eventBIOS },
                        set: { v in notif.eventBIOS = v }
                    ),
                    showsSettingNotification: false
                )
                ToggleTile(
                    id: "notif.evt.settings",
                    icon: "gearshape",
                    title: SakuraL10n.tr("osd.tile.notificationsEvtSettings"),
                    isOn: Binding<Bool>(
                        get: { notif.eventSettings },
                        set: { v in notif.eventSettings = v }
                    ),
                    showsSettingNotification: false
                )
                SettingTile(
                    id: "notif.test",
                    icon: "paperplane.fill",
                    title: SakuraL10n.tr("osd.tile.notificationsTestPreview"),
                    value: SakuraL10n.tr("osd.tile.notificationsTestHint")
                ) {
                    notif.post(.info)
                }
            }
        }
    }
}
