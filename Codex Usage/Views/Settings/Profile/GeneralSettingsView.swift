//
//  GeneralSettingsView.swift
//  Codex Usage - General Profile Settings
//
//  Refactored to use DesignTokens and SettingsSection components
//

import SwiftUI
import UserNotifications

/// General profile settings: Refresh interval, Auto-start, Notifications
struct GeneralSettingsView: View {
    @StateObject private var profileManager = ProfileManager.shared

    private struct RefreshOption: Hashable, Identifiable {
        let seconds: TimeInterval
        let title: String
        var id: TimeInterval { seconds }
    }

    private let refreshOptions: [RefreshOption] = [
        RefreshOption(seconds: 60, title: "1 minute"),
        RefreshOption(seconds: 300, title: "5 minutes"),
        RefreshOption(seconds: 900, title: "15 minutes"),
        RefreshOption(seconds: 1_800, title: "30 minutes"),
        RefreshOption(seconds: 3_600, title: "1 hour"),
        RefreshOption(seconds: 18_000, title: "5 hours"),
        RefreshOption(seconds: 86_400, title: "1 day")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                // Page Header
                SettingsPageHeader(
                    title: "general.title".localized,
                    subtitle: "general.subtitle".localized
                )

                if let profile = profileManager.activeProfile {
                    // Refresh Interval
                    SettingsSectionCard(
                        title: "general.refresh_title".localized,
                        subtitle: "general.refresh_subtitle".localized
                    ) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                            HStack(spacing: DesignTokens.Spacing.iconText) {
                                Image(systemName: "clock")
                                    .font(.system(size: DesignTokens.Icons.standard))
                                    .foregroundColor(DesignTokens.Colors.accent)
                                    .frame(width: DesignTokens.Spacing.iconFrame)

                                Text(nearestRefreshOption(for: profile.refreshInterval).title)
                                    .font(DesignTokens.Typography.bodyMedium)

                                Spacer()
                            }

                            Picker(
                                "Auto refresh",
                                selection: Binding(
                                    get: { nearestRefreshOption(for: profile.refreshInterval).seconds },
                                    set: { newValue in
                                        var updated = profile
                                        updated.refreshInterval = newValue
                                        profileManager.updateProfile(updated)
                                    }
                                )
                            ) {
                                ForEach(refreshOptions) { option in
                                    Text(option.title).tag(option.seconds)
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                NotificationCenter.default.post(name: .manualRefreshRequested, object: nil)
                            } label: {
                                Label("Update Now", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    // Auto-Start Session
                    SettingsSectionCard(
                        title: "general.autostart_title".localized,
                        subtitle: "general.autostart_subtitle".localized
                    ) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                            SettingToggle(
                                title: "general.autostart_toggle".localized,
                                description: "general.autostart_description".localized,
                                isOn: Binding(
                                    get: { profile.autoStartSessionEnabled },
                                    set: { newValue in
                                        var updated = profile
                                        updated.autoStartSessionEnabled = newValue
                                        profileManager.updateProfile(updated)
                                    }
                                )
                            )

                            // Requirement
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                                Text("Requirements:")
                                    .font(DesignTokens.Typography.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)

                                Text("general.autostart_requirement".localized)
                                    .font(DesignTokens.Typography.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Notifications
                    SettingsSectionCard(
                        title: "general.notifications_title".localized,
                        subtitle: "general.notifications_subtitle".localized
                    ) {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                            SettingToggle(
                                title: "notifications.enable".localized,
                                description: "notifications.enable.description".localized,
                                isOn: Binding(
                                    get: { profile.notificationSettings.enabled },
                                    set: { newValue in
                                        var updated = profile
                                        updated.notificationSettings.enabled = newValue
                                        profileManager.updateProfile(updated)

                                        if newValue {
                                            requestNotificationPermission()
                                        }
                                    }
                                )
                            )

                            if profile.notificationSettings.enabled {
                                Divider()

                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                                    Text("notifications.alert_thresholds".localized)
                                        .font(DesignTokens.Typography.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(.secondary)

                                    VStack(spacing: DesignTokens.Spacing.small) {
                                        ThresholdIndicator(level: "75%", color: SettingsColors.usageMedium, label: "notifications.threshold.warning".localized)
                                        ThresholdIndicator(level: "90%", color: SettingsColors.usageHigh, label: "notifications.threshold.high".localized)
                                        ThresholdIndicator(level: "95%", color: SettingsColors.usageCritical, label: "notifications.threshold.critical".localized)
                                        ThresholdIndicator(level: "0%", color: SettingsColors.usageLow, label: "notifications.threshold.session_reset".localized)
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    // MARK: - Helper Methods

    private func nearestRefreshOption(for interval: TimeInterval) -> RefreshOption {
        guard let nearest = refreshOptions.min(by: { abs($0.seconds - interval) < abs($1.seconds - interval) }) else {
            return refreshOptions[0]
        }
        return nearest
    }

    private func requestNotificationPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            if settings.authorizationStatus == .authorized {
                NotificationManager.shared.sendSimpleAlert(type: .notificationsEnabled)
            } else if settings.authorizationStatus == .notDetermined {
                let granted = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted == true {
                    NotificationManager.shared.sendSimpleAlert(type: .notificationsEnabled)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview {
    GeneralSettingsView()
        .frame(width: 520, height: 600)
}
