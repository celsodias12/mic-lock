import Foundation

public struct AudioInput: Equatable, Sendable {
    public let id: UInt32
    public let uid: String
    public let name: String

    public init(id: UInt32, uid: String, name: String) {
        self.id = id
        self.uid = uid
        self.name = name
    }
}

public struct AudioSnapshot: Sendable {
    public let inputs: [AudioInput]
    public let defaultInputID: UInt32?

    public init(inputs: [AudioInput], defaultInputID: UInt32?) {
        self.inputs = inputs
        self.defaultInputID = defaultInputID
    }
}

@MainActor
public protocol AudioHardware: AnyObject {
    func snapshot() throws -> AudioSnapshot
    func setDefaultInput(id: UInt32) throws
}

public enum LockStatus: Equatable, Sendable {
    case unconfigured, paused, waiting, locked
    case error(String)

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

@MainActor
public final class MicrophoneLock {
    public private(set) var inputs: [AudioInput] = []
    public private(set) var defaultInputID: UInt32?
    public private(set) var preferredUID: String?
    public private(set) var preferredName: String?
    public private(set) var isEnabled: Bool
    public private(set) var status: LockStatus = .unconfigured
    public private(set) var retryAfter: TimeInterval?

    private let hardware: any AudioHardware
    private let defaults: UserDefaults
    private let now: () -> TimeInterval
    private var writeTimes: [TimeInterval] = []
    private var failures = 0
    private var blockedReason: String?
    private var lastPreferredObjectID: UInt32?

    public init(
        hardware: any AudioHardware,
        defaults: UserDefaults,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.hardware = hardware
        self.defaults = defaults
        self.now = now
        preferredUID = defaults.string(forKey: "preferredInputUID")
        preferredName = defaults.string(forKey: "preferredInputName")
        isEnabled = defaults.bool(forKey: "lockEnabled") && preferredUID != nil
    }

    public func select(_ input: AudioInput) {
        preferredUID = input.uid
        preferredName = input.name
        defaults.set(input.uid, forKey: "preferredInputUID")
        defaults.set(input.name, forKey: "preferredInputName")
        setEnabled(true)
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && preferredUID != nil
        defaults.set(isEnabled, forKey: "lockEnabled")
        resetRecovery()
        refresh()
    }

    public func resetRecovery() {
        writeTimes = []
        clearFailures()
    }

    private func clearFailures() {
        failures = 0
        blockedReason = nil
        retryAfter = nil
    }

    public func refresh() {
        retryAfter = nil
        do {
            let snapshot = try hardware.snapshot()
            update(snapshot)
            let preferredObjectID = inputs.first { $0.uid == preferredUID }?.id
            if preferredObjectID != lastPreferredObjectID { clearFailures() }
            lastPreferredObjectID = preferredObjectID

            guard let preferredUID else { status = .unconfigured; return }
            guard isEnabled else { status = .paused; return }
            guard let preferred = inputs.first(where: { $0.uid == preferredUID }) else {
                status = .waiting
                return
            }
            guard defaultInputID != preferred.id else {
                status = .locked
                failures = 0
                blockedReason = nil
                return
            }
            if let blockedReason { status = .error(blockedReason); return }

            let instant = now()
            writeTimes.removeAll { instant - $0 >= 10 }
            guard writeTimes.count < 5 else {
                blockedReason = "Trocas repetidas de entrada. Pause o outro app ou tente novamente."
                status = .error(blockedReason!)
                return
            }
            writeTimes.append(instant)
            try hardware.setDefaultInput(id: preferred.id)
            let confirmed = try hardware.snapshot()
            update(confirmed)
            guard confirmed.inputs.contains(where: { $0.uid == preferredUID && $0.id == confirmed.defaultInputID }) else {
                recordFailure("O macOS ainda não confirmou a entrada escolhida.")
                return
            }
            failures = 0
            status = .locked
        } catch {
            recordFailure("Não foi possível acessar o áudio: \(error.localizedDescription)")
        }
    }

    private func update(_ snapshot: AudioSnapshot) {
        inputs = snapshot.inputs
        defaultInputID = snapshot.defaultInputID
    }

    private func recordFailure(_ message: String) {
        failures += 1
        status = .error(message)
        if failures <= 3 {
            retryAfter = 0.5 * pow(2, Double(failures - 1))
        } else {
            blockedReason = message
        }
    }
}
