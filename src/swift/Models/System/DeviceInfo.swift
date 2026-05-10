// DeviceInfo.swift: device hardware info for onboarding and About.
// SPDX-License-Identifier: GPL-3.0+

import Darwin
import Metal
#if canImport(MetalFX)
import MetalFX
#endif
import UIKit

enum DeviceInfo {

    // MARK: - Model

    private static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    /// Hardware identifier e.g. "iPhone14,3".
    /// Uses `Darwin.uname` (not `sysctlbyname("hw.machine", …)`).
    static var machineID: String {
        var sys = utsname()
        guard uname(&sys) == 0 else { return "" }
        let machineCap = MemoryLayout.size(ofValue: sys.machine)
        return withUnsafeMutablePointer(to: &sys.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: machineCap) {
                String(validatingCString: $0) ?? ""
            }
        }
    }

    /// Marketing name (e.g. "iPhone 13 Pro Max") from a built-in lookup,
    /// falling back to the hw identifier if unmapped.
    static var modelName: String {
        let id = machineID
        return modelMap[id] ?? id
    }

    // MARK: - RAM

    /// Total physical RAM in bytes.
    static var totalRAMBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Human-readable string like "6 GB RAM".
    static var totalRAMString: String {
        let gb = Double(totalRAMBytes) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.0f GB RAM", gb)
        }
        let mb = Double(totalRAMBytes) / (1024 * 1024)
        return String(format: "%.0f MB RAM", mb)
    }

    /// Approximate usable RAM cap (iOS gives ~75% of physical or 6 GB max).
    static var usableRAMMB: Int {
        let totalMB = Int(totalRAMBytes / (1024 * 1024))
        return min(totalMB * 3 / 4, 6144)
    }

    // MARK: - Storage

    static var totalStorageGB: String {
        let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        if let total = attrs?[.systemSize] as? Int64 {
            return String(format: "%.0f GB", Double(total) / 1_000_000_000)
        }
        return "?"
    }

    static var availableStorageGB: String {
        let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: NSHomeDirectory()
        )
        if let free = attrs?[.systemFreeSize] as? Int64 {
            return String(format: "%.1f GB", Double(free) / 1_000_000_000)
        }
        return "?"
    }

    // MARK: - iOS

    @MainActor
    static var iosVersion: String {
        UIDevice.current.systemVersion
    }

    // MARK: - CPU / GPU (Metal)

    // vendor-reported Metal GPU label. usually includes SoC naming on Apple GPUs.
    static var gpuName: String {
        guard let name = metalDevice?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "—"
        }
        return name
    }

    private static func metalSoCADisplayLabel() -> String? {
        guard let raw = metalDevice?.name.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if raw == "Apple GPU" { return nil }
        if raw.hasSuffix(" GPU") { return String(raw.dropLast(" GPU".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        return raw
    }

    // best-effort SoC label. prefers MTLDevice.name minus a trailing " GPU", falls back to an hw.machine-keyed guess.
    static var cpuName: String {
        if let soc = metalSoCADisplayLabel() { return soc }
        let id = machineID
        guard !id.isEmpty else { return "—" }
        return fallbackSoCMarketingFromMachine(id)
    }

    private static func fallbackSoCMarketingFromMachine(_ id: String) -> String {
        if id.hasPrefix("iPhone10") { return "A11 Bionic" }
        if id.hasPrefix("iPhone11") { return "A12 Bionic" }
        if id.hasPrefix("iPhone12") { return "A13 Bionic" }
        if id.hasPrefix("iPhone13") { return "A14 Bionic" }
        if id.hasPrefix("iPhone14") { return "A15 Bionic" }
        if id.hasPrefix("iPhone15") { return "A16 Bionic" }
        if id.hasPrefix("iPhone16") { return "A17 Pro" }
        if id.hasPrefix("iPhone17") { return "A18 / A18 Pro" }
        if id.hasPrefix("iPhone18") { return "A19 Pro" }

        if id == "iPad11,6" || id == "iPad11,7" { return "A12 Bionic" }
        if id.hasPrefix("iPad12") { return "A13 Bionic" }
        if id == "iPad13,18" || id == "iPad13,19" { return "A14 Bionic" }
        if id == "iPad15,7" || id == "iPad15,8" { return "A16 Bionic" }

        if id == "iPad13,1" || id == "iPad13,2" { return "A14 Bionic" }
        if id == "iPad13,16" || id == "iPad13,17" { return "M1" }
        if id == "iPad14,8" || id == "iPad14,9" || id == "iPad14,10" || id == "iPad14,11" { return "M2" }
        if id == "iPad15,3" || id == "iPad15,4" || id == "iPad15,5" || id == "iPad15,6" { return "M3" }

        if id == "iPad14,1" || id == "iPad14,2" { return "A15 Bionic" }

        if id == "iPad13,4" || id == "iPad13,5" || id == "iPad13,6" || id == "iPad13,7"
            || id == "iPad13,8" || id == "iPad13,9" || id == "iPad13,10" || id == "iPad13,11" { return "M1" }
        if id == "iPad14,3" || id == "iPad14,4" || id == "iPad14,5" || id == "iPad14,6" { return "M2" }
        if id.hasPrefix("iPad16") { return "M4" }

        return "Apple (\(id))"
    }

    // MARK: - Performance tier

    enum PerformanceTier: String {
        case good
        case fair
        case poor
    }

    private static var iphoneHardwareMajor: Int? {
        let id = machineID
        guard id.hasPrefix("iPhone") else { return nil }
        let tail = id.dropFirst(6)
        return tail.split(separator: ",").first.flatMap { Int($0) }
    }

    static var performanceTier: PerformanceTier {
        guard let m = iphoneHardwareMajor else { return .good }
        if m < 13 {
            if m <= 10 { return .poor }
            return .fair
        }
        return .good
    }

    static var isOlderHardware: Bool {
        performanceTier != .good
    }

    // MARK: - Capabilities

    /// One row in the onboarding "Device Capabilities" card.
    struct Capability: Identifiable, Hashable {
        let id: String
        /// Localized title (e.g. "MetalFX Frame Interpolation").
        let title: String
        /// Localized one-line requirement summary (always shown beneath title).
        let requirement: String
        /// Whether this device + iOS version supports the capability.
        let supported: Bool
    }

    /// True when running on iOS 26 or newer, used as a coarse gate for some features.
    @MainActor
    static var isIOS26OrLater: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// MetalFX spatial scaler (used by MetalFX texture upscaler & non-temporal display path).
    /// Available on iOS 16+ on all Apple GPU families currently shipping; we still confirm via runtime check.
    static var supportsMetalFXSpatial: Bool {
        guard let dev = metalDevice else { return false }
        if #available(iOS 16.0, *) {
            return MTLFXSpatialScalerDescriptor.supportsDevice(dev)
        }
        return false
    }

    /// MetalFX temporal scaler (used by the "MetalFX Temporal Display" toggle).
    /// Requires Apple7 GPU family (A14 / M1) or later.
    static var supportsMetalFXTemporal: Bool {
        guard let dev = metalDevice else { return false }
        if #available(iOS 16.0, *) {
            return MTLFXTemporalScalerDescriptor.supportsDevice(dev)
        }
        return false
    }

    /// MetalFX frame interpolation (used by the "MetalFX Frame Interpolation" toggle).
    /// Requires iOS 26 + an Apple GPU family that supports the new MetalFX frame interpolator.
    static var supportsMetalFXFrameInterpolation: Bool {
        guard let dev = metalDevice else { return false }
        if #available(iOS 26.0, *) {
            return MTLFXFrameInterpolatorDescriptor.supportsDevice(dev)
        }
        return false
    }

    /// VideoToolbox iOS 26 frame features (graphics setting). Pure OS-version gate.
    @MainActor
    static var supportsVideoToolboxIOS26FrameFeatures: Bool {
        isIOS26OrLater
    }

    /// Core ML neural upscaler. Available on every device shipping iOS 17+, but the Neural Engine
    /// is what makes it usable in real-time. We treat it as supported wherever Metal exists.
    static var supportsNeuralUpscaler: Bool {
        metalDevice != nil
    }


    /// Ordered list of advanced graphics capabilities for the onboarding device page.
    @MainActor
    static var advancedGraphicsCapabilities: [Capability] {
        [
            Capability(
                id: "metalFXSpatial",
                title: SakuraL10n.tr("onboarding.capability.metalFXSpatial.title"),
                requirement: SakuraL10n.tr("onboarding.capability.metalFXSpatial.req"),
                supported: supportsMetalFXSpatial
            ),
            Capability(
                id: "metalFXTemporal",
                title: SakuraL10n.tr("onboarding.capability.metalFXTemporal.title"),
                requirement: SakuraL10n.tr("onboarding.capability.metalFXTemporal.req"),
                supported: supportsMetalFXTemporal
            ),
            Capability(
                id: "metalFXFrameInterp",
                title: SakuraL10n.tr("onboarding.capability.metalFXFrameInterp.title"),
                requirement: SakuraL10n.tr("onboarding.capability.metalFXFrameInterp.req"),
                supported: supportsMetalFXFrameInterpolation
            ),
            Capability(
                id: "videotoolboxIOS26",
                title: SakuraL10n.tr("onboarding.capability.videotoolboxIOS26.title"),
                requirement: SakuraL10n.tr("onboarding.capability.videotoolboxIOS26.req"),
                supported: supportsVideoToolboxIOS26FrameFeatures
            ),
            Capability(
                id: "neuralUpscale",
                title: SakuraL10n.tr("onboarding.capability.neuralUpscale.title"),
                requirement: SakuraL10n.tr("onboarding.capability.neuralUpscale.req"),
                supported: supportsNeuralUpscaler
            ),
        ]
    }

    // MARK: - Model lookup

    private static let modelMap: [String: String] = [
        // ── iPhone ──────────────────────────────────────────────────────
        "iPhone10,1": "iPhone 8",           "iPhone10,4": "iPhone 8",
        "iPhone10,2": "iPhone 8 Plus",      "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X",           "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS",
        "iPhone11,4": "iPhone XS Max",      "iPhone11,6": "iPhone XS Max",
        "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11",          "iPhone12,3": "iPhone 11 Pro",
        "iPhone12,5": "iPhone 11 Pro Max",  "iPhone12,8": "iPhone SE (2nd gen)",
        "iPhone13,1": "iPhone 12 mini",     "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro",      "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini",     "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro",      "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd gen)",
        "iPhone14,7": "iPhone 14",          "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro",      "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15",          "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro",      "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,1": "iPhone 16 Pro",      "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",          "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        // iPhone 17 / Air series, future-proof
        "iPhone18,1": "iPhone 17 Pro",      "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",          "iPhone18,4": "iPhone 17 Air",

        // ── iPad ────────────────────────────────────────────────────────
        // iPad (8th gen), A12
        "iPad11,6": "iPad (8th gen)",       "iPad11,7": "iPad (8th gen)",
        // iPad (9th gen), A13
        "iPad12,1": "iPad (9th gen)",       "iPad12,2": "iPad (9th gen)",
        // iPad (10th gen), A14
        "iPad13,18": "iPad (10th gen)",     "iPad13,19": "iPad (10th gen)",
        // iPad (A16)
        "iPad15,7": "iPad (A16)",           "iPad15,8": "iPad (A16)",

        // ── iPad Air ────────────────────────────────────────────────────
        // iPad Air (3rd gen), A12
        "iPad11,3": "iPad Air (3rd gen)",   "iPad11,4": "iPad Air (3rd gen)",
        // iPad Air (4th gen), A14
        "iPad13,1": "iPad Air (4th gen)",   "iPad13,2": "iPad Air (4th gen)",
        // iPad Air (5th gen), M1
        "iPad13,16": "iPad Air (5th gen)",  "iPad13,17": "iPad Air (5th gen)",
        // iPad Air 11\" (M2)
        "iPad14,8": "iPad Air 11\" (M2)",   "iPad14,9": "iPad Air 11\" (M2)",
        // iPad Air 13\" (M2)
        "iPad14,10": "iPad Air 13\" (M2)",  "iPad14,11": "iPad Air 13\" (M2)",
        // iPad Air 11\" (M3)
        "iPad15,3": "iPad Air 11\" (M3)",   "iPad15,4": "iPad Air 11\" (M3)",
        // iPad Air 13\" (M3)
        "iPad15,5": "iPad Air 13\" (M3)",   "iPad15,6": "iPad Air 13\" (M3)",

        // ── iPad mini ───────────────────────────────────────────────────
        // iPad mini (5th gen), A12
        "iPad11,1": "iPad mini (5th gen)",  "iPad11,2": "iPad mini (5th gen)",
        // iPad mini (6th gen), A15
        "iPad14,1": "iPad mini (6th gen)",  "iPad14,2": "iPad mini (6th gen)",

        // ── iPad Pro ────────────────────────────────────────────────────
        // iPad Pro 11\" (3rd gen), M1
        "iPad13,4": "iPad Pro 11\" (M1)",   "iPad13,5": "iPad Pro 11\" (M1)",
        "iPad13,6": "iPad Pro 11\" (M1)",   "iPad13,7": "iPad Pro 11\" (M1)",
        // iPad Pro 12.9\" (5th gen), M1
        "iPad13,8": "iPad Pro 12.9\" (M1)", "iPad13,9": "iPad Pro 12.9\" (M1)",
        "iPad13,10": "iPad Pro 12.9\" (M1)","iPad13,11": "iPad Pro 12.9\" (M1)",
        // iPad Pro 11\" (4th gen), M2
        "iPad14,3": "iPad Pro 11\" (M2)",   "iPad14,4": "iPad Pro 11\" (M2)",
        // iPad Pro 12.9\" (6th gen), M2
        "iPad14,5": "iPad Pro 12.9\" (M2)", "iPad14,6": "iPad Pro 12.9\" (M2)",
        // iPad Pro M4 11\" / 13\"
        "iPad16,3": "iPad Pro 11\" (M4)",   "iPad16,4": "iPad Pro 11\" (M4)",
        "iPad16,5": "iPad Pro 13\" (M4)",   "iPad16,6": "iPad Pro 13\" (M4)",
    ]
}
