//
//  WatchPointModels.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Foundation

let productionPatrolWebhookURL = "https://hp-server.tailed5092.ts.net/webhook/patrol-test"
let developmentSchedulerAdminURL = "http://172.20.10.3:3000"

struct GuardProfile: Codable, Hashable {
    var name: String
}

struct Checkpoint: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var notes: String
    var isActive: Bool
}

struct PatrolAppointment: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var startsAt: Date
    var endsAt: Date
    var isActive: Bool
}

struct PatrolEvent: Codable, Identifiable, Hashable {
    var id: UUID
    var source: String
    var guardName: String
    var checkpointId: String?
    var checkpointName: String
    var eventType: String
    var timestamp: Date
    var latitude: Double?
    var longitude: Double?
    var accuracyMeters: Double?
    var status: PatrolEventStatus
    var requestPayload: PatrolWebhookRequest
    var webhookReceived: Bool
    var responseCode: Int?
    var schedulerStatusCode: Int?
    var responseSummary: String?
    var schedulerReason: String?
    var retryCount: Int
    var lastAttemptAt: Date?
}

enum PatrolEventStatus: String, Codable, CaseIterable {
    case queued
    case sending
    case backendReceived
    case schedulerSucceeded
    case engineNotReady
    case failed

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .sending: return "Sending"
        case .backendReceived: return "Backend Received"
        case .schedulerSucceeded: return "Sent"
        case .engineNotReady: return "Engine Not Ready"
        case .failed: return "Failed"
        }
    }
}

struct PatrolWebhookRequest: Codable, Hashable {
    let source: String
    let guardName: String
    let checkpointId: String?
    let checkpointName: String
    let eventType: String
    let timestamp: String
    let lat: Double?
    let lng: Double?
    let accuracyMeters: Double?

    enum CodingKeys: String, CodingKey {
        case source
        case guardName = "guard"
        case checkpointId
        case checkpointName
        case eventType
        case timestamp
        case lat
        case lng
        case accuracyMeters
    }
}

struct WebhookResponse: Decodable {
    let ok: Bool?
    let message: String?
    let receivedAt: String?
    let guardName: String?
    let checkpointName: String?
    let source: String?
    let schedulerStatusCode: Int?
    let schedulerResponse: SchedulerEngineResponse?

    enum CodingKeys: String, CodingKey {
        case ok
        case message
        case receivedAt
        case guardName = "guard"
        case checkpointName
        case source
        case schedulerStatusCode
        case schedulerResponse
    }
}

struct SchedulerEngineResponse: Decodable {
    let ok: Bool?
    let reason: String?
}

enum WebhookError: LocalizedError {
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case let .http(status, body):
            return body.isEmpty ? "Webhook returned HTTP \(status)." : "Webhook returned HTTP \(status): \(body)"
        }
    }
}

// Mirrors scheduler.js DEFAULT_CONFIG exactly. Round-tripped whole (GET then
// PUT) so fields the app doesn't expose UI for -- notably patrol.checkpoints,
// which the browser's patrol.html page owns -- are never dropped or reset.
struct PatrolConfig: Codable, Hashable {
    var groupName: String
    var timezone: String
    var message: String
    var schedule: ScheduleConfig
    var patrol: PatrolSection
}

struct ScheduleConfig: Codable, Hashable {
    var enabled: Bool
    var activeShiftDays: [Int]
    var extraShiftDates: [String]
    var shiftStartHour: Int
    var shiftEndHour: Int
    var firstSendMinuteMin: Int
    var firstSendMinuteMax: Int
    var sendSecondMin: Int
    var sendSecondMax: Int
    var minSendIntervalMinutes: Int
    var maxSendIntervalMinutes: Int
    var minMinutesBetweenSends: Int
    var maxSendsPerDay: Int
    var reconnectCooldownMinutes: Int
    var staleSendGraceMinutes: Int
}

struct PatrolSection: Codable, Hashable {
    var checkpoints: [ServerCheckpoint]
}

// Server-side GPS checkpoint shape (used by public/patrol.html). Not edited
// from WatchPoint -- WatchPoint's own checkpoints stay device-local -- but
// decoded/encoded as-is so saving schedule/message settings from the app
// never wipes checkpoints saved from the browser.
struct ServerCheckpoint: Codable, Hashable {
    var id: String
    var name: String
    var lat: Double
    var lng: Double
    var radiusMeters: Double
}

struct ConfigResponse: Decodable {
    let account: SchedulerAccount
    let config: PatrolConfig
}

struct ConfigUpdateRequest: Encodable {
    let config: PatrolConfig
}

let weekdayLabels: [(value: Int, short: String)] = [
    (0, "Sun"), (1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"),
]
