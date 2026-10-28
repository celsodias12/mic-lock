import Foundation
import Testing
@testable import MicLockCore

@MainActor
private final class HardwareFixture: AudioHardware {
    let wave = AudioInput(id: 10, uid: "wave-3", name: "Elgato Wave:3")
    let builtin = AudioInput(id: 20, uid: "builtin", name: "Microfone do Mac")
    var inputs: [AudioInput]
    var currentID: UInt32? = 20
    var writes: [UInt32] = []
    var readFails = false
    var writeFails = false
    var writeHasEffect = true

    init() { inputs = [wave, builtin] }

    func snapshot() throws -> AudioSnapshot {
        if readFails { throw FixtureError.unavailable }
        return AudioSnapshot(inputs: inputs, defaultInputID: currentID)
    }

    func setDefaultInput(id: UInt32) throws {
        writes.append(id)
        if writeFails { throw FixtureError.unavailable }
        if writeHasEffect { currentID = id }
    }
}

private enum FixtureError: Error { case unavailable }

@MainActor
private func settings() -> UserDefaults {
    UserDefaults(suiteName: "app.miclock.tests.\(UUID().uuidString)")!
}

@Suite @MainActor
struct MicrophoneLockTests {
    @Test func firstLaunchDoesNotChangeInput() {
        let hardware = HardwareFixture()
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.refresh()
        #expect(hardware.writes.isEmpty)
        #expect(lock.status == .unconfigured)
        #expect(!lock.isEnabled)
    }

    @Test func selectionRestoresAndRemembersPreferredInput() {
        let hardware = HardwareFixture()
        let defaults = settings()
        let lock = MicrophoneLock(hardware: hardware, defaults: defaults)
        lock.select(hardware.wave)
        #expect(hardware.currentID == 10)
        #expect(lock.status == .locked)
        #expect(lock.preferredUID == "wave-3")
        let reopened = MicrophoneLock(hardware: hardware, defaults: defaults)
        reopened.refresh()
        #expect(reopened.preferredUID == "wave-3")
        #expect(reopened.isEnabled)
        #expect(reopened.status == .locked)
        #expect(hardware.writes == [10])
    }

    @Test func outsideChangeIsCorrectedWithoutRewritingAlreadyCorrectInput() {
        let hardware = HardwareFixture()
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(hardware.wave)
        lock.refresh()
        hardware.currentID = 20
        lock.refresh()
        #expect(hardware.writes == [10, 10])
        #expect(lock.status == .locked)
    }

    @Test func pauseAllowsOtherInputsAndPersistsAcrossLaunches() {
        let hardware = HardwareFixture()
        let defaults = settings()
        let lock = MicrophoneLock(hardware: hardware, defaults: defaults)
        lock.select(hardware.wave)
        lock.setEnabled(false)
        hardware.currentID = 20
        lock.refresh()
        #expect(hardware.writes == [10])
        #expect(lock.status == .paused)
        let reopened = MicrophoneLock(hardware: hardware, defaults: defaults)
        reopened.refresh()
        #expect(reopened.status == .paused)
        #expect(reopened.preferredUID == "wave-3")
        reopened.setEnabled(true)
        #expect(hardware.writes == [10, 10])
        #expect(reopened.status == .locked)
    }

    @Test func disconnectedDeviceIsRememberedAndReconnectionUsesNewObjectID() {
        let hardware = HardwareFixture()
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(hardware.wave)
        hardware.inputs = [hardware.builtin]
        hardware.currentID = 20
        lock.refresh()
        #expect(lock.status == .waiting)
        #expect(lock.preferredName == "Elgato Wave:3")
        #expect(hardware.writes == [10])
        hardware.inputs.append(AudioInput(id: 99, uid: "wave-3", name: "Elgato Wave:3"))
        lock.refresh()
        #expect(hardware.currentID == 99)
        #expect(lock.status == .locked)
    }

    @Test func identicalNamesDoNotSelectWrongDevice() {
        let hardware = HardwareFixture()
        let other = AudioInput(id: 30, uid: "another-wave", name: "Elgato Wave:3")
        hardware.inputs.append(other)
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(other)
        #expect(hardware.currentID == 30)
        #expect(lock.preferredUID == "another-wave")
    }

    @Test func noInputsDoesNotWriteAndDoesNotForgetSelection() {
        let hardware = HardwareFixture()
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(hardware.wave)
        hardware.inputs = []
        hardware.currentID = nil
        lock.refresh()
        #expect(lock.status == .waiting)
        #expect(lock.preferredUID == "wave-3")
        #expect(hardware.writes == [10])
    }

    @Test func readAndWriteFailuresAreVisibleAndRecoverable() {
        let hardware = HardwareFixture()
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        hardware.writeFails = true
        lock.select(hardware.wave)
        #expect(lock.status.isError)
        #expect(lock.retryAfter != nil)
        hardware.writeFails = false
        lock.refresh()
        #expect(lock.status == .locked)
        hardware.readFails = true
        lock.refresh()
        #expect(lock.status.isError)
        hardware.readFails = false
        lock.refresh()
        #expect(lock.status == .locked)
    }

    @Test func successfulWriteWithoutEffectIsNeverReportedAsLocked() {
        let hardware = HardwareFixture()
        hardware.writeHasEffect = false
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(hardware.wave)
        #expect(lock.status.isError)
        #expect(lock.defaultInputID == 20)
        #expect(lock.retryAfter != nil)
    }

    @Test func repeatedOutsideChangesStopUntilExplicitRecovery() {
        let hardware = HardwareFixture()
        var instant: TimeInterval = 100
        let lock = MicrophoneLock(hardware: hardware, defaults: settings(), now: { instant })
        lock.select(hardware.wave)
        for _ in 0..<12 {
            hardware.currentID = 20
            lock.refresh()
        }
        #expect(hardware.writes.count == 5)
        #expect(lock.status.isError)
        #expect(lock.retryAfter == nil)
        instant = 130
        lock.refresh()
        #expect(hardware.writes.count == 5)
        lock.resetRecovery()
        lock.refresh()
        #expect(hardware.currentID == 10)
        #expect(lock.status == .locked)
    }

    @Test func failedWritesHaveBoundedAutomaticRetries() {
        let hardware = HardwareFixture()
        hardware.writeFails = true
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(hardware.wave)
        for _ in 0..<12 { lock.refresh() }
        #expect(hardware.writes.count == 4)
        #expect(lock.retryAfter == nil)
        #expect(lock.status.isError)
        hardware.writeFails = false
        lock.resetRecovery()
        lock.refresh()
        #expect(lock.status == .locked)
    }

    @Test func reconnectClearsPreviousFailures() {
        let hardware = HardwareFixture()
        hardware.writeFails = true
        let lock = MicrophoneLock(hardware: hardware, defaults: settings())
        lock.select(hardware.wave)
        for _ in 0..<5 { lock.refresh() }
        hardware.inputs = [hardware.builtin]
        lock.refresh()
        hardware.writeFails = false
        hardware.inputs = [hardware.wave, hardware.builtin]
        lock.refresh()
        #expect(lock.status == .locked)
    }

    @Test func unrelatedFlappingDeviceDoesNotResetContentionLimit() {
        let hardware = HardwareFixture()
        let lock = MicrophoneLock(hardware: hardware, defaults: settings(), now: { 100 })
        let unrelated = AudioInput(id: 50, uid: "flapping", name: "Outro dispositivo")
        lock.select(hardware.wave)
        for iteration in 0..<12 {
            hardware.inputs = iteration.isMultiple(of: 2)
                ? [hardware.wave, hardware.builtin, unrelated] : [hardware.wave, hardware.builtin]
            hardware.currentID = 20
            lock.refresh()
        }
        #expect(hardware.writes.count == 5)
        #expect(lock.status.isError)
        #expect(lock.retryAfter == nil)
    }
}
