//
//  APIServiceProtocol.swift
//  Codex Usage
//
//  Created by Codex Code on 2025-12-20.
//

import Foundation

/// Protocol defining API operations for Codex services
/// Enables dependency injection and testing with mock API services
protocol APIServiceProtocol {
    // MARK: - Session Key Management
    func saveSessionKey(_ key: String, preserveOrgIfUnchanged: Bool) throws

    // MARK: - Codex.ai API
    func fetchOrganizationId(sessionKey: String?) async throws -> String
    func fetchUsageData() async throws -> CodexUsage
    func sendInitializationMessage() async throws

    // MARK: - Console API
    func fetchConsoleOrganizations(apiSessionKey: String) async throws -> [APIOrganization]
    func fetchAPIUsageData(organizationId: String, apiSessionKey: String) async throws -> APIUsage
}
