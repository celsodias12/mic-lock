@MainActor
public enum AudioInventory {
    /// Ignore a failed query only when a fresh inventory confirms disappearance.
    public static func snapshot(
        deviceIDs: () throws -> [UInt32],
        defaultInputID: () throws -> UInt32?,
        readInput: (UInt32) throws -> AudioInput?
    ) throws -> AudioSnapshot {
        let ids = try deviceIDs()
        let current = try defaultInputID()
        var inputs: [AudioInput] = []
        for id in ids {
            do {
                if let input = try readInput(id) { inputs.append(input) }
            } catch {
                if try deviceIDs().contains(id) { throw error }
            }
        }
        return AudioSnapshot(inputs: inputs, defaultInputID: current)
    }
}
