// SPDX-License-Identifier: GPL-3.0+

import Foundation
import GameController

extension Notification.Name {
    static let sakuraControllerPortAssignmentsChanged = Notification.Name("SakuraControllerPortAssignmentsChanged")
}

final class ControllerPortAssigner: ObservableObject, @unchecked Sendable {
    static let shared = ControllerPortAssigner()

    @Published private(set) var liveByPort: [GCController?] = [nil, nil]
    
    private var persisted: [String: Int] = [:]
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        
        loadPersisted()

        let nc = NotificationCenter.default
        nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let c = note.object as? GCController else { return }
            self.onConnect(c)
        }
        nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let c = note.object as? GCController else { return }
            self.onDisconnect(c)
        }

        for c in GCController.controllers() {
            onConnect(c)
        }
    }
    
    func identity(for c: GCController) -> String {
        let cat = c.productCategory
        if let v = c.vendorName { return "\(v)|\(cat)" }
        let cls = NSStringFromClass(type(of: c) as AnyClass)
        return "generic|\(cat)|\(cls)"
    }
    
    func port(for c: GCController) -> Int? {
        let p = SakuraGamepadIOS_PortForController(Unmanaged.passUnretained(c).toOpaque())
        return (p >= 0 && p <= 1) ? Int(p) : nil
    }
    
    func reassign(controller c: GCController, to newPort: Int) {
        guard newPort == 0 || newPort == 1 else { return }
        if isVirtual(c) { return }
        
        let oldPort = port(for: c)
        if oldPort == newPort { return }
        
        let id = identity(for: c)
        
        if let occupant = liveByPort[newPort], occupant !== c {
            let occupantId = identity(for: occupant)
            if let oldPort {
                // Swap
                liveByPort[oldPort] = occupant
                SakuraGamepadIOS_SetControllerPort(Unmanaged.passUnretained(occupant).toOpaque(), Int32(oldPort))
                persisted[occupantId] = oldPort
            } else {
                // Kick out to unassigned
                SakuraGamepadIOS_ClearController(Unmanaged.passUnretained(occupant).toOpaque())
                persisted.removeValue(forKey: occupantId)
            }
        }
        
        if let oldPort, liveByPort[oldPort] === c {
            liveByPort[oldPort] = nil
        }
        
        liveByPort[newPort] = c
        SakuraGamepadIOS_SetControllerPort(Unmanaged.passUnretained(c).toOpaque(), Int32(newPort))
        persisted[id] = newPort
        savePersisted()
        
        NotificationCenter.default.post(name: .sakuraControllerPortAssignmentsChanged, object: nil)
    }
    
    func forget(identity id: String) {
        persisted.removeValue(forKey: id)
        savePersisted()
        NotificationCenter.default.post(name: .sakuraControllerPortAssignmentsChanged, object: nil)
    }

    func clear(port: Int) {
        guard port == 0 || port == 1 else { return }
        guard let c = liveByPort[port] else { return }
        persisted.removeValue(forKey: identity(for: c))
        liveByPort[port] = nil
        SakuraGamepadIOS_ClearController(Unmanaged.passUnretained(c).toOpaque())
        savePersisted()
        NotificationCenter.default.post(name: .sakuraControllerPortAssignmentsChanged, object: nil)
    }

    func connectedPhysicalControllers() -> [GCController] {
        var out: [GCController] = []
        var seen = Set<ObjectIdentifier>()
        for c in liveByPort.compactMap({ $0 }) + GCController.controllers() {
            if isVirtual(c) { continue }
            let oid = ObjectIdentifier(c)
            if seen.contains(oid) { continue }
            seen.insert(oid)
            out.append(c)
        }
        return out
    }
    
    private func onConnect(_ c: GCController) {
        if isVirtual(c) { return }
        if port(for: c) != nil { return } // Already tracked
        
        let id = identity(for: c)
        let pref = persisted[id]
        
        var chosen: Int? = nil
        if let pref, pref >= 0, pref <= 1, liveByPort[pref] == nil {
            chosen = pref
        } else if liveByPort[0] == nil {
            chosen = 0
        } else if liveByPort[1] == nil {
            chosen = 1
        }
        
        if let chosen {
            liveByPort[chosen] = c
            SakuraGamepadIOS_SetControllerPort(Unmanaged.passUnretained(c).toOpaque(), Int32(chosen))
            persisted[id] = chosen
            savePersisted()
            NotificationCenter.default.post(name: .sakuraControllerPortAssignmentsChanged, object: nil)
        } else {
            print("ControllerPortAssigner: 2 ports already occupied, ignoring third pad (\(id))")
        }
    }
    
    private func onDisconnect(_ c: GCController) {
        if isVirtual(c) { return }
        var changed = false
        for p in 0...1 {
            if liveByPort[p] === c {
                liveByPort[p] = nil
                changed = true
            }
        }
        SakuraGamepadIOS_ClearController(Unmanaged.passUnretained(c).toOpaque())
        if changed {
            NotificationCenter.default.post(name: .sakuraControllerPortAssignmentsChanged, object: nil)
        }
    }
    
    private func isVirtual(_ c: GCController) -> Bool {
        return NSStringFromClass(type(of: c) as AnyClass).contains("GCVirtualController")
    }
    
    private func loadPersisted() {
        let raw = SettingsStore.shared.controllerPortAssignmentsRaw
        if let data = raw.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            persisted = dict
        }
    }
    
    private func savePersisted() {
        if let data = try? JSONEncoder().encode(persisted),
           let str = String(data: data, encoding: .utf8) {
            SettingsStore.shared.controllerPortAssignmentsRaw = str
        }
    }
}
