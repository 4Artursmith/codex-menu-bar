import Foundation

/// Service for fetching Codex system status
class CodexStatusService {
    private let statusURL: URL

    /// Response structure from Statuspage API
    private struct StatusResponse: Codable {
        let status: StatusDetail

        struct StatusDetail: Codable {
            let indicator: String
            let description: String
        }
    }

    // MARK: - Initialization

    init() {
        // Build URL safely with fallback to hardcoded URL
        if let url = try? URLBuilder.codexStatus(endpoint: "/status.json").build() {
            self.statusURL = url
        } else {
            // Fallback to hardcoded URL (should never happen, but prevents crashes)
            self.statusURL = URL(string: "https://status.openai.com/api/v2/status.json")!
        }
    }

    // MARK: - Status Fetching

    /// Fetch current Codex status
    func fetchStatus() async throws -> CodexStatus {
        // TESTING: Uncomment to test different status states
        // return CodexStatus(indicator: .none, description: "All Systems Operational")      // Green
        // return CodexStatus(indicator: .minor, description: "Minor Service Outage")        // Yellow
        // return CodexStatus(indicator: .major, description: "Major Service Outage")        // Orange
        // return CodexStatus(indicator: .critical, description: "Critical Service Outage")  // Red
        // return CodexStatus(indicator: .unknown, description: "Status Unknown")            // Gray

        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 10  // 10 second timeout

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(StatusResponse.self, from: data)

        // Map indicator string to enum
        let indicator: CodexStatus.StatusIndicator
        switch response.status.indicator {
        case "none":
            indicator = .none
        case "minor":
            indicator = .minor
        case "major":
            indicator = .major
        case "critical":
            indicator = .critical
        default:
            indicator = .unknown
        }

        return CodexStatus(indicator: indicator, description: response.status.description)
    }
}
