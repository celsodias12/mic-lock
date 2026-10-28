import Testing
@testable import MicLockCore

private enum DeviceQueryError: Error { case unavailable }

@Suite @MainActor
struct AudioInventoryTests {
    @Test func presentDeviceQueryFailureIsPropagatedForRetry() {
        #expect(throws: DeviceQueryError.self) {
            try AudioInventory.snapshot(
                deviceIDs: { [10, 20] }, defaultInputID: { 20 },
                readInput: { _ in throw DeviceQueryError.unavailable }
            )
        }
    }

    @Test func disappearanceDuringQueryDoesNotHideOtherInputs() throws {
        var reads = 0
        let snapshot = try AudioInventory.snapshot(
            deviceIDs: { reads += 1; return reads == 1 ? [10, 20] : [20] },
            defaultInputID: { 20 },
            readInput: { id in
                if id == 10 { throw DeviceQueryError.unavailable }
                return AudioInput(id: 20, uid: "builtin", name: "Microfone do Mac")
            }
        )
        #expect(snapshot.inputs.map(\.uid) == ["builtin"])
        #expect(snapshot.defaultInputID == 20)
    }

    @Test func outputOnlyDevicesAreOmittedWithoutError() throws {
        let snapshot = try AudioInventory.snapshot(
            deviceIDs: { [30] }, defaultInputID: { nil }, readInput: { _ in nil }
        )
        #expect(snapshot.inputs.isEmpty)
    }
}
