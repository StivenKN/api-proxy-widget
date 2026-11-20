import ProxyLimits
import SwiftUI

@main
struct APIProxyWidgetApp: App {
    @State private var store = LimitsStore()

    var body: some Scene {
        MenuBarExtra {
            PanelView(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: store.pools.first, isOutOfDate: store.isOutOfDate))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Switches the panel between limits and settings. Settings come first until a hub is saved.
private struct PanelView: View {
    let store: LimitsStore
    @State private var showsSettings = false

    var body: some View {
        Group {
            if !store.isLoaded {
                ProgressView().controlSize(.small).padding(24)
            } else if showsSettings || !store.isConfigured {
                SettingsView(store: store) { showsSettings = false }
            } else {
                LimitsView(store: store) { showsSettings = true }
            }
        }
        .frame(width: 330)
    }
}
