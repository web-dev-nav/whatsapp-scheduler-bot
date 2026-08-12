//
//  PatrolService.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Foundation

struct PatrolService {
    var webhookURL: URL

    func sendPatrolEvent(_ requestBody: PatrolWebhookRequest) async throws -> (WebhookResponse, Int) {
        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WebhookError.http(status: httpResponse.statusCode, body: body)
        }

        return (try JSONDecoder().decode(WebhookResponse.self, from: data), httpResponse.statusCode)
    }
}
