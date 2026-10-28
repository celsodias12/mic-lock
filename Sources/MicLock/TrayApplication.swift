import AppKit
import MicLockCore
import ServiceManagement

@MainActor
final class TrayApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hardware = CoreAudioHardware()
    private let controller: MicrophoneLock
    private let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private var retry: DispatchWorkItem?
    private var observerRetry: DispatchWorkItem?
    private var observerFailures = 0
    private var monitoringError: String?
    private let smokeTest: Bool

    init(smokeTest: Bool = false) {
        self.smokeTest = smokeTest
        let defaults = smokeTest
            ? UserDefaults(suiteName: "app.miclock.smoke.\(UUID().uuidString)")!
            : .standard
        controller = MicrophoneLock(hardware: hardware, defaults: defaults)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil
        )
        installObservers()
        reconcile()
        if smokeTest {
            print("Tray: \(statusItem?.button != nil ? "OK" : "FALHOU")")
            for item in menu.items where !item.isSeparatorItem { print(item.title) }
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        retry?.cancel()
        observerRetry?.cancel()
        hardware.stopObserving()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.button?.performClick(nil)
        return false
    }

    func menuWillOpen(_ menu: NSMenu) { reconcile() }

    private func installObservers() {
        observerRetry?.cancel()
        do {
            try hardware.startObserving { [weak self] recovery in
                guard let self else { return }
                if recovery {
                    self.controller.resetRecovery()
                    self.observerFailures = 0
                    self.installObservers()
                }
                self.reconcile()
            }
            monitoringError = nil
            observerFailures = 0
        } catch {
            monitoringError = error.localizedDescription
            if observerFailures < 3 {
                let delay = pow(2, Double(observerFailures))
                observerFailures += 1
                let work = DispatchWorkItem { [weak self] in
                    self?.installObservers()
                    self?.reconcile()
                }
                observerRetry = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    private func reconcile() {
        retry?.cancel()
        controller.refresh()
        rebuildMenu()
        if let delay = controller.retryAfter {
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        add("Mic Lock").isEnabled = false
        add(statusText).isEnabled = false
        if case .error(let message) = controller.status {
            let item = add(shortened(message))
            item.isEnabled = false
            item.toolTip = message
        }
        if let monitoringError {
            let item = add("Monitoramento indisponível")
            item.isEnabled = false
            item.toolTip = monitoringError
        }
        let current = controller.inputs.first { $0.id == controller.defaultInputID }
        let prefix = controller.status.isError ? "Última leitura" : "Entrada atual"
        add("\(prefix): \(current.map(inputTitle) ?? "indisponível")").isEnabled = false
        menu.addItem(.separator())
        add("Manter como padrão").isEnabled = false

        if let uid = controller.preferredUID, !controller.inputs.contains(where: { $0.uid == uid }) {
            let item = add("\(controller.preferredName ?? "Microfone escolhido") (desconectado)")
            item.state = .on
            item.isEnabled = false
        }
        for input in controller.inputs {
            let item = add(inputTitle(input), action: #selector(selectInput(_:)))
            item.representedObject = input.uid
            item.toolTip = input.uid
            item.state = input.uid == controller.preferredUID ? .on : .off
        }
        if controller.inputs.isEmpty { add("Nenhuma entrada disponível").isEnabled = false }

        menu.addItem(.separator())
        let lockItem = add("Manter microfone fixado", action: #selector(toggleLock))
        lockItem.state = controller.isEnabled ? .on : .off
        lockItem.isEnabled = controller.preferredUID != nil
        if controller.status.isError || monitoringError != nil {
            add("Tentar novamente", action: #selector(retryNow))
        }
        let login = SMAppService.mainApp.status
        let loginItem = add(
            login == .requiresApproval ? "Iniciar no login (aprovação pendente…)" : "Iniciar no login",
            action: #selector(toggleLogin)
        )
        loginItem.state = login == .enabled ? .on : login == .requiresApproval ? .mixed : .off
        menu.addItem(.separator())
        add("Sair do Mic Lock", action: #selector(quit), key: "q")

        let symbol: String
        switch controller.status {
        case .locked: symbol = "mic.fill"
        case .waiting: symbol = "mic.slash"
        case .error: symbol = "exclamationmark.triangle"
        default: symbol = "mic"
        }
        let image = NSImage(systemSymbolName: monitoringError == nil ? symbol : "exclamationmark.triangle", accessibilityDescription: "Mic Lock: \(statusText)")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "Mic Lock — \(statusText)"
    }

    private var statusText: String {
        switch controller.status {
        case .unconfigured: "Escolha um microfone para fixar"
        case .paused: "Fixação pausada"
        case .waiting: "Aguardando conexão"
        case .locked: "Fixado: \(controller.preferredName ?? "microfone escolhido")"
        case .error: "Não foi possível fixar a entrada"
        }
    }

    @discardableResult
    private func add(_ title: String, action: Selector? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = action == nil ? nil : self
        menu.addItem(item)
        return item
    }

    private func shortened(_ text: String) -> String {
        text.count > 78 ? String(text.prefix(75)) + "…" : text
    }

    private func inputTitle(_ input: AudioInput) -> String {
        let matches = controller.inputs.filter { $0.name == input.name }
        let suffix = matches.count > 1 ? " · \((matches.firstIndex(of: input) ?? 0) + 1)" : ""
        return input.name + suffix
    }

    @objc private func selectInput(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        do {
            if let input = try hardware.snapshot().inputs.first(where: { $0.uid == uid }) {
                controller.select(input)
            }
            reconcile()
        } catch { showError("Não foi possível escolher o microfone", error: error) }
    }

    @objc private func toggleLock() {
        controller.setEnabled(!controller.isEnabled)
        reconcile()
    }

    @objc private func retryNow() {
        controller.resetRecovery()
        observerFailures = 0
        installObservers()
        reconcile()
    }

    @objc private func wokeUp() { retryNow() }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled: try service.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try service.register()
            }
        } catch { showError("Não foi possível alterar o início no login", error: error) }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
