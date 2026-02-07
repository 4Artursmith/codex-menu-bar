import Foundation

/// Service for fetching usage data directly from Codex's API
class CodexAPIService: APIServiceProtocol {
    // MARK: - Types

    /// Authentication method for API requests
    private enum AuthenticationType {
        case codexAISession(String)      // Cookie: sessionKey=...
        case cliOAuth(String)              // Authorization: Bearer ... (with openai-beta header)
        case consoleAPISession(String)     // Cookie: sessionKey=... (different endpoint)
    }

    // MARK: - Properties

    private let sessionKeyPath: URL
    private let sessionKeyValidator: SessionKeyValidator
    let baseURL = Constants.APIEndpoints.codexBase
    let consoleBaseURL = Constants.APIEndpoints.consoleBase

    // MARK: - Initialization

    init(sessionKeyPath: URL? = nil, sessionKeyValidator: SessionKeyValidator = SessionKeyValidator()) {
        // Default path: ~/.codex-session-key
        self.sessionKeyPath = sessionKeyPath ?? Constants.CodexPaths.homeDirectory
            .appendingPathComponent(".codex-session-key")
        self.sessionKeyValidator = sessionKeyValidator
    }

    // MARK: - Session Key Management

    /// Reads and validates the session key from active profile
    private func readSessionKey() throws -> String {
        do {
            // Load from active profile only
            guard let activeProfile = ProfileManager.shared.activeProfile else {
                LoggingService.shared.logError("CodexAPIService.readSessionKey: No active profile")
                throw AppError.sessionKeyNotFound()
            }

            LoggingService.shared.log("CodexAPIService.readSessionKey: Profile '\(activeProfile.name)'")
            LoggingService.shared.log("  - codexSessionKey: \(activeProfile.codexSessionKey == nil ? "NIL" : "EXISTS (len: \(activeProfile.codexSessionKey!.count))")")

            guard let key = activeProfile.codexSessionKey else {
                LoggingService.shared.logError("CodexAPIService.readSessionKey: Profile has NIL codexSessionKey - throwing sessionKeyNotFound")
                throw AppError.sessionKeyNotFound()
            }

            let validatedKey = try sessionKeyValidator.validate(key)
            LoggingService.shared.log("CodexAPIService.readSessionKey: Key validated successfully")
            return validatedKey

        } catch let error as SessionKeyValidationError {
            // Convert validation errors to AppError
            throw AppError.wrap(error)
        } catch let error as AppError {
            // Re-throw AppError as-is
            throw error
        } catch {
            let appError = AppError(
                code: .storageReadFailed,
                message: "Failed to read session key from profile",
                technicalDetails: error.localizedDescription,
                underlyingError: error,
                isRecoverable: true,
                recoverySuggestion: "Please check your session key configuration in the active profile"
            )
            ErrorLogger.shared.log(appError)
            throw appError
        }
    }

    /// Gets the best available authentication method with fallback support
    /// Priority: 1) codex.ai session → 2) saved CLI OAuth → 3) system Keychain CLI OAuth
    /// Note: Console API session is NOT used as fallback (it only provides billing data, not usage)
    private func getAuthentication() throws -> AuthenticationType {
        guard let activeProfile = ProfileManager.shared.activeProfile else {
            LoggingService.shared.logError("CodexAPIService.getAuthentication: No active profile")
            throw AppError.sessionKeyNotFound()
        }

        // Try codex.ai session key first
        if let sessionKey = activeProfile.codexSessionKey {
            do {
                let validatedKey = try sessionKeyValidator.validate(sessionKey)
                LoggingService.shared.log("CodexAPIService: Using codex.ai session key")
                return .codexAISession(validatedKey)
            } catch {
                LoggingService.shared.logError("CodexAPIService: codex.ai session key validation failed: \(error.localizedDescription)")
            }
        }

        // Fall back to saved CLI OAuth token if available and not expired
        if let cliJSON = activeProfile.cliCredentialsJSON {
            if !CodexCodeSyncService.shared.isTokenExpired(cliJSON),
               let accessToken = CodexCodeSyncService.shared.extractAccessToken(from: cliJSON) {
                LoggingService.shared.log("CodexAPIService: Falling back to saved CLI OAuth token")
                return .cliOAuth(accessToken)
            } else {
                LoggingService.shared.log("CodexAPIService: Saved CLI OAuth token is expired or invalid")
            }
        }

        // Fall back to reading CLI credentials directly from system Keychain
        do {
            if let systemCredentials = try CodexCodeSyncService.shared.readSystemCredentials() {
                LoggingService.shared.log("CodexAPIService: Found CLI credentials in system Keychain")

                // Validate token is not expired
                if CodexCodeSyncService.shared.isTokenExpired(systemCredentials) {
                    LoggingService.shared.log("CodexAPIService: System Keychain CLI token is expired")
                } else if let accessToken = CodexCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
                    LoggingService.shared.log("CodexAPIService: Using CLI credentials from system Keychain")
                    return .cliOAuth(accessToken)
                } else {
                    LoggingService.shared.log("CodexAPIService: Could not extract access token from system Keychain credentials")
                }
            } else {
                LoggingService.shared.log("CodexAPIService: No CLI credentials found in system Keychain")
            }
        } catch {
            LoggingService.shared.log("CodexAPIService: Could not read system CLI credentials: \(error.localizedDescription)")
        }

        LoggingService.shared.logError("CodexAPIService.getAuthentication: No valid credentials for usage data")
        throw AppError.sessionKeyNotFound()
    }

    /// Builds an authenticated request with the appropriate headers for the auth type
    private func buildAuthenticatedRequest(url: URL, auth: AuthenticationType) -> URLRequest {
        var request = URLRequest(url: url)

        switch auth {
        case .codexAISession(let sessionKey):
            // Existing codex.ai authentication
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

        case .cliOAuth(let accessToken):
            // CLI OAuth authentication (requires specific headers)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("codex-code/2.1.5", forHTTPHeaderField: "User-Agent")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "openai-beta")

        case .consoleAPISession(let apiKey):
            // Console API authentication
            request.setValue("sessionKey=\(apiKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        return request
    }

    /// Saves a session key with smart org ID preservation
    /// Only clears org ID if the key actually changed
    func saveSessionKey(_ key: String, preserveOrgIfUnchanged: Bool = true) throws {
        do {
            // Validate the key before saving
            let validatedKey = try sessionKeyValidator.validate(key)

            guard let profileId = ProfileManager.shared.activeProfile?.id else {
                throw AppError(
                    code: .storageWriteFailed,
                    message: "No active profile found",
                    technicalDetails: "Cannot save session key without an active profile",
                    isRecoverable: true,
                    recoverySuggestion: "Please ensure a profile is active"
                )
            }

            // Check if key actually changed (for smart org clearing)
            var shouldClearOrg = true
            if preserveOrgIfUnchanged {
                let existingKey = ProfileManager.shared.activeProfile?.codexSessionKey
                shouldClearOrg = (existingKey != validatedKey)
            }

            // Save to active profile
            var credentials = (try? ProfileManager.shared.loadCredentials(for: profileId)) ?? ProfileCredentials()
            credentials.codexSessionKey = validatedKey
            try ProfileManager.shared.saveCredentials(for: profileId, credentials: credentials)

            LoggingService.shared.log("Session key saved to active profile")

            // Only clear org ID if key actually changed
            if shouldClearOrg {
                clearOrganizationIdCache()
                ProfileManager.shared.updateOrganizationId(nil, for: profileId)
                LoggingService.shared.log("Session key changed - cleared organization ID")
            } else {
                LoggingService.shared.log("Session key unchanged - preserving organization ID")
            }

        } catch let error as SessionKeyValidationError {
            // Convert validation errors to AppError
            throw AppError.wrap(error)
        } catch {
            // Keychain errors
            let appError = AppError(
                code: .sessionKeyStorageFailed,
                message: "Failed to save session key",
                technicalDetails: error.localizedDescription,
                underlyingError: error,
                isRecoverable: true,
                recoverySuggestion: "Please check Keychain access and try again"
            )
            ErrorLogger.shared.log(appError)
            throw appError
        }
    }

    // MARK: - Organization ID Caching

    /// Cache organization ID to reduce API calls
    private var cachedOrgId: String?
    private var cachedOrgIdSessionKey: String?
    private struct CachedLocalCLILogUsage {
        let usage: CodexUsage
        let sourcePath: String
        let sourceModifiedAt: Date
        let cachedAt: Date
    }
    private var cachedLocalCLILogUsage: CachedLocalCLILogUsage?
    private let localCLILogUsageCacheTTL: TimeInterval = 20

    /// Clears the cached organization ID (call when session key changes)
    func clearOrganizationIdCache() {
        cachedOrgId = nil
        cachedOrgIdSessionKey = nil
    }

    // MARK: - API Requests

    /// Fetches all organizations for the authenticated user
    func fetchAllOrganizations(sessionKey: String? = nil) async throws -> [AccountInfo] {
        return try await ErrorRecovery.shared.executeWithRetry(maxAttempts: 3) {
            let sessionKey = try sessionKey ?? self.readSessionKey()

            // Build URL safely
            let url: URL
            do {
                url = try URLBuilder(baseURL: self.baseURL)
                    .appendingPath("/organizations")
                    .build()
            } catch {
                throw AppError.wrap(error)
            }

            var request = URLRequest(url: url)
            request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpMethod = "GET"
            request.timeoutInterval = 30

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                // Network errors
                let appError = AppError(
                    code: .networkGenericError,
                    message: "Failed to connect to Codex API",
                    technicalDetails: error.localizedDescription,
                    underlyingError: error,
                    isRecoverable: true,
                    recoverySuggestion: "Please check your internet connection and try again"
                )
                ErrorLogger.shared.log(appError)
                throw appError
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError(
                    code: .apiInvalidResponse,
                    message: "Invalid response from server",
                    isRecoverable: true
                )
            }

            switch httpResponse.statusCode {
            case 200:
                // Parse organizations array
                do {
                    let organizations = try JSONDecoder().decode([AccountInfo].self, from: data)
                    guard !organizations.isEmpty else {
                        throw AppError(
                            code: .apiParsingFailed,
                            message: "No organizations found",
                            technicalDetails: "Organizations array is empty",
                            isRecoverable: false,
                            recoverySuggestion: "Please ensure your Codex account has access to organizations"
                        )
                    }

                    // Log all available organizations for debugging
                    LoggingService.shared.logInfo("Found \(organizations.count) organization(s):")
                    for (index, org) in organizations.enumerated() {
                        LoggingService.shared.logInfo("  [\(index)] \(org.name) (ID: \(org.uuid))")
                    }

                    return organizations
                } catch {
                    let appError = AppError(
                        code: .apiParsingFailed,
                        message: "Failed to parse organizations",
                        technicalDetails: error.localizedDescription,
                        underlyingError: error,
                        isRecoverable: false
                    )
                    ErrorLogger.shared.log(appError)
                    throw appError
                }

            case 401, 403:
                throw AppError.apiUnauthorized()

            case 429:
                throw AppError.apiRateLimited()

            case 500...599:
                throw AppError.apiServerError(statusCode: httpResponse.statusCode)

            default:
                throw AppError(
                    code: .apiGenericError,
                    message: "Unexpected API response",
                    technicalDetails: "HTTP \(httpResponse.statusCode)",
                    isRecoverable: true
                )
            }
        }
    }

    // MARK: - Read-Only Testing

    /// Tests a session key without saving to Keychain
    /// Returns available organizations if successful
    func testSessionKey(_ key: String) async throws -> [AccountInfo] {
        // Validate using professional validator
        let validatedKey = try sessionKeyValidator.validate(key)

        // Fetch organizations using the test key (don't save it)
        let organizations = try await fetchAllOrganizations(sessionKey: validatedKey)

        LoggingService.shared.logInfo("Tested session key - found \(organizations.count) organization(s)")

        return organizations
    }

    /// Fetches the organization ID for the authenticated user
    /// Uses stored org ID if available, otherwise fetches all orgs and auto-selects
    func fetchOrganizationId(sessionKey: String? = nil) async throws -> String {
        let sessionKey = try sessionKey ?? self.readSessionKey()

        // Check for stored organization ID in active profile first
        if let storedOrgId = ProfileManager.shared.activeProfile?.organizationId {
            LoggingService.shared.logInfo("Using stored organization ID from profile: \(storedOrgId)")
            return storedOrgId
        }

        // No stored org ID - fetch all organizations
        LoggingService.shared.logInfo("No stored organization ID - fetching all organizations")
        let organizations = try await fetchAllOrganizations(sessionKey: sessionKey)

        // Auto-select organization (prefer first one for now - user can change later)
        let selectedOrg = organizations.first!
        LoggingService.shared.logInfo("Auto-selected organization: \(selectedOrg.name) (ID: \(selectedOrg.uuid))")

        // Store the selected org ID in active profile
        if let profileId = ProfileManager.shared.activeProfile?.id {
            ProfileManager.shared.updateOrganizationId(selectedOrg.uuid, for: profileId)
        }

        return selectedOrg.uuid
    }

    /// Fetches usage data for a specific profile using provided credentials
    /// - Parameters:
    ///   - sessionKey: The Codex.ai session key
    ///   - organizationId: The organization ID
    /// - Returns: CodexUsage data for the profile
    func fetchUsageData(sessionKey: String, organizationId: String) async throws -> CodexUsage {
        let usageData = try await performRequest(endpoint: "/organizations/\(organizationId)/usage", sessionKey: sessionKey)
        return try parseUsageResponse(usageData)
    }

    /// Fetches usage data for a specific profile.
    /// Prefers profile-specific credentials and falls back to valid system CLI OAuth.
    func fetchUsageData(for profile: Profile) async throws -> CodexUsage {
        // Profile-specific codex.ai credentials (legacy/manual)
        if let sessionKey = profile.codexSessionKey,
           let organizationId = profile.organizationId {
            return try await fetchUsageData(sessionKey: sessionKey, organizationId: organizationId)
        }

        // Profile-specific CLI OAuth credentials (preferred)
        if let cliJSON = profile.cliCredentialsJSON,
           !CodexCodeSyncService.shared.isTokenExpired(cliJSON),
           let accessToken = CodexCodeSyncService.shared.extractAccessToken(from: cliJSON) {
            return try await fetchUsageDataWithOAuthToken(accessToken)
        }

        // Fallback: currently logged-in system CLI credentials
        if let systemCredentials = try? CodexCodeSyncService.shared.readSystemCredentials(),
           !CodexCodeSyncService.shared.isTokenExpired(systemCredentials),
           let accessToken = CodexCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
            return try await fetchUsageDataWithOAuthToken(accessToken)
        }

        throw AppError(
            code: .sessionKeyNotFound,
            message: "No valid credentials for usage data",
            technicalDetails: "Profile '\(profile.name)' has no valid CLI OAuth or session credentials",
            isRecoverable: true,
            recoverySuggestion: "Run 'codex login' in terminal and sync in Settings > CLI Account"
        )
    }

    /// Fetches real usage data from Codex's API
    func fetchUsageData() async throws -> CodexUsage {
        let auth = try getAuthentication()

        switch auth {
        case .codexAISession(let sessionKey):
            // Use existing codex.ai flow
            let orgId = try await fetchOrganizationId(sessionKey: sessionKey)

            async let usageDataTask = performRequest(endpoint: "/organizations/\(orgId)/usage", sessionKey: sessionKey)

            // Use active profile's checkOverageLimitEnabled setting
            let checkOverage = ProfileManager.shared.activeProfile?.checkOverageLimitEnabled ?? true
            async let overageDataTask: Data? = checkOverage ? performRequest(endpoint: "/organizations/\(orgId)/overage_spend_limit", sessionKey: sessionKey) : nil

            let usageData = try await usageDataTask
            var codexUsage = try parseUsageResponse(usageData)

            if checkOverage,
               let data = try? await overageDataTask,
               let overage = try? JSONDecoder().decode(OverageSpendLimitResponse.self, from: data),
               overage.isEnabled == true {
                codexUsage.costUsed = overage.usedCredits
                codexUsage.costLimit = overage.monthlyCreditLimit
                codexUsage.costCurrency = overage.currency
            }

            return codexUsage

        case .cliOAuth(let accessToken):
            return try await fetchUsageDataWithOAuthToken(accessToken)

        case .consoleAPISession:
            // Console API is for billing/credits only, not usage data
            throw AppError(
                code: .sessionKeyNotFound,
                message: "No valid credentials for usage data",
                technicalDetails: "Console API only provides billing data, not usage statistics",
                isRecoverable: true,
                recoverySuggestion: "Please add a codex.ai session key or sync your CLI account"
            )
        }
    }

    private func fetchUsageDataWithOAuthToken(_ accessToken: String) async throws -> CodexUsage {
        LoggingService.shared.log("CodexAPIService: Fetching usage via OAuth endpoint")

        do {
            guard let url = URL(string: "https://api.openai.com/api/oauth/usage") else {
                throw AppError(
                    code: .urlMalformed,
                    message: "Invalid OAuth usage endpoint",
                    isRecoverable: false
                )
            }

            var request = buildAuthenticatedRequest(url: url, auth: .cliOAuth(accessToken))
            request.httpMethod = "GET"
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppError(
                    code: .apiInvalidResponse,
                    message: "Invalid response from OAuth endpoint",
                    isRecoverable: true
                )
            }

            guard httpResponse.statusCode == 200 else {
                let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
                throw AppError(
                    code: .apiUnauthorized,
                    message: "OAuth authentication failed",
                    technicalDetails: "Status: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                    isRecoverable: true,
                    recoverySuggestion: "Please run 'codex login' and re-sync your CLI account"
                )
            }

            return try parseUsageResponse(data)
        } catch {
            LoggingService.shared.logWarning("CodexAPIService: OAuth usage endpoint unavailable, falling back to local Codex session logs (\(error.localizedDescription))")
            do {
                return try fetchUsageDataFromLocalCLISessions()
            } catch {
                LoggingService.shared.logWarning("CodexAPIService: Local CLI session parsing unavailable (\(error.localizedDescription)). Using last known usage instead.")
                return fallbackUsageFromProfileOrEmpty()
            }
        }
    }

    // MARK: - CLI Session Log Fallback

    /// Fallback usage source when remote OAuth usage endpoint is unavailable.
    /// Reads the latest token_count rate limits from local Codex CLI session logs.
    private func fetchUsageDataFromLocalCLISessions() throws -> CodexUsage {
        let sessionsDirectory = Constants.CodexPaths.codexDirectory.appendingPathComponent("sessions")
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: sessionsDirectory.path) else {
            throw AppError(
                code: .storageReadFailed,
                message: "Codex CLI sessions not found",
                technicalDetails: "Missing directory: \(sessionsDirectory.path)",
                isRecoverable: true,
                recoverySuggestion: "Run at least one Codex CLI command, then refresh"
            )
        }

        let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            throw AppError(
                code: .storageReadFailed,
                message: "Unable to scan Codex CLI sessions",
                technicalDetails: "Failed to create directory enumerator",
                isRecoverable: true
            )
        }

        var filesByDate: [(url: URL, date: Date)] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  fileURL.lastPathComponent.hasPrefix("rollout-") else {
                continue
            }

            let values = try? fileURL.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile == true,
                  let modifiedAt = values?.contentModificationDate else {
                continue
            }

            filesByDate.append((url: fileURL, date: modifiedAt))
        }

        guard !filesByDate.isEmpty else {
            throw AppError(
                code: .storageReadFailed,
                message: "No Codex CLI session logs found",
                technicalDetails: "No rollout-*.jsonl files under \(sessionsDirectory.path)",
                isRecoverable: true,
                recoverySuggestion: "Run Codex CLI first, then refresh"
            )
        }

        let sortedFiles = filesByDate.sorted { $0.date > $1.date }

        if let newestFile = sortedFiles.first,
           let cachedUsage = cachedLocalUsageIfValid(sourcePath: newestFile.url.path, sourceModifiedAt: newestFile.date) {
            return cachedUsage
        }

        var scannedFiles = 0
        for fileEntry in sortedFiles.prefix(12) {
            scannedFiles += 1
            if let snapshot = try parseLatestRateLimits(from: fileEntry.url) {
                let usage = usageFromRateLimitSnapshot(snapshot)
                storeLocalUsageCache(usage, sourcePath: fileEntry.url.path, sourceModifiedAt: fileEntry.date)
                return usage
            }
        }

        if let cached = cachedLocalCLILogUsage {
            return cached.usage
        }

        throw AppError(
            code: .apiParsingFailed,
            message: "Failed to parse Codex CLI usage",
            technicalDetails: "No token_count/rate_limits entries in latest \(scannedFiles) rollout logs",
            isRecoverable: true
        )
    }

    private func usageFromRateLimitSnapshot(_ snapshot: CLIRateLimitSnapshot) -> CodexUsage {
        let weeklyLimit = Constants.weeklyLimit
        let weeklyTokens = Int(Double(weeklyLimit) * (snapshot.weeklyUsedPercent / 100.0))

        return CodexUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: snapshot.sessionUsedPercent,
            sessionResetTime: snapshot.sessionResetTime,
            weeklyTokensUsed: weeklyTokens,
            weeklyLimit: weeklyLimit,
            weeklyPercentage: snapshot.weeklyUsedPercent,
            weeklyResetTime: snapshot.weeklyResetTime,
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }

    private func fallbackUsageFromProfileOrEmpty() -> CodexUsage {
        if let cachedUsage = ProfileManager.shared.activeProfile?.codexUsage {
            return cachedUsage
        }
        return .empty
    }

    private func cachedLocalUsageIfValid(sourcePath: String, sourceModifiedAt: Date) -> CodexUsage? {
        guard let cached = cachedLocalCLILogUsage else {
            return nil
        }

        let isFresh = Date().timeIntervalSince(cached.cachedAt) <= localCLILogUsageCacheTTL
        guard isFresh,
              cached.sourcePath == sourcePath,
              cached.sourceModifiedAt == sourceModifiedAt else {
            return nil
        }

        return cached.usage
    }

    private func storeLocalUsageCache(_ usage: CodexUsage, sourcePath: String, sourceModifiedAt: Date) {
        cachedLocalCLILogUsage = CachedLocalCLILogUsage(
            usage: usage,
            sourcePath: sourcePath,
            sourceModifiedAt: sourceModifiedAt,
            cachedAt: Date()
        )
    }

    private func parseRateLimits(from payload: [String: Any]) -> [String: Any]? {
        if let direct = payload["rate_limits"] as? [String: Any] {
            return direct
        }

        if let info = payload["info"] as? [String: Any],
           let nested = info["rate_limits"] as? [String: Any] {
            return nested
        }

        return nil
    }

    private func parseLatestRateLimits(from fileURL: URL) throws -> CLIRateLimitSnapshot? {
        let data = try Data(contentsOf: fileURL)
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        var latestSnapshot: CLIRateLimitSnapshot?

        for line in content.split(whereSeparator: \.isNewline) {
            guard let lineData = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = root["type"] as? String,
                  type == "event_msg" || type == "event",
                  let payload = root["payload"] as? [String: Any],
                  let rateLimits = parseRateLimits(from: payload),
                  let primary = rateLimits["primary"] as? [String: Any],
                  let secondary = rateLimits["secondary"] as? [String: Any] else {
                continue
            }

            let sessionUsed = parseDouble(primary["used_percent"]) ?? 0
            let weeklyUsed = parseDouble(secondary["used_percent"]) ?? 0

            let sessionReset = parseTimestamp(primary["resets_at"]) ?? Date().addingTimeInterval(5 * 60 * 60)
            let weeklyReset = parseTimestamp(secondary["resets_at"]) ?? Date().nextMonday1259pm()

            latestSnapshot = CLIRateLimitSnapshot(
                sessionUsedPercent: sessionUsed,
                sessionResetTime: sessionReset,
                weeklyUsedPercent: weeklyUsed,
                weeklyResetTime: weeklyReset
            )
        }

        return latestSnapshot
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private func parseTimestamp(_ value: Any?) -> Date? {
        if let seconds = parseDouble(value) {
            return Date(timeIntervalSince1970: seconds)
        }

        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) {
                return date
            }

            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) {
                return date
            }
        }

        return nil
    }

    /*
     Old parser implementation was replaced with a more fault-tolerant variant above.
     It used only the newest file and strict payload checks, causing false parse errors.
     */
    private struct CLIRateLimitSnapshot {
        let sessionUsedPercent: Double
        let sessionResetTime: Date
        let weeklyUsedPercent: Double
        let weeklyResetTime: Date
    }

    private func performRequest(endpoint: String, sessionKey: String) async throws -> Data {
        // Build URL safely
        let url = try URLBuilder(baseURL: baseURL)
            .appendingPath(endpoint)
            .build()

        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpMethod = "GET"
        request.timeoutInterval = 30

        LoggingService.shared.logAPIRequest(endpoint)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Network-level errors
            LoggingService.shared.logAPIError(endpoint, error: error)
            let appError = AppError(
                code: .networkGenericError,
                message: "Failed to connect to Codex API",
                technicalDetails: "Endpoint: \(endpoint)\nError: \(error.localizedDescription)",
                underlyingError: error,
                isRecoverable: true,
                recoverySuggestion: "Please check your internet connection and try again"
            )
            throw appError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError(
                code: .apiInvalidResponse,
                message: "Invalid response from server",
                technicalDetails: "Endpoint: \(endpoint)",
                isRecoverable: true
            )
        }

        LoggingService.shared.logAPIResponse(endpoint, statusCode: httpResponse.statusCode)

        // Log raw response if debug logging is enabled
        if DataStore.shared.loadDebugAPILoggingEnabled() {
            if let responseString = String(data: data, encoding: .utf8) {
                // Truncate to first 500 chars to avoid huge logs
                let truncated = responseString.prefix(500)
                LoggingService.shared.logDebug("API Response [\(endpoint)]: \(truncated)...")
            }
        }

        switch httpResponse.statusCode {
        case 200:
            return data

        case 401, 403:
            // Include response body in error for debugging
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            throw AppError(
                code: .apiUnauthorized,
                message: "Unauthorized. Your session key may have expired.",
                technicalDetails: "Endpoint: \(endpoint)\nStatus: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                isRecoverable: true,
                recoverySuggestion: "Please update your session key in Settings"
            )

        case 429:
            throw AppError(
                code: .apiRateLimited,
                message: "Rate limited by Codex API",
                technicalDetails: "Endpoint: \(endpoint)",
                isRecoverable: true,
                recoverySuggestion: "Please wait a few minutes before trying again"
            )

        case 500...599:
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            throw AppError(
                code: .apiServerError,
                message: "Codex API server error",
                technicalDetails: "Endpoint: \(endpoint)\nStatus: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                isRecoverable: true,
                recoverySuggestion: "Please try again later"
            )

        default:
            let responsePreview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to read response"
            throw AppError(
                code: .apiGenericError,
                message: "Unexpected API response",
                technicalDetails: "Endpoint: \(endpoint)\nStatus: \(httpResponse.statusCode)\nResponse: \(responsePreview)",
                isRecoverable: true
            )
        }
    }

    // MARK: - Response Parsing

    private func parseUsageResponse(_ data: Data) throws -> CodexUsage {
        // Parse Codex's actual API response structure

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Extract session usage (five_hour)
            var sessionPercentage = 0.0
            var sessionResetTime = Date().addingTimeInterval(5 * 3600)
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let utilization = fiveHour["utilization"] {
                    sessionPercentage = parseUtilization(utilization)
                }
                if let resetsAt = fiveHour["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    sessionResetTime = formatter.date(from: resetsAt) ?? sessionResetTime
                }
            }

            // Extract weekly usage (seven_day)
            var weeklyPercentage = 0.0
            var weeklyResetTime = Date().nextMonday1259pm()
            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let utilization = sevenDay["utilization"] {
                    weeklyPercentage = parseUtilization(utilization)
                }
                if let resetsAt = sevenDay["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    weeklyResetTime = formatter.date(from: resetsAt) ?? weeklyResetTime
                }
            }

            // Extract Opus weekly usage (seven_day_opus)
            var opusPercentage = 0.0
            if let sevenDayOpus = json["seven_day_opus"] as? [String: Any] {
                if let utilization = sevenDayOpus["utilization"] {
                    opusPercentage = parseUtilization(utilization)
                }
            }

            // Extract Sonnet weekly usage (seven_day_sonnet)
            var sonnetPercentage = 0.0
            var sonnetResetTime: Date? = nil
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                if let utilization = sevenDaySonnet["utilization"] {
                    sonnetPercentage = parseUtilization(utilization)
                }
                if let resetsAt = sevenDaySonnet["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    sonnetResetTime = formatter.date(from: resetsAt)
                }
            }

            // We don't know user's plan, so we use 0 for limits we can't determine
            let weeklyLimit = Constants.weeklyLimit

            // Calculate token counts from percentages (using weekly limit as reference)
            let sessionTokens = 0  // Can't calculate without knowing plan
            let sessionLimit = 0   // Unknown without plan
            let weeklyTokens = Int(Double(weeklyLimit) * (weeklyPercentage / 100.0))
            let opusTokens = Int(Double(weeklyLimit) * (opusPercentage / 100.0))
            let sonnetTokens = Int(Double(weeklyLimit) * (sonnetPercentage / 100.0))

            let usage = CodexUsage(
                sessionTokensUsed: sessionTokens,
                sessionLimit: sessionLimit,
                sessionPercentage: sessionPercentage,
                sessionResetTime: sessionResetTime,
                weeklyTokensUsed: weeklyTokens,
                weeklyLimit: weeklyLimit,
                weeklyPercentage: weeklyPercentage,
                weeklyResetTime: weeklyResetTime,
                opusWeeklyTokensUsed: opusTokens,
                opusWeeklyPercentage: opusPercentage,
                sonnetWeeklyTokensUsed: sonnetTokens,
                sonnetWeeklyPercentage: sonnetPercentage,
                sonnetWeeklyResetTime: sonnetResetTime,
                costUsed: nil,
                costLimit: nil,
                costCurrency: nil,
                lastUpdated: Date(),
                userTimezone: .current
            )

            return usage
        }

        // Log the actual response for debugging
        if DataStore.shared.loadDebugAPILoggingEnabled() {
            if let responseString = String(data: data, encoding: .utf8) {
                LoggingService.shared.logDebug("Failed to parse usage response: \(responseString)")
            }
        }

        throw AppError(
            code: .apiParsingFailed,
            message: "Failed to parse usage data",
            technicalDetails: "Unable to parse JSON response structure",
            isRecoverable: false,
            recoverySuggestion: "Please check the error log and report this issue"
        )
    }

    // MARK: - Parsing Helpers

    /// Robust utilization parser that handles Int, Double, or String types
    /// - Parameter value: The utilization value from API (can be Int, Double, or String)
    /// - Returns: Parsed percentage as Double, or 0.0 if parsing fails
    private func parseUtilization(_ value: Any) -> Double {
        // Try Int first (most common)
        if let intValue = value as? Int {
            return Double(intValue)
        }

        // Try Double
        if let doubleValue = value as? Double {
            return doubleValue
        }

        // Try String
        if let stringValue = value as? String {
            // Remove any percentage symbols or whitespace
            let cleaned = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")

            if let parsed = Double(cleaned) {
                return parsed
            }
        }

        // Log warning if we couldn't parse
        LoggingService.shared.logWarning("Failed to parse utilization value: \(value) (type: \(type(of: value)))")
        return 0.0
    }

    // MARK: - Session Initialization

    /// Sends a minimal message to Codex to initialize a new session
    /// Uses Codex 3.5 Haiku (cheapest model)
    /// Creates a temporary conversation that is deleted after initialization to avoid cluttering chat history
    func sendInitializationMessage() async throws {
        let sessionKey = try readSessionKey()
        let orgId = try await fetchOrganizationId(sessionKey: sessionKey)

        // Create a new conversation
        let conversationURL = try URLBuilder(baseURL: baseURL)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations"])
            .build()

        var conversationRequest = URLRequest(url: conversationURL)
        conversationRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        conversationRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        conversationRequest.httpMethod = "POST"

        let conversationBody: [String: Any] = [
            "uuid": UUID().uuidString.lowercased(),
            "name": ""
        ]
        conversationRequest.httpBody = try JSONSerialization.data(withJSONObject: conversationBody)

        let (conversationData, conversationResponse) = try await URLSession.shared.data(for: conversationRequest)

        guard let httpResponse = conversationResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            throw APIError.serverError(statusCode: httpResponse.statusCode)
        }

        // Parse conversation UUID
        guard let json = try? JSONSerialization.jsonObject(with: conversationData) as? [String: Any],
              let conversationUUID = json["uuid"] as? String else {
            throw APIError.invalidResponse
        }

        // Send a minimal "Hi" message to initialize the session
        let messageURL = try URLBuilder(baseURL: baseURL)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations", conversationUUID, "/completion"])
            .build()

        var messageRequest = URLRequest(url: messageURL)
        messageRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        messageRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        messageRequest.httpMethod = "POST"

        let messageBody: [String: Any] = [
            "prompt": "Hi",
            "model": "codex-haiku-4-5-20251001",
            "timezone": "UTC"
        ]
        messageRequest.httpBody = try JSONSerialization.data(withJSONObject: messageBody)

        let (_, messageResponse) = try await URLSession.shared.data(for: messageRequest)

        guard let messageHTTPResponse = messageResponse as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard messageHTTPResponse.statusCode == 200 else {
            throw APIError.serverError(statusCode: messageHTTPResponse.statusCode)
        }

        // Delete the conversation to keep it out of chat history (incognito mode)
        let deleteURL = try URLBuilder(baseURL: baseURL)
            .appendingPathComponents(["/organizations", orgId, "/chat_conversations", conversationUUID])
            .build()

        var deleteRequest = URLRequest(url: deleteURL)
        deleteRequest.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        deleteRequest.httpMethod = "DELETE"

        // Attempt to delete, but don't fail if deletion fails
        // The session is already initialized, which is the primary goal
        do {
            let (_, deleteResponse) = try await URLSession.shared.data(for: deleteRequest)
            if let deleteHTTPResponse = deleteResponse as? HTTPURLResponse {
                // Successfully deleted conversation - status code 200 or 204 expected
                _ = deleteHTTPResponse.statusCode
            }
        } catch {
            // Silently ignore deletion errors - session is already initialized
        }
    }

}
