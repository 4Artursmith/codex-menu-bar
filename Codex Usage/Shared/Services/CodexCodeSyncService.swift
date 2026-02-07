//
//  CodexCodeSyncService.swift
//  Codex Usage
//
//  Created by Codex Code on 2026-01-07.
//

import Foundation
import Security

struct CodexCLIAccountSummary {
    let email: String?
    let subscriptionLabel: String
    let rawSubscriptionType: String
    let scopes: [String]
    let accountId: String?
}

/// Manages synchronization of Codex Code CLI credentials between system Keychain and profiles
class CodexCodeSyncService {
    static let shared = CodexCodeSyncService()

    private struct CredentialsCacheEntry {
        let credentials: String?
        let expiresAt: Date
    }

    private struct ValidityCacheEntry {
        let isValid: Bool
        let expiresAt: Date
    }

    private struct SummaryCacheEntry {
        let summary: CodexCLIAccountSummary?
        let expiresAt: Date
    }

    private struct TokenExpiryCacheEntry {
        let expiry: Date?
        let expiresAt: Date
    }

    private let cacheQueue = DispatchQueue(label: "CodexCodeSyncService.cache")
    private var cachedSystemCredentials: CredentialsCacheEntry?
    private var cachedSystemValidity: ValidityCacheEntry?
    private var cachedAccountSummaries: [String: SummaryCacheEntry] = [:]
    private var cachedTokenExpiries: [String: TokenExpiryCacheEntry] = [:]
    private var isRefreshingValidityCache = false
    private var lastValidityRefreshStartAt: Date = .distantPast
    private let credentialsCacheTTL: TimeInterval = 5
    private let validityCacheTTL: TimeInterval = 30
    private let summaryCacheTTL: TimeInterval = 120
    private let tokenExpiryCacheTTL: TimeInterval = 30
    private let minimumValidityRefreshInterval: TimeInterval = 5
    private let keychainReadTimeout: TimeInterval = 2.0

    private init() {}

    // MARK: - System Keychain Access

    /// Reads Codex Code credentials from system Keychain using security command
    func readSystemCredentials(forceRefresh: Bool = false) throws -> String? {
        let now = Date()
        if !forceRefresh,
           let cached = cacheQueue.sync(execute: { cachedSystemCredentials }),
           cached.expiresAt > now {
            return cached.credentials
        }

        var resolvedCredentials: String?
        var keychainError: Error?

        // Fast path: Codex CLI keeps OAuth credentials in ~/.codex/auth.json.
        // Prefer this source first to avoid keychain interaction prompts/hangs.
        if let authFileCredentials = try readCredentialsFromCodexAuthFile() {
            LoggingService.shared.log("Loaded CLI credentials from ~/.codex/auth.json")
            resolvedCredentials = authFileCredentials
        }

        if resolvedCredentials == nil {
            do {
                if let keychainCredentials = try readCredentialsFromKeychain() {
                    resolvedCredentials = keychainCredentials
                }
            } catch {
                keychainError = error
                LoggingService.shared.log("Keychain read failed after auth.json fallback")
            }
        }

        if resolvedCredentials == nil, let keychainError {
            throw keychainError
        }

        storeSystemCredentialsCache(resolvedCredentials)
        clearSystemValidityCache()
        return resolvedCredentials
    }

    /// Reads CLI credentials from macOS Keychain
    private func readCredentialsFromKeychain() throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "Codex Code-credentials",
            "-a", NSUserName(),
            "-w"  // Print password only
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        guard process.waitUntilExit(timeout: keychainReadTimeout) else {
            LoggingService.shared.log("Keychain read timed out, skipping keychain path")
            return nil
        }

        let exitCode = process.terminationStatus

        if exitCode == 0 {
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let value = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw CodexCodeError.invalidJSON
            }
            return value
        } else if exitCode == 44 {
            // Exit code 44 = item not found
            return nil
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            LoggingService.shared.log("Failed to read keychain: \(errorString)")
            throw CodexCodeError.keychainReadFailed(status: OSStatus(exitCode))
        }
    }

    /// Reads CLI credentials from ~/.codex/auth.json and normalizes them into app format.
    /// This supports Codex CLI OAuth logins that are not mirrored to Keychain.
    private func readCredentialsFromCodexAuthFile() throws -> String? {
        let authFileURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")

        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            return nil
        }

        let fileData = try Data(contentsOf: authFileURL)
        guard let root = try JSONSerialization.jsonObject(with: fileData) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }

        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "subscriptionType": (root["auth_mode"] as? String) ?? "chatgpt"
        ]

        if let refreshToken = tokens["refresh_token"] as? String, !refreshToken.isEmpty {
            oauth["refreshToken"] = refreshToken
        }

        if let idToken = tokens["id_token"] as? String, !idToken.isEmpty {
            oauth["idToken"] = idToken
        }

        if let accountId = tokens["account_id"] as? String, !accountId.isEmpty {
            oauth["accountId"] = accountId
        }

        if let jwtPayload = decodeJWTPayload(accessToken) {
            if let expiry = jwtPayload["exp"] as? TimeInterval {
                oauth["expiresAt"] = expiry
            } else if let expiry = jwtPayload["exp"] as? Int {
                oauth["expiresAt"] = TimeInterval(expiry)
            }

            if let scopes = jwtPayload["scp"] as? [String], !scopes.isEmpty {
                oauth["scopes"] = scopes
            } else if let scopesString = jwtPayload["scp"] as? String {
                let scopes = scopesString
                    .split(separator: " ")
                    .map(String.init)
                    .filter { !$0.isEmpty }
                if !scopes.isEmpty {
                    oauth["scopes"] = scopes
                }
            }
        }

        var normalized: [String: Any] = ["codexAiOauth": oauth]
        if let lastRefresh = root["last_refresh"] as? String {
            normalized["lastRefresh"] = lastRefresh
        }

        let normalizedData = try JSONSerialization.data(withJSONObject: normalized)
        return String(data: normalizedData, encoding: .utf8)
    }

    /// Decodes JWT payload (base64url) for extracting expiry/scopes.
    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else {
            return nil
        }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }

        return payload
    }

    /// Writes Codex Code credentials to system Keychain using security command
    func writeSystemCredentials(_ jsonData: String) throws {
        LoggingService.shared.log("Writing credentials to keychain using security command")

        // First, delete existing item
        let deleteProcess = Process()
        deleteProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        deleteProcess.arguments = [
            "delete-generic-password",
            "-s", "Codex Code-credentials",
            "-a", NSUserName()
        ]

        try deleteProcess.run()
        deleteProcess.waitUntilExit()

        let deleteExitCode = deleteProcess.terminationStatus
        if deleteExitCode == 0 {
            LoggingService.shared.log("Deleted existing keychain item")
        } else {
            LoggingService.shared.log("No existing keychain item to delete (or delete failed with code \(deleteExitCode))")
        }

        // Add new item using security command
        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        addProcess.arguments = [
            "add-generic-password",
            "-s", "Codex Code-credentials",
            "-a", NSUserName(),
            "-w", jsonData,
            "-U"  // Update if exists
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        addProcess.standardOutput = outputPipe
        addProcess.standardError = errorPipe

        try addProcess.run()
        addProcess.waitUntilExit()

        let exitCode = addProcess.terminationStatus

        if exitCode == 0 {
            LoggingService.shared.log("✅ Added Codex Code system credentials successfully using security command")
            storeSystemCredentialsCache(jsonData)
            clearSystemValidityCache()
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            LoggingService.shared.log("❌ Failed to add credentials: \(errorString)")
            throw CodexCodeError.keychainWriteFailed(status: OSStatus(exitCode))
        }
    }

    // MARK: - Profile Sync Operations

    /// Syncs credentials from system to profile (one-time copy)
    func syncToProfile(_ profileId: UUID) throws {
        guard let jsonData = try readSystemCredentials() else {
            throw CodexCodeError.noCredentialsFound
        }

        try syncCredentialsJSONToProfile(jsonData, profileId: profileId)
    }

    /// Syncs provided credentials JSON to a profile (without reading system credentials again).
    func syncCredentialsJSONToProfile(_ jsonData: String, profileId: UUID) throws {
        try validateCredentialsJSON(jsonData)

        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw CodexCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = jsonData
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Synced CLI credentials to profile: \(profileId)")
    }

    private func validateCredentialsJSON(_ jsonData: String) throws {
        guard let data = jsonData.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
            throw CodexCodeError.invalidJSON
        }
    }

    /// Applies profile's CLI credentials to system (overwrites current login)
    func applyProfileCredentials(_ profileId: UUID) throws {
        LoggingService.shared.log("🔄 Applying CLI credentials for profile: \(profileId)")

        let profiles = ProfileStore.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }),
              let jsonData = profile.cliCredentialsJSON else {
            LoggingService.shared.log("❌ No CLI credentials found for profile: \(profileId)")
            throw CodexCodeError.noProfileCredentials
        }

        LoggingService.shared.log("📦 Found CLI credentials, writing to keychain...")
        try writeSystemCredentials(jsonData)

        LoggingService.shared.log("✅ Applied profile CLI credentials to system: \(profileId)")
    }

    /// Removes CLI credentials from profile (doesn't affect system)
    func removeFromProfile(_ profileId: UUID) throws {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw CodexCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = nil
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Removed CLI credentials from profile: \(profileId)")
    }

    // MARK: - Access Token Extraction

    func extractAccessToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["codexAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    func hasValidSystemCLIOAuthCached() -> Bool {
        let now = Date()
        if let cached = cacheQueue.sync(execute: { cachedSystemValidity }),
           cached.expiresAt > now {
            return cached.isValid
        }

        let staleValue = cacheQueue.sync { cachedSystemValidity?.isValid ?? false }
        refreshSystemValidityCacheInBackgroundIfNeeded()
        return staleValue
    }

    /// Pre-warms system CLI OAuth validity cache asynchronously.
    func prewarmSystemCLIOAuthValidityCache() {
        refreshSystemValidityCacheInBackgroundIfNeeded(forceRefresh: true)
    }

    func extractSubscriptionInfo(from jsonData: String) -> (type: String, scopes: [String])? {
        guard let summary = extractAccountSummary(from: jsonData) else {
            return nil
        }

        return (summary.subscriptionLabel, summary.scopes)
    }

    func extractAccountSummary(from jsonData: String) -> CodexCLIAccountSummary? {
        let now = Date()
        if let cached = cacheQueue.sync(execute: { cachedAccountSummaries[jsonData] }),
           cached.expiresAt > now {
            return cached.summary
        }

        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["codexAiOauth"] as? [String: Any] else {
            cacheQueue.sync {
                pruneAuxCachesIfNeeded()
                cachedAccountSummaries[jsonData] = SummaryCacheEntry(
                    summary: nil,
                    expiresAt: now.addingTimeInterval(summaryCacheTTL)
                )
            }
            return nil
        }

        let rawType = (oauth["subscriptionType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let scopes = oauth["scopes"] as? [String] ?? []
        let accountId = oauth["accountId"] as? String
        let email = extractEmail(from: oauth)

        let summary = CodexCLIAccountSummary(
            email: email,
            subscriptionLabel: normalizedSubscriptionLabel(rawType: rawType, scopes: scopes),
            rawSubscriptionType: rawType,
            scopes: scopes,
            accountId: accountId
        )

        cacheQueue.sync {
            pruneAuxCachesIfNeeded()
            cachedAccountSummaries[jsonData] = SummaryCacheEntry(
                summary: summary,
                expiresAt: now.addingTimeInterval(summaryCacheTTL)
            )
        }

        return summary
    }

    private func extractEmail(from oauth: [String: Any]) -> String? {
        if let email = oauth["email"] as? String, !email.isEmpty {
            return email
        }

        if let idToken = oauth["idToken"] as? String,
           let payload = decodeJWTPayload(idToken),
           let email = payload["email"] as? String ?? payload["preferred_username"] as? String ?? payload["upn"] as? String,
           !email.isEmpty {
            return email
        }

        if let accessToken = oauth["accessToken"] as? String,
           let payload = decodeJWTPayload(accessToken),
           let email = payload["email"] as? String ?? payload["preferred_username"] as? String ?? payload["upn"] as? String,
           !email.isEmpty {
            return email
        }

        if let accountId = oauth["accountId"] as? String, accountId.contains("@") {
            return accountId
        }

        return nil
    }

    private func normalizedSubscriptionLabel(rawType: String, scopes: [String]) -> String {
        let loweredRaw = rawType.lowercased()
        let inferredFromScopes = inferPlanFromScopes(scopes)

        if loweredRaw.contains("enterprise") { return "Enterprise" }
        if loweredRaw.contains("team") { return "Team" }
        if loweredRaw.contains("pro") { return "Pro" }
        if loweredRaw.contains("plus") { return "Plus" }
        if loweredRaw.contains("free") { return "Free" }

        if let inferred = inferredFromScopes {
            return inferred
        }

        if loweredRaw == "chatgpt" || loweredRaw == "oauth" || loweredRaw == "unknown" {
            return "ChatGPT"
        }

        if loweredRaw.isEmpty {
            return "ChatGPT"
        }

        return rawType.prefix(1).uppercased() + String(rawType.dropFirst())
    }

    private func inferPlanFromScopes(_ scopes: [String]) -> String? {
        let merged = scopes.joined(separator: " ").lowercased()

        if merged.contains("enterprise") { return "Enterprise" }
        if merged.contains("team") { return "Team" }
        if merged.contains("pro") { return "Pro" }
        if merged.contains("plus") { return "Plus" }
        if merged.contains("free") { return "Free" }

        return nil
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        let now = Date()
        if let cached = cacheQueue.sync(execute: { cachedTokenExpiries[jsonData] }),
           cached.expiresAt > now {
            return cached.expiry
        }

        let expiry: Date?
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["codexAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            expiry = nil
            cacheQueue.sync {
                pruneAuxCachesIfNeeded()
                cachedTokenExpiries[jsonData] = TokenExpiryCacheEntry(
                    expiry: expiry,
                    expiresAt: now.addingTimeInterval(tokenExpiryCacheTTL)
                )
            }
            return expiry
        }

        expiry = Date(timeIntervalSince1970: expiresAt)
        cacheQueue.sync {
            pruneAuxCachesIfNeeded()
            cachedTokenExpiries[jsonData] = TokenExpiryCacheEntry(
                expiry: expiry,
                expiresAt: now.addingTimeInterval(tokenExpiryCacheTTL)
            )
        }
        return expiry
    }

    /// Checks if the OAuth token in the credentials JSON is expired
    func isTokenExpired(_ jsonData: String) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry info = assume valid
            return false
        }
        return Date() > expiryDate
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles
    func resyncBeforeSwitching(for profileId: UUID) throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from system (if user is logged in)
        guard let freshJSON = try readSystemCredentials() else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        // Update profile's stored credentials with fresh ones
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            return
        }

        profiles[index].cliCredentialsJSON = freshJSON
        profiles[index].cliAccountSyncedAt = Date()  // Update sync timestamp
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("✓ Re-synced CLI credentials from system and updated timestamp")
    }

    private func storeSystemCredentialsCache(_ credentials: String?) {
        cacheQueue.sync {
            cachedSystemCredentials = CredentialsCacheEntry(
                credentials: credentials,
                expiresAt: Date().addingTimeInterval(credentialsCacheTTL)
            )
        }
    }

    private func clearSystemValidityCache() {
        cacheQueue.sync {
            cachedSystemValidity = nil
        }
    }

    private func pruneAuxCachesIfNeeded() {
        let now = Date()
        if cachedAccountSummaries.count > 64 {
            cachedAccountSummaries = cachedAccountSummaries.filter { $0.value.expiresAt > now }
        }
        if cachedTokenExpiries.count > 64 {
            cachedTokenExpiries = cachedTokenExpiries.filter { $0.value.expiresAt > now }
        }
    }

    private func refreshSystemValidityCacheInBackgroundIfNeeded(forceRefresh: Bool = false) {
        let shouldStart = cacheQueue.sync { () -> Bool in
            let now = Date()
            if isRefreshingValidityCache {
                return false
            }

            if !forceRefresh,
               now.timeIntervalSince(lastValidityRefreshStartAt) < minimumValidityRefreshInterval {
                return false
            }

            isRefreshingValidityCache = true
            lastValidityRefreshStartAt = now
            return true
        }

        guard shouldStart else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let isValid: Bool
            do {
                if let credentials = try self.readSystemCredentials(forceRefresh: forceRefresh) {
                    isValid = !self.isTokenExpired(credentials) && self.extractAccessToken(from: credentials) != nil
                } else {
                    isValid = false
                }
            } catch {
                isValid = false
            }

            self.cacheQueue.sync {
                self.cachedSystemValidity = ValidityCacheEntry(
                    isValid: isValid,
                    expiresAt: Date().addingTimeInterval(self.validityCacheTTL)
                )
                self.isRefreshingValidityCache = false
            }
        }
    }
}

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        if !isRunning {
            return true
        }

        let semaphore = DispatchSemaphore(value: 0)
        let previousHandler = terminationHandler
        terminationHandler = { process in
            previousHandler?(process)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if isRunning {
                terminate()
            }
            return false
        }

        return true
    }
}

// MARK: - CodexCodeError

enum CodexCodeError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    case keychainReadFailed(status: OSStatus)
    case keychainWriteFailed(status: OSStatus)
    case noProfileCredentials

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Codex CLI credentials found. Run 'codex login' and try sync again."
        case .invalidJSON:
            return "Codex Code credentials are corrupted or invalid."
        case .keychainReadFailed(let status):
            return "Failed to read credentials from system Keychain (status: \(status))."
        case .keychainWriteFailed(let status):
            return "Failed to write credentials to system Keychain (status: \(status))."
        case .noProfileCredentials:
            return "This profile has no synced CLI account."
        }
    }
}
