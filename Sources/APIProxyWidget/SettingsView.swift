import ProxyLimits
import ServiceManagement
import SwiftUI

/// Hub address, management key and launch at login. Shown inside the panel, and first when
/// the widget has nothing to read from yet.
struct SettingsView: View {
    let store: LimitsStore
    let close: () -> Void

    @State private var hubText = ""
    @State private var keyText = ""
    @State private var problem: String?
    @State private var isSaving = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.isConfigured ? "Settings" : "Connect your hub")
                .font(.system(size: 15, weight: .semibold))
            if !store.isConfigured {
                Text("The widget reads limits from your CLIProxyAPI hub's management API.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Hub address").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                TextField("https://hub.example.ts.net:8317", text: $hubText)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Management key").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                SecureField(keyPlaceholder, text: $keyText)
                    .textFieldStyle(.roundedBorder)
                    // Not a login: keeps macOS from offering saved passwords, whose popup
                    // also swallows the Return that should save.
                    .textContentType(.oneTimeCode)
                    .onSubmit(save)
                Text("The hub's management secret-key, not the access key your tools send. It is stored in your Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Open at login", isOn: $launchesAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchesAtLogin) { _, wanted in setLaunchAtLogin(wanted) }

            HStack {
                Button("Quit") { NSApplication.shared.terminate(nil) }
                Spacer()
                if store.isConfigured {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                }
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(isSaving)
            }
        }
        .padding(Metrics.edge)
        .onAppear { hubText = store.hubURL?.absoluteString ?? "http://127.0.0.1:8317" }
    }

    private var keyPlaceholder: String {
        guard let typed = HubClient.normalizedBaseURL(hubText), store.hasSavedKey(for: typed) else {
            return "Paste the key"
        }
        return "Saved. Paste to replace"
    }

    private func save() {
        // Return can reach this through both the field and the default button. A second save
        // would send a wrong key twice, and each wrong key counts toward the hub's ban.
        guard !isSaving else { return }
        guard let url = HubClient.normalizedBaseURL(hubText) else {
            problem = "That doesn't look like a hub address. Try https://hub.example.ts.net:8317."
            return
        }
        let key = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || store.hasSavedKey(for: url) else {
            problem = "Paste the management key for this hub."
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            guard await store.save(hubURL: url, managementKey: key.isEmpty ? nil : key) else {
                problem = "The key could not be saved to your Keychain."
                return
            }
            keyText = ""
            problem = nil
            close()
        }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        // Setting the checkbox back to the real state below lands here again.
        guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = "Open at login needs the installed app (make install): \(error.localizedDescription)"
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}
