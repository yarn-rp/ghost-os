// SettingsView.swift - Settings destination.
//
// Three sections:
//   - AI provider — one card per ProviderRegistry entry, shows live
//     health status + actionable hints.
//   - About — version, "reveal flows folder", paths.
//   - (Future slots, omitted for v1.)

import Flow42Core
import SwiftUI

struct SettingsView: View {
    @StateObject private var configStore = ProviderConfigStore()
    @StateObject private var healthCheck = ProviderHealthCheck()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section(
                    title: "AI provider",
                    subtitle: ProviderRegistry.all.count > 1
                        ? "Pick the AI you want to drive your flows."
                        : "The AI that drives your flows."
                ) {
                    providerList
                }

                section(title: "About", subtitle: nil) {
                    aboutCard
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(36)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle("Settings")
        .onAppear {
            if let provider = configStore.selected {
                healthCheck.check(provider)
            }
        }
        .onChange(of: configStore.selected?.id) { _, _ in
            if let provider = configStore.selected {
                healthCheck.check(provider)
            }
        }
    }

    // MARK: - Provider list

    @ViewBuilder
    private var providerList: some View {
        VStack(spacing: 10) {
            ForEach(ProviderRegistry.all) { provider in
                ProviderCard(
                    provider: provider,
                    isSelected: configStore.selected?.id == provider.id,
                    status: configStore.selected?.id == provider.id
                        ? healthCheck.status
                        : .unknown,
                    onSelect: {
                        configStore.select(provider)
                    },
                    onRecheck: {
                        healthCheck.check(provider)
                    }
                )
            }
        }
    }

    // MARK: - About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(label: "flow42 root", value: Flow42Paths.root()) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: Flow42Paths.root())]
                )
            }
            Divider().opacity(0.3)
            row(label: "Flows folder", value: Flow42Paths.flowsRoot()) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: Flow42Paths.flowsRoot())]
                )
            }
            Divider().opacity(0.3)
            row(label: "Config file", value: Flow42Paths.configFile()) {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: Flow42Paths.configFile())]
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(
        title: String, subtitle: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            content()
                .padding(.top, 4)
        }
    }

    private func row(label: String, value: String, onReveal: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button(action: onReveal) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
        }
    }
}

// MARK: - Provider card

private struct ProviderCard: View {
    let provider: ProviderDefinition
    let isSelected: Bool
    let status: ProviderHealthCheck.Status
    let onSelect: () -> Void
    let onRecheck: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: provider.logoSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accentForStatus)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accentForStatus.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Text(provider.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                statusChip
            }

            // Detail row when status carries actionable info.
            if let detail = statusDetail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.primary.opacity(0.04))
                    )
            }

            HStack(spacing: 8) {
                if !isSelected {
                    Button("Select", action: onSelect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Button("Recheck") { onRecheck() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if let url = provider.docsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Setup help", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? accentForStatus.opacity(0.6) : .primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : 0.5
                )
        )
        .onHover { isHovered = $0 }
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(accentForStatus)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(accentForStatus.opacity(0.12))
        )
        .overlay(
            Capsule().strokeBorder(accentForStatus.opacity(0.35), lineWidth: 0.5)
        )
        .foregroundStyle(accentForStatus)
    }

    private var accentForStatus: Color {
        switch status {
        case .connected:    return Color(red: 0x36/255, green: 0xC8/255, blue: 0x5B/255) // green
        case .checking:     return .secondary
        case .authRequired: return Color(red: 0xFF/255, green: 0xB6/255, blue: 0x40/255) // amber
        case .notInstalled: return Color(red: 0xFF/255, green: 0x5C/255, blue: 0x5C/255) // red
        case .other:        return Color(red: 0xFF/255, green: 0x5C/255, blue: 0x5C/255) // red
        case .unknown:      return .secondary
        }
    }

    private var statusDetail: String? {
        switch status {
        case .authRequired(let d), .notInstalled(let d), .other(let d):
            return d
        case .connected, .checking, .unknown:
            return nil
        }
    }
}
