//
//  LoggingService.swift
//  Codex Usage
//
//  Created by Codex Code on 2025-12-20.
//

import Foundation
import os.log

/// Centralized logging service using os.log
/// Provides consistent logging across the application
final class LoggingService {
    static let shared = LoggingService()

    private let subsystem = Bundle.main.bundleIdentifier ?? "com.codexusage"
    private let verboseLoggingEnabled = false

    // Category-specific loggers
    private lazy var apiLogger = OSLog(subsystem: subsystem, category: "API")
    private lazy var storageLogger = OSLog(subsystem: subsystem, category: "Storage")
    private lazy var notificationLogger = OSLog(subsystem: subsystem, category: "Notifications")
    private lazy var uiLogger = OSLog(subsystem: subsystem, category: "UI")
    private lazy var generalLogger = OSLog(subsystem: subsystem, category: "General")

    private init() {}

    // MARK: - API Logging

    func logAPIRequest(_ endpoint: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("📤 API Request: %{public}@", log: apiLogger, type: .info, endpoint())
    }

    func logAPIResponse(_ endpoint: @autoclosure () -> String, statusCode: Int) {
        guard verboseLoggingEnabled else { return }
        os_log("📥 API Response: %{public}@ [%d]", log: apiLogger, type: .info, endpoint(), statusCode)
    }

    func logAPIError(_ endpoint: @autoclosure () -> String, error: Error) {
        guard verboseLoggingEnabled else { return }
        os_log("❌ API Error: %{public}@ - %{public}@", log: apiLogger, type: .error, endpoint(), error.localizedDescription)
    }

    // MARK: - Storage Logging

    func logStorageSave(_ key: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("💾 Storage Save: %{public}@", log: storageLogger, type: .debug, key())
    }

    func logStorageLoad(_ key: @autoclosure () -> String, success: Bool) {
        guard verboseLoggingEnabled else { return }
        if success {
            os_log("📂 Storage Load: %{public}@ ✓", log: storageLogger, type: .debug, key())
        } else {
            os_log("📂 Storage Load: %{public}@ ✗ (not found)", log: storageLogger, type: .debug, key())
        }
    }

    func logStorageError(_ operation: @autoclosure () -> String, error: Error) {
        os_log("❌ Storage Error [%{public}@]: %{public}@", log: storageLogger, type: .error, operation(), error.localizedDescription)
    }

    // MARK: - Notification Logging

    func logNotificationSent(_ type: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("🔔 Notification Sent: %{public}@", log: notificationLogger, type: .info, type())
    }

    func logNotificationError(_ error: Error) {
        os_log("❌ Notification Error: %{public}@", log: notificationLogger, type: .error, error.localizedDescription)
    }

    func logNotificationPermission(_ granted: Bool) {
        guard verboseLoggingEnabled else { return }
        os_log("🔐 Notification Permission: %{public}@", log: notificationLogger, type: .info, granted ? "Granted" : "Denied")
    }

    // MARK: - UI Logging

    func logUIEvent(_ event: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("🖱️ UI Event: %{public}@", log: uiLogger, type: .debug, event())
    }

    func logWindowEvent(_ event: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("🪟 Window Event: %{public}@", log: uiLogger, type: .debug, event())
    }

    // MARK: - General Logging

    func log(_ message: @autoclosure () -> String, type: OSLogType = .default) {
        guard verboseLoggingEnabled || type == .error || type == .fault else { return }
        os_log("%{public}@", log: generalLogger, type: type, message())
    }

    func logError(_ message: @autoclosure () -> String, error: Error? = nil) {
        if let error = error {
            os_log("❌ %{public}@: %{public}@", log: generalLogger, type: .error, message(), error.localizedDescription)
        } else {
            os_log("❌ %{public}@", log: generalLogger, type: .error, message())
        }
    }

    func logWarning(_ message: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("⚠️ %{public}@", log: generalLogger, type: .default, message())
    }

    func logInfo(_ message: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("ℹ️ %{public}@", log: generalLogger, type: .info, message())
    }

    func logDebug(_ message: @autoclosure () -> String) {
        guard verboseLoggingEnabled else { return }
        os_log("🐛 %{public}@", log: generalLogger, type: .debug, message())
    }
}
