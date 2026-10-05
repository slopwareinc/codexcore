import SwiftUI
import AppKit
import CodexCore
import CodexCoreUI

struct CodexAppRemoteControlFeaturesView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Bindable var features: CodexAppRemoteControlFeatures
    @State private var confirmsEnable = false
    @State private var confirmsDisable = false
    @State private var revokeTarget: CodexSchemaRemoteControlClient?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.lg) {
            Label("Remote control", systemImage: "iphone.and.arrow.forward")
                .font(theme.fonts.panelTitle)
            Text("Paired devices can access this Codex environment. Enable access explicitly, pair a device, and revoke devices you no longer use.")
                .font(theme.fonts.body).foregroundStyle(theme.colors.textSecondary)
            if let status = features.status {
                row("Server", status.serverName)
                row("Connection", status.status.rawValue)
                if let environmentID = status.environmentID { row("Environment", environmentID) }
            } else {
                Text("Refresh to read the current remote-control status.")
                    .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
            Toggle("Apply enable or disable temporarily", isOn: $features.temporaryChange)
                .font(theme.fonts.body)
            HStack {
                Button(features.isBusy ? "Working…" : "Refresh status") { Task { await features.refresh() } }
                if features.status?.status == .disabled || features.status == nil {
                    Button("Enable remote control…") { confirmsEnable = true }
                } else {
                    Button("Disable remote control…", role: .destructive) { confirmsDisable = true }
                    Button("Pair a device") { Task { await features.startPairing() } }
                        .disabled(features.status?.status != .connected)
                }
            }.disabled(features.isBusy)
            if let pairing = features.pairing {
                pairingPanel(pairing)
            }
            if !features.clients.isEmpty {
                Text("Paired devices").font(theme.fonts.panelTitle)
                ForEach(features.clients, id: \.clientID) { client in
                    HStack(alignment: .top, spacing: theme.spacing.md) {
                        Image(systemName: client.deviceType == "phone" ? "iphone" : "desktopcomputer")
                            .foregroundStyle(theme.colors.textSecondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.displayName ?? client.deviceModel ?? "Device").font(theme.fonts.label)
                            Text([client.platform, client.osVersion, client.appVersion].compactMap { $0 }.joined(separator: " · "))
                                .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
                        }
                        Spacer()
                        Button("Revoke…", role: .destructive) { revokeTarget = client }
                            .disabled(features.isBusy)
                    }
                }
            }
            if let error = features.errorMessage { CodexErrorBanner(message: error) }
            if let notice = features.notice {
                Text(notice).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing.lg)
        .background(theme.colors.surface, in: RoundedRectangle(cornerRadius: theme.radii.large))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.large).stroke(theme.colors.border, lineWidth: 1))
        .confirmationDialog("Enable access from paired devices?", isPresented: $confirmsEnable) {
            Button("Enable remote control") { Task { await features.enable() } }
        } message: { Text("New devices still need to complete pairing. The runtime manages their permissions.") }
        .confirmationDialog("Disable remote control?", isPresented: $confirmsDisable) {
            Button("Disable", role: .destructive) { Task { await features.disable() } }
        }
        .confirmationDialog("Revoke this device's access?", isPresented: Binding(
            get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }
        )) {
            if let client = revokeTarget {
                Button("Revoke \(client.displayName ?? "device")", role: .destructive) {
                    revokeTarget = nil
                    Task { await features.revoke(client) }
                }
            }
        }
        .onDisappear { features.clearPairing() }
    }

    private func pairingPanel(_ pairing: CodexSchemaRemoteControlPairingStartResponse) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text("Pairing code").font(theme.fonts.label)
            Text(pairing.manualPairingCode ?? pairing.pairingCode)
                .font(theme.fonts.code).textSelection(.enabled)
                .privacySensitive()
            Text("Expires \(Date(timeIntervalSince1970: TimeInterval(pairing.expiresAt)).formatted(date: .omitted, time: .shortened))")
                .font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary)
            HStack {
                Button("Copy code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pairing.manualPairingCode ?? pairing.pairingCode, forType: .string)
                }
                Button("Check pairing") { Task { await features.checkPairing() } }
                    .disabled(features.isBusy)
                Button("Hide code") { features.clearPairing() }
            }
        }
        .padding(theme.spacing.md)
        .background(theme.colors.surfaceElevated, in: RoundedRectangle(cornerRadius: theme.radii.medium))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(theme.fonts.label)
            Spacer()
            Text(value).font(theme.fonts.caption).foregroundStyle(theme.colors.textSecondary).textSelection(.enabled)
        }
    }
}
