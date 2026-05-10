// SPDX-License-Identifier: GPL-3.0+

import Foundation
import QuartzCore
import SwiftUI
import UIKit
import Metal
import Observation

struct HUDTelemetry: Equatable {
    var fps: Double = 0
    var gpuPresentFPS: Double = 0
    var neuralOutputFPS: Double = 0
    var vps: Double = 0
    var speed: Double = 0
    var avgFps: Double = 0
    var low1Fps: Double = 0
    var frameTimeMs: Double = 0

    var internalWidth: UInt32 = 0
    var internalHeight: UInt32 = 0
    var upscale: Float = 1
    var cpuUsageApp: Double = 0
    var ramUsedMB: Double = 0
    var ramAvailableMB: Double = 0
    var ramTotalMB: Double = 0
    var gpuAllocatedMB: Double = 0
    var gpuMaxBudgetMB: Double = 0
    var thermalState: ProcessInfo.ThermalState = .nominal
    var batteryLevel: Float = -1
    var batteryState: UIDevice.BatteryState = .unknown

    var fpsHistory: [Double] = []
    var cpuHistory: [Double] = []
}

@Observable
@MainActor
final class HUDModel {
    static let shared = HUDModel()

    private(set) var telemetry = HUDTelemetry()

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastHostSample: CFAbsoluteTime = 0
    @ObservationIgnored private var lastMetalPresentCount: UInt64 = 0
    @ObservationIgnored private var lastMetalPresentTime: CFAbsoluteTime = 0
    @ObservationIgnored private var lastNeuralCommitCount: UInt64 = 0
    @ObservationIgnored private var lastNeuralCommitTime: CFAbsoluteTime = 0
    @ObservationIgnored private let hostInterval: TimeInterval = 0.5
    @ObservationIgnored private var notifObservers: [NSObjectProtocol] = []

    var refreshRate: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "sakura.hud.refreshRate")
            return v > 0 ? v : 6
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "sakura.hud.refreshRate")
            if timer != nil { startTimer() }
        }
    }

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        var t = telemetry
        t.thermalState = ProcessInfo.processInfo.thermalState
        t.batteryLevel = UIDevice.current.batteryLevel
        t.batteryState = UIDevice.current.batteryState
        telemetry = t

        let c = NotificationCenter.default
        notifObservers.append(c.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var t = self.telemetry
                t.thermalState = ProcessInfo.processInfo.thermalState
                self.telemetry = t
            }
        })
        notifObservers.append(c.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var t = self.telemetry
                t.batteryLevel = UIDevice.current.batteryLevel
                self.telemetry = t
            }
        })
        notifObservers.append(c.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var t = self.telemetry
                t.batteryState = UIDevice.current.batteryState
                self.telemetry = t
            }
        })
    }

    // MARK: - Lifecycle

    func start() {
        startTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = 1.0 / Double(max(1, refreshRate))
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Refresh

    private func refresh() {
        var t = telemetry

        t.vps = SakuraBridge.perfVPS()

        let presentCount = UInt64(SakuraBridge.perfMetalLayerPresentCount())
        let monoNow = CACurrentMediaTime()
        var sampledLayerPresent = false
        if SakuraBridge.isRunning() {
            if lastMetalPresentTime > 0 {
                let dt = monoNow - lastMetalPresentTime
                if dt > 0.0005 {
                    let delta = presentCount &- lastMetalPresentCount
                    t.gpuPresentFPS = Double(delta) / dt
                    sampledLayerPresent = true
                }
            }
            lastMetalPresentTime = monoNow
            lastMetalPresentCount = presentCount

            let neuralCount = UInt64(SakuraBridge.perfNeuralCommitCount())
            if lastNeuralCommitTime > 0 {
                let ndt = monoNow - lastNeuralCommitTime
                if ndt > 0.0005 {
                    let nd = neuralCount &- lastNeuralCommitCount
                    t.neuralOutputFPS = Double(nd) / ndt
                }
            }
            lastNeuralCommitTime = monoNow
            lastNeuralCommitCount = neuralCount
        } else {
            t.gpuPresentFPS = 0
            t.neuralOutputFPS = 0
            lastMetalPresentTime = 0
            lastMetalPresentCount = 0
            lastNeuralCommitTime = 0
            lastNeuralCommitCount = 0
        }

        t.speed = SakuraBridge.perfSpeed()
        t.internalWidth = UInt32(SakuraBridge.psBaseWidth())
        t.internalHeight = UInt32(SakuraBridge.psBaseHeight())
        t.upscale = SettingsStore.shared.upscaleMultiplier

        let emuFps = t.vps
        let outputFps = (sampledLayerPresent || t.gpuPresentFPS > 0) ? t.gpuPresentFPS : emuFps
        t.fps = outputFps
        t.frameTimeMs = outputFps > 0 ? 1000.0 / outputFps : 0

        let now = CFAbsoluteTimeGetCurrent()
        if lastHostSample == 0 || (now - lastHostSample) >= hostInterval {
            lastHostSample = now
            t.cpuUsageApp = Self.appCPUUsage()
            t.ramUsedMB = Self.appMemoryFootprint()
            t.ramAvailableMB = Self.availableMemoryMB()
            t.ramTotalMB = Self.totalPhysicalMemoryMB()
            let (alloc, budget) = Self.gpuMemoryMB()
            t.gpuAllocatedMB = alloc
            t.gpuMaxBudgetMB = budget
        }

        push(&t.fpsHistory, outputFps)
        push(&t.cpuHistory, t.cpuUsageApp)

        if !t.fpsHistory.isEmpty {
            t.avgFps = t.fpsHistory.reduce(0, +) / Double(t.fpsHistory.count)
            let sorted = t.fpsHistory.sorted()
            let idx = max(0, Int(Double(sorted.count) * 0.01))
            t.low1Fps = sorted[idx]
        }

        telemetry = t
    }

    private func push(_ arr: inout [Double], _ value: Double, cap: Int = 48) {
        arr.append(value)
        if arr.count > cap {
            arr.removeFirst(arr.count - cap)
        }
    }

    // MARK: - Mach task CPU

    static func appCPUUsage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else { return 0 }

        var total: Double = 0
        let infoCount = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = infoCount
            let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &count)
                }
            }
            if kr == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / 1000.0 * 100.0
            }
        }
        let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), size)
        let cores = max(1, ProcessInfo.processInfo.processorCount)
        return min(100.0, total / Double(cores))
    }

    static func appMemoryFootprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        if kr == KERN_SUCCESS {
            return Double(info.phys_footprint) / (1024 * 1024)
        }
        return 0
    }

    static func availableMemoryMB() -> Double {
        Double(os_proc_available_memory()) / (1024 * 1024)
    }

    static func totalPhysicalMemoryMB() -> Double {
        Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024)
    }

    private static let sharedMetalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    static func gpuMemoryMB() -> (alloc: Double, budget: Double) {
        guard let dev = sharedMetalDevice else { return (0, 0) }
        let alloc = Double(dev.currentAllocatedSize) / (1024 * 1024)
        var budget: Double = 0
        if #available(iOS 16.0, *) {
            budget = Double(dev.recommendedMaxWorkingSetSize) / (1024 * 1024)
        }
        return (alloc, budget)
    }

    // MARK: - Display helpers

    var thermalStateString: String {
        switch telemetry.thermalState {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "?"
        }
    }

    var thermalColor: Color {
        switch telemetry.thermalState {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }

    var batteryPercentText: String {
        guard telemetry.batteryLevel >= 0 else { return "—" }
        return "\(Int(telemetry.batteryLevel * 100))%"
    }

    static func fpsColor(_ fps: Double) -> Color {
        if fps >= 58 { return .green }
        if fps >= 30 { return .yellow }
        return .red
    }

    static func layerPresentColor(_ hz: Double, displayCap: Double) -> Color {
        if displayCap <= 62 {
            return fpsColor(hz)
        }
        if hz >= displayCap * 0.88 { return .green }
        if hz >= displayCap * 0.55 { return .yellow }
        return .orange
    }

    static func cpuColor(_ cpu: Double) -> Color {
        if cpu < 70 { return .green }
        if cpu < 90 { return .yellow }
        return .red
    }
}
