// ProviderConfigStore.swift - The app's view of "which provider is
// selected", backed by ConfigFile in Flow42Core.
//
// Auto-selects the default provider on first run (writes config.yaml).
// SwiftUI binds to `selected` as `@Published`; flipping it writes through
// to disk and triggers a fresh health check.

import Combine
import Flow42Core
import Foundation

@MainActor
final class ProviderConfigStore: ObservableObject {

    /// The currently selected provider definition. Nil means no provider
    /// is configured AND no default exists (impossible today since
    /// ProviderRegistry.defaultProvider is always non-nil, but we model
    /// the absence cleanly so future changes don't crash the UI).
    @Published private(set) var selected: ProviderDefinition?

    init() {
        let config = ConfigFile.read()
        if let id = config.provider?.id, let provider = ProviderRegistry.find(id: id) {
            self.selected = provider
        } else if let fallback = ProviderRegistry.defaultProvider {
            // First run (or stale id) — auto-pick the default and persist
            // so the rest of the app sees a valid config from this point.
            self.selected = fallback
            try? ConfigFile.setProvider(id: fallback.id)
        } else {
            self.selected = nil
        }
    }

    /// Explicitly select a provider. No-op if it's already selected.
    func select(_ provider: ProviderDefinition) {
        if selected?.id == provider.id { return }
        selected = provider
        try? ConfigFile.setProvider(id: provider.id)
    }
}
