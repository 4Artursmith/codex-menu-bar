//
//  CodexCLILoginService.swift
//  Codex Usage
//
//  Created by Codex Code on 2026-02-07.
//

import Foundation

/// Starts interactive Codex CLI login flow for users who are not authorized yet.
final class CodexCLILoginService {
    static let shared = CodexCLILoginService()

    private init() {}

    /// Opens Terminal and runs `codex login` so the user can authorize in browser.
    @discardableResult
    func startLoginFlowInTerminal() -> Bool {
        startFlowInTerminal(command: "codex login")
    }

    /// Opens Terminal and forces switching to another account.
    @discardableResult
    func startSwitchAccountFlowInTerminal() -> Bool {
        startFlowInTerminal(command: "codex logout && codex login")
    }

    @discardableResult
    private func startFlowInTerminal(command: String) -> Bool {
        let escapedCommand = escapeForAppleScriptString(command)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "tell application \"Terminal\" to activate",
            "-e", "tell application \"Terminal\" to do script \"\(escapedCommand)\""
        ]

        do {
            try process.run()
            LoggingService.shared.log("CodexCLILoginService: Started '\(command)' flow in Terminal")
            return true
        } catch {
            LoggingService.shared.logError("CodexCLILoginService: Failed to launch 'codex login' flow: \(error.localizedDescription)")
            return false
        }
    }

    private func escapeForAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
