//
//  SchedulerAdminAPI.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Foundation
import Security

struct SchedulerAccount: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let hasPassword: Bool
}

struct AccountsResponse: Codable {
    let accounts: [SchedulerAccount]
}

struct AccountAuthResponse: Codable {
    let account: SchedulerAccount
    let token: String
}

struct CreateAccountResponse: Codable {
    let account: SchedulerAccount
    let accounts: [SchedulerAccount]
    let token: String
}

struct DeleteAccountResponse: Codable {
    let account: SchedulerAccount
    let accounts: [SchedulerAccount]
}

struct WhatsAppAdminState: Codable {
    let account: SchedulerAccount?
    let status: String
    let qrDataUrl: String?
    let chats: [WhatsAppAdminChat]
    let error: String?
}

struct WhatsAppAdminChat: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isGroup: Bool
}

struct AdminErrorResponse: Codable {
    let error: String?
}

struct SchedulerHealth: Codable {
    let status: String
    let engineVersion: String
    let minimumIOSVersion: String?
    let nodeVersion: String
    let startedAt: String
    let uptimeSeconds: Int
    let serverTime: String
    let totalAccounts: Int
    let connectedAccounts: Int
    let activeSessions: Int
}

enum SchedulerAdminError: LocalizedError {
    case invalidURL
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Scheduler admin URL is invalid."
        case let .http(status, message):
            return message.isEmpty ? "Admin API returned HTTP \(status)." : message
        }
    }
}

struct SchedulerAdminAPI {
    var baseURL: URL
    var accountId: String
    var token: String

    func accounts() async throws -> [SchedulerAccount] {
        let response: AccountsResponse = try await request(path: "/api/accounts")
        return response.accounts
    }

    func health() async throws -> SchedulerHealth {
        try await request(path: "/api/health")
    }

    func login(password: String) async throws -> AccountAuthResponse {
        try await request(
            path: "/api/accounts/auth",
            method: "POST",
            body: ["account": accountId, "password": password]
        )
    }

    func createAccount(name: String, password: String) async throws -> CreateAccountResponse {
        try await request(path: "/api/accounts", method: "POST", body: ["name": name, "password": password])
    }

    func deleteAccount() async throws -> DeleteAccountResponse {
        try await request(path: "/api/accounts", method: "DELETE", query: ["account": accountId], authorized: true)
    }

    func whatsAppStatus() async throws -> WhatsAppAdminState {
        try await request(path: "/api/whatsapp", query: ["account": accountId], authorized: true)
    }

    func logoutWhatsApp() async throws -> WhatsAppAdminState {
        try await request(path: "/api/whatsapp/logout", method: "POST", query: ["account": accountId], authorized: true)
    }

    func config() async throws -> ConfigResponse {
        try await request(path: "/api/config", query: ["account": accountId], authorized: true)
    }

    func logs() async throws -> [SchedulerLogEntry] {
        let response: LogsResponse = try await request(path: "/api/logs", query: ["account": accountId], authorized: true)
        return response.logs
    }

    func patrolState() async throws -> PatrolStateResponse {
        try await request(path: "/api/patrol/state", query: ["account": accountId], authorized: true)
    }

    func updatePatrolState(_ state: PatrolStateUpdateRequest) async throws -> PatrolStateResponse {
        try await request(
            path: "/api/patrol/state",
            method: "PUT",
            query: ["account": accountId],
            body: state,
            authorized: true
        )
    }

    func importLegacyPatrolState(_ state: PatrolImportRequest) async throws -> PatrolStateResponse {
        try await request(
            path: "/api/patrol/import",
            method: "POST",
            query: ["account": accountId],
            body: state,
            authorized: true
        )
    }

    func sendLocation(_ location: PatrolLocationRequest) async throws -> PatrolLocationResponse {
        try await request(
            path: "/api/patrol/location",
            method: "POST",
            query: ["account": accountId],
            body: location,
            authorized: true
        )
    }

    func sendPatrolEvent(_ event: PatrolEventRequest) async throws -> PatrolActionResponse {
        try await request(
            path: "/api/patrol/events",
            method: "POST",
            query: ["account": accountId],
            body: event,
            authorized: true
        )
    }

    func retryPatrolEvents() async throws -> PatrolRetryResponse {
        try await request(
            path: "/api/patrol/events/retry",
            method: "POST",
            query: ["account": accountId],
            body: [String: String](),
            authorized: true
        )
    }

    func updateConfig(_ config: PatrolConfig) async throws -> ConfigResponse {
        try await request(
            path: "/api/config",
            method: "PUT",
            query: ["account": accountId],
            body: ConfigUpdateRequest(config: config),
            authorized: true
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        body: Body? = Optional<String>.none,
        authorized: Bool = false
    ) async throws -> Response {
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let endpoint = URL(string: "\(base)\(normalizedPath)"),
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SchedulerAdminError.invalidURL
        }

        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw SchedulerAdminError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Account-Auth")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let decoded = try? JSONDecoder().decode(AdminErrorResponse.self, from: data)
            throw SchedulerAdminError.http(
                status: httpResponse.statusCode,
                message: decoded?.error ?? String(data: data, encoding: .utf8) ?? ""
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        authorized: Bool = false
    ) async throws -> Response {
        let emptyBody: String? = nil
        return try await request(path: path, method: method, query: query, body: emptyBody, authorized: authorized)
    }
}

enum KeychainStore {
    static func token(accountId: String) -> String {
        guard let data = read(account: accountId),
              let value = String(data: data, encoding: .utf8) else {
            return ""
        }
        return value
    }

    static func setToken(_ token: String, accountId: String) {
        let data = Data(token.utf8)
        let query = baseQuery(accountId: accountId)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func clearToken(accountId: String) {
        SecItemDelete(baseQuery(accountId: accountId) as CFDictionary)
    }

    private static func read(account: String) -> Data? {
        var query = baseQuery(accountId: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func baseQuery(accountId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WatchPoint.SchedulerAdmin",
            kSecAttrAccount as String: accountId
        ]
    }
}
