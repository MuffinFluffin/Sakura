// SPDX-License-Identifier: GPL-3.0+

import SwiftUI
import UIKit

struct OSDGameplayOverlay: View {
    var presentationScreen: UIScreen? = nil

    @Bindable private var model = HUDModel.shared
    @State private var theme = ThemeManager.shared
    @Bindable private var settings = SettingsStore.shared

    @AppStorage("sakura.hud.relOffsetX") private var relOffsetX: Double = 0
    @AppStorage("sakura.hud.relOffsetY") private var relOffsetY: Double = 0
    @State private var dragOffset: CGSize = .zero

    private var displayCapFPS: Double {
        Double((presentationScreen ?? UIScreen.main).maximumFramesPerSecond)
    }

    var body: some View {
        hudContent
            .fixedSize(horizontal: true, vertical: true)
            .scaleEffect(CGFloat(theme.hudScale), anchor: .topTrailing)
            .offset(x: CGFloat(relOffsetX) + dragOffset.width,
                    y: CGFloat(relOffsetY) + dragOffset.height)
            .gesture(
                DragGesture()
                    .onChanged { v in dragOffset = v.translation }
                    .onEnded { v in
                        relOffsetX += Double(v.translation.width)
                        relOffsetY += Double(v.translation.height)
                        dragOffset = .zero
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    relOffsetX = 0
                    relOffsetY = 0
                    dragOffset = .zero
                }
            )
            .accessibilityHint(SakuraL10n.tr("help.faq.3.1.a"))
    }

    private func resolutionHUDText(_ t: HUDTelemetry) -> String {
        let pw = UInt32(SakuraBridge.psPresentWidth())
        let ph = UInt32(SakuraBridge.psPresentHeight())
        if pw > 0 && ph > 0 {
            return "\(pw)×\(ph)"
        }
        if t.internalWidth == 0 || t.internalHeight == 0 { return "—" }
        let u = Double(t.upscale)
        let hundred = Int((u * 100.0).rounded())
        let upStr = hundred % 100 == 0 ? "\(hundred / 100)x" : String(format: "%.2gx", u)
        return "\(t.internalWidth)×\(t.internalHeight) \(upStr)"
    }

    private func fpsGraphVerticalCap(_ t: HUDTelemetry) -> Double {
        let peak = max(t.vps, t.gpuPresentFPS, t.neuralOutputFPS, t.avgFps)
        let cap = displayCapFPS
        return max(60.0, cap, ceil(peak / 30.0) * 30.0)
    }

    @ViewBuilder
    private var hudContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            if settings.hudShowFPS {
                let emu = model.telemetry.vps
                let layerHz = model.telemetry.gpuPresentFPS > 0 ? model.telemetry.gpuPresentFPS : model.telemetry.fps
                let neuralHz = model.telemetry.neuralOutputFPS
                let neuralLive = settings.neuralUpscaleLive
                let cap = displayCapFPS
                HStack(spacing: 4) {
                    Text(neuralLive ? "EMU/LAY/NUR" : "EMU/LAY")
                        .font(.system(size: 9, weight: .bold, design: theme.hudFontDesign()))
                        .foregroundStyle(theme.hudLabelColor().opacity(0.75))
                        .frame(width: neuralLive ? 72 : 44, alignment: .leading)
                    Text(String(format: "%.0f", emu))
                        .font(.system(size: 10, weight: .semibold, design: theme.hudFontDesign()))
                        .foregroundStyle(HUDModel.fpsColor(emu))
                        .monospacedDigit()
                    Text("/")
                        .font(.system(size: 10, weight: .semibold, design: theme.hudFontDesign()))
                        .foregroundStyle(theme.hudLabelColor().opacity(0.55))
                    Text(String(format: "%.0f", layerHz))
                        .font(.system(size: 10, weight: .semibold, design: theme.hudFontDesign()))
                        .foregroundStyle(HUDModel.layerPresentColor(layerHz, displayCap: cap))
                        .monospacedDigit()
                    if neuralLive {
                        Text("/")
                            .font(.system(size: 10, weight: .semibold, design: theme.hudFontDesign()))
                            .foregroundStyle(theme.hudLabelColor().opacity(0.55))
                        Text(String(format: "%.0f", neuralHz))
                            .font(.system(size: 10, weight: .semibold, design: theme.hudFontDesign()))
                            .foregroundStyle(HUDModel.layerPresentColor(neuralHz, displayCap: cap))
                            .monospacedDigit()
                    }
                }
            }
            if settings.hudShowAvgLow {
                line("AVG", String(format: "%.0f", model.telemetry.avgFps))
                line("1%L", String(format: "%.0f", model.telemetry.low1Fps),
                     color: HUDModel.fpsColor(model.telemetry.low1Fps))
            }
            if settings.hudShowSpeed {
                line("SPD", String(format: "%.0f%%", model.telemetry.speed * 100))
            }
            if settings.hudShowCPU {
                line("CPU", String(format: "%.0f%%", model.telemetry.cpuUsageApp),
                     color: HUDModel.cpuColor(model.telemetry.cpuUsageApp))
            }
            if settings.hudShowResolution {
                line("RES", resolutionHUDText(model.telemetry))
            }
            if settings.hudShowFrameTime {
                line("FT", String(format: "%.1fms", model.telemetry.frameTimeMs))
            }
            if settings.hudShowRAM {
                line("RAM", String(format: "%.0fM", model.telemetry.ramUsedMB))
            }
            if settings.hudShowGPU {
                line("GPU", String(format: "%.0fM", model.telemetry.gpuAllocatedMB))
            }
            if settings.hudShowTemperature {
                line("TMP", model.thermalStateString, color: model.thermalColor)
            }
            if settings.hudShowBattery {
                line("BAT", model.batteryPercentText)
            }
            if settings.hudShowGraphs {
                VStack(spacing: 1) {
                    miniGraph(values: model.telemetry.fpsHistory, maxValue: fpsGraphVerticalCap(model.telemetry))
                    miniGraph(values: model.telemetry.cpuHistory, maxValue: 100)
                }
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(surface)
        .overlay(border)
    }

    private func miniGraph(values: [Double], maxValue: Double) -> some View {
        OSDSparklineGraph(
            values: values,
            color: theme.hudGraphColor(),
            lineWidth: max(0.7, CGFloat(theme.hudGraphLineWidth) * 0.75),
            maxValue: maxValue
        )
        .frame(width: 72, height: 8)
    }


    private func line(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: theme.hudFontDesign()))
                .foregroundStyle(theme.hudLabelColor().opacity(0.75))
                .frame(width: label.count > 5 ? 38 : 26, alignment: .leading)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: theme.hudFontDesign()))
                .foregroundStyle(color ?? theme.hudValueColor())
                .lineLimit(1)
                .monospacedDigit()
        }
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: CGFloat(theme.hudCornerRadius), style: .continuous)
            .fill(theme.hudTileColor().opacity(theme.hudOpacity))
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: CGFloat(theme.hudCornerRadius), style: .continuous)
            .stroke(theme.hudStrokeColor().opacity(0.2), lineWidth: 0.5)
    }
}
