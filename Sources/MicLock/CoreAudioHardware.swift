import CoreAudio
import Foundation
import MicLockCore

struct AudioError: LocalizedError {
    let operation: String
    let code: OSStatus
    var errorDescription: String? { "\(operation) (CoreAudio \(code))" }
}

@MainActor
final class CoreAudioHardware: AudioHardware {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var onChange: (@MainActor (Bool) -> Void)?
    private var pendingChange: DispatchWorkItem?
    private var needsRecovery = false

    func snapshot() throws -> AudioSnapshot {
        let snapshot = try AudioInventory.snapshot(
            deviceIDs: readDeviceIDs,
            defaultInputID: {
                let current = try self.readUInt32(self.system, kAudioHardwarePropertyDefaultInputDevice)
                return current == kAudioObjectUnknown ? nil : current
            },
            readInput: readInput
        )
        let inputs = snapshot.inputs.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
        }
        return AudioSnapshot(inputs: inputs, defaultInputID: snapshot.defaultInputID)
    }

    private func readDeviceIDs() throws -> [AudioObjectID] {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "Listar entradas")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if size > 0 {
            let result = ids.withUnsafeMutableBytes {
                AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
            }
            try check(result, "Ler entradas")
        }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func readInput(_ id: AudioObjectID) throws -> AudioInput? {
        guard try hasInputChannels(id),
              try readUInt32(id, kAudioDevicePropertyDeviceIsAlive) == 1,
              try readUInt32(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeInput) == 1
        else { return nil }
        let uid = try readString(id, kAudioDevicePropertyDeviceUID)
        let name = try readString(id, kAudioObjectPropertyName)
        guard !uid.isEmpty else { throw AudioError(operation: "Ler identificador do dispositivo", code: kAudioHardwareUnspecifiedError) }
        return AudioInput(id: id, uid: uid, name: name)
    }

    func setDefaultInput(id: UInt32) throws {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var value = id
        try check(
            AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value),
            "Definir entrada padrão"
        )
    }

    func startObserving(onChange: @escaping @MainActor (Bool) -> Void) throws {
        self.onChange = onChange
        try recoverObservations()
    }

    func recoverObservations() throws {
        removeListeners()
        do {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyServiceRestarted] {
                var address = property(selector)
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.queueChange(recovery: selector == kAudioHardwarePropertyServiceRestarted)
                    }
                }
                try check(AudioObjectAddPropertyListenerBlock(system, &address, .main, listener), "Monitorar entradas")
                listeners.append((address, listener))
            }
        } catch {
            removeListeners()
            throw error
        }
    }

    func stopObserving() {
        pendingChange?.cancel()
        pendingChange = nil
        onChange = nil
        removeListeners()
    }

    private func queueChange(recovery: Bool) {
        needsRecovery = needsRecovery || recovery
        guard pendingChange == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingChange = nil
            let recovery = self.needsRecovery
            self.needsRecovery = false
            self.onChange?(recovery)
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func removeListeners() {
        for (var address, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(system, &address, .main, listener)
        }
        listeners.removeAll()
    }

    private func hasInputChannels(_ id: AudioObjectID) throws -> Bool {
        var address = property(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size), "Consultar canais")
        guard size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage), "Ler canais")
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }

    private func readUInt32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var address = property(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Consultar dispositivo")
        return value
    }

    private func readString(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = property(selector)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        try check(result, "Ler nome do dispositivo")
        return value as String
    }

    private func property(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioError(operation: operation, code: status) }
    }
}
