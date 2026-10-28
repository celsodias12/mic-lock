import AppKit
import Foundation

let arguments = Set(CommandLine.arguments.dropFirst())
if arguments.contains("--diagnose") {
    do {
        let snapshot = try CoreAudioHardware().snapshot()
        let devices: [[String: Any]] = snapshot.inputs.map {
            ["id": $0.id, "uid": $0.uid, "name": $0.name, "isDefault": $0.id == snapshot.defaultInputID]
        }
        let data = try JSONSerialization.data(withJSONObject: ["inputs": devices], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else if arguments.isEmpty || arguments == ["--smoke-test"] {
    let app = NSApplication.shared
    // Avoid two independent controllers competing over the same microphone.
    if !arguments.contains("--smoke-test"),
       let identifier = Bundle.main.bundleIdentifier,
       NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
           $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
       }) {
        exit(0)
    }
    app.setActivationPolicy(.accessory)
    let delegate = TrayApplication(smokeTest: arguments.contains("--smoke-test"))
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
} else {
    FileHandle.standardError.write(Data("Uso: MicLock [--diagnose | --smoke-test]\n".utf8))
    exit(2)
}
