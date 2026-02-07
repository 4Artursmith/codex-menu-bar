import SwiftUI
import AppKit

/// Simplified setup wizard that relies on Codex CLI authorization only.
struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isSyncing = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    @State private var isMigrating = false
    @State private var migrationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if MigrationService.shared.shouldShowMigrationOption() {
                migrationCard
                Divider()
            }

            content

            Spacer()

            Divider()

            footer
        }
        .frame(width: 560, height: 520)
        .onAppear {
            Task {
                await syncFromSystem(closeOnSuccess: true, showMissingMessage: false)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image("WizardLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)

            Text("Welcome to Codex Menu Bar")
                .font(.system(size: 22, weight: .semibold))

            Text("No API keys or session keys required.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
        .padding(.top, 26)
        .padding(.bottom, 20)
    }

    private var migrationCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 16))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 4) {
                Text("Import data from previous version")
                    .font(.system(size: 12, weight: .medium))

                Text(migrationMessage ?? "Migrate old profiles and settings automatically.")
                    .font(.system(size: 11))
                    .foregroundColor(migrationMessage == nil ? .secondary : .green)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: migrateOldData) {
                if isMigrating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 40)
                } else {
                    Text("Import")
                        .font(.system(size: 11))
                        .frame(width: 40)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isMigrating)

            Button("Skip") {
                skipMigration()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .disabled(isMigrating)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.blue.opacity(0.08))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How it works")
                .font(.system(size: 15, weight: .semibold))

            instructionRow("1. Open Terminal and run: codex login")
            instructionRow("2. Come back here and click Sync Authorization")
            instructionRow("3. The app will detect and use your CLI login automatically")

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://platform.openai.com/docs/codex") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open docs", systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await syncFromSystem(closeOnSuccess: true, showMissingMessage: true)
                    }
                } label: {
                    if isSyncing {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Sync Authorization", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSyncing)
            }
            .padding(.top, 4)

            if let statusMessage {
                HStack(spacing: 8) {
                    Image(systemName: statusIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundColor(statusIsError ? .red : .green)
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusIsError ? .red : .green)
                }
                .padding(10)
                .background((statusIsError ? Color.red : Color.green).opacity(0.08))
                .cornerRadius(8)
            }
        }
        .padding(26)
    }

    private var footer: some View {
        HStack {
            Button("Skip for now") {
                finishSetup()
                dismiss()
            }
            .buttonStyle(.bordered)
            .disabled(isSyncing)

            Spacer()

            Button("Continue") {
                finishSetup()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSyncing)
        }
        .padding(18)
    }

    @ViewBuilder
    private func instructionRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func syncFromSystem(closeOnSuccess: Bool, showMissingMessage: Bool) async {
        await MainActor.run {
            isSyncing = true
            if showMissingMessage {
                statusMessage = nil
            }
        }

        do {
            guard let profileId = await MainActor.run(body: { ProfileManager.shared.activeProfile?.id }) else {
                throw CodexCodeError.noProfileCredentials
            }

            guard let jsonData = try CodexCodeSyncService.shared.readSystemCredentials() else {
                if showMissingMessage {
                    await MainActor.run {
                        statusMessage = "No Codex CLI login found. Run 'codex login' first."
                        statusIsError = true
                        isSyncing = false
                    }
                } else {
                    await MainActor.run {
                        isSyncing = false
                    }
                }
                return
            }

            guard !CodexCodeSyncService.shared.isTokenExpired(jsonData),
                  CodexCodeSyncService.shared.extractAccessToken(from: jsonData) != nil else {
                await MainActor.run {
                    statusMessage = "Your Codex CLI login is expired. Run 'codex login' again."
                    statusIsError = true
                    isSyncing = false
                }
                return
            }

            try CodexCodeSyncService.shared.syncToProfile(profileId)

            await MainActor.run {
                ProfileManager.shared.loadProfiles()

                if var activeProfile = ProfileManager.shared.activeProfile, activeProfile.id == profileId {
                    activeProfile.hasCliAccount = true
                    activeProfile.cliAccountSyncedAt = Date()
                    ProfileManager.shared.updateProfile(activeProfile)
                }

                finishSetup()

                statusMessage = "Authorization synced successfully."
                statusIsError = false
                isSyncing = false
            }

            if closeOnSuccess {
                await MainActor.run {
                    dismiss()
                }
            }
        } catch {
            await MainActor.run {
                statusMessage = "Failed to sync authorization: \(error.localizedDescription)"
                statusIsError = true
                isSyncing = false
            }
        }
    }

    private func finishSetup() {
        SharedDataStore.shared.saveHasCompletedSetup(true)
        SharedDataStore.shared.markWizardShown()
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    private func migrateOldData() {
        isMigrating = true
        migrationMessage = nil

        Task {
            do {
                let count = try MigrationService.shared.migrateFromAppGroup()
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = "Imported \(count) profile(s) successfully."
                    ProfileManager.shared.loadProfiles()
                }
            } catch {
                await MainActor.run {
                    isMigrating = false
                    migrationMessage = "Import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func skipMigration() {
        UserDefaults.standard.set(true, forKey: "HasMigratedFromAppGroup")
        migrationMessage = "Import skipped."
    }
}
