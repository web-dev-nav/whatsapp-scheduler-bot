//
//  WatchPointModels.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Foundation

let productionSchedulerAdminURL = "https://hp-server.tailed5092.ts.net:10000"

enum AppRelease {
    static let requiredEngineVersion = "1.3.0"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "7"
    }

    static var displayVersion: String { "\(version) (\(build))" }

    static func isVersion(_ version: String, atLeast requiredVersion: String) -> Bool {
        version.compare(requiredVersion, options: .numeric) != .orderedAscending
    }
}

struct GuardProfile: Codable, Hashable {
    var name: String
}

struct PatrolSettings: Codable, Hashable {
    var accuracyThresholdMeters: Double
    var checkpointCooldownMinutes: Double
}

struct PatrolSession: Codable, Hashable {
    var active: Bool
    var updatedAt: String?
}

// Authoritative checkpoint shape returned by /api/patrol/state.
struct Checkpoint: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
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
    var requestPayload: PatrolEventPayload
    var apiReceived: Bool
    var responseCode: Int?
    var schedulerStatusCode: Int?
    var responseSummary: String?
    var schedulerReason: String?
    var retryCount: Int
    var lastAttemptAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, source, guardName, checkpointId, checkpointName, eventType, timestamp
        case latitude, longitude, accuracyMeters, status, requestPayload, apiReceived
        case webhookReceived, responseCode, schedulerStatusCode, responseSummary
        case schedulerReason, retryCount, lastAttemptAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(String.self, forKey: .source)
        guardName = try values.decode(String.self, forKey: .guardName)
        checkpointId = try values.decodeIfPresent(String.self, forKey: .checkpointId)
        checkpointName = try values.decode(String.self, forKey: .checkpointName)
        eventType = try values.decode(String.self, forKey: .eventType)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        accuracyMeters = try values.decodeIfPresent(Double.self, forKey: .accuracyMeters)
        status = try values.decode(PatrolEventStatus.self, forKey: .status)
        requestPayload = try values.decode(PatrolEventPayload.self, forKey: .requestPayload)
        let currentAPIReceived = try values.decodeIfPresent(Bool.self, forKey: .apiReceived)
        let legacyWebhookReceived = try values.decodeIfPresent(Bool.self, forKey: .webhookReceived)
        apiReceived = currentAPIReceived ?? legacyWebhookReceived ?? false
        responseCode = try values.decodeIfPresent(Int.self, forKey: .responseCode)
        schedulerStatusCode = try values.decodeIfPresent(Int.self, forKey: .schedulerStatusCode)
        responseSummary = try values.decodeIfPresent(String.self, forKey: .responseSummary)
        schedulerReason = try values.decodeIfPresent(String.self, forKey: .schedulerReason)
        retryCount = try values.decode(Int.self, forKey: .retryCount)
        lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(source, forKey: .source)
        try values.encode(guardName, forKey: .guardName)
        try values.encodeIfPresent(checkpointId, forKey: .checkpointId)
        try values.encode(checkpointName, forKey: .checkpointName)
        try values.encode(eventType, forKey: .eventType)
        try values.encode(timestamp, forKey: .timestamp)
        try values.encodeIfPresent(latitude, forKey: .latitude)
        try values.encodeIfPresent(longitude, forKey: .longitude)
        try values.encodeIfPresent(accuracyMeters, forKey: .accuracyMeters)
        try values.encode(status, forKey: .status)
        try values.encode(requestPayload, forKey: .requestPayload)
        try values.encode(apiReceived, forKey: .apiReceived)
        try values.encodeIfPresent(responseCode, forKey: .responseCode)
        try values.encodeIfPresent(schedulerStatusCode, forKey: .schedulerStatusCode)
        try values.encodeIfPresent(responseSummary, forKey: .responseSummary)
        try values.encodeIfPresent(schedulerReason, forKey: .schedulerReason)
        try values.encode(retryCount, forKey: .retryCount)
        try values.encodeIfPresent(lastAttemptAt, forKey: .lastAttemptAt)
    }
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

struct PatrolEventPayload: Codable, Hashable {
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

struct PatrolStateResponse: Codable {
    let account: SchedulerAccount
    let profile: GuardProfile
    let settings: PatrolSettings
    let checkpoints: [Checkpoint]
    let history: [PatrolEvent]
    let session: PatrolSession
}

struct PatrolStateUpdateRequest: Encodable {
    let profile: GuardProfile
    let settings: PatrolSettings
    let checkpoints: [Checkpoint]
    let session: PatrolSession
}

struct PatrolImportRequest: Encodable {
    let profile: GuardProfile?
    let settings: PatrolSettings?
    let checkpoints: [Checkpoint]
    let history: [PatrolEvent]
}

struct PatrolLocationRequest: Encodable {
    let source: String
    let lat: Double
    let lng: Double
    let accuracyMeters: Double
}

struct PatrolEventRequest: Encodable {
    let checkpointId: String
    let source: String
    let eventType: String
    let lat: Double?
    let lng: Double?
    let accuracyMeters: Double?
}

struct PatrolActionResponse: Decodable {
    let ok: Bool
    let event: PatrolEvent?
    let state: PatrolStateResponse
}

struct PatrolLocationResponse: Decodable {
    let ok: Bool
    let ignored: Bool
    let reason: String?
    let events: [PatrolEvent]
    let state: PatrolStateResponse
}

struct PatrolRetryResponse: Decodable {
    let ok: Bool
    let retried: Int
    let state: PatrolStateResponse
}

// Mirrors scheduler.js DEFAULT_CONFIG exactly and is round-tripped whole.
// The server keeps its legacy config patrol.checkpoints representation in
// sync with the authoritative patrol-state checkpoint collection.
struct PatrolConfig: Codable, Hashable {
    var groupName: String
    var timezone: String
    var message: String
    // Optional keeps the iOS client able to read responses from a server that
    // predates shared delivery settings. The updated server always returns it.
    var delivery: DeliveryConfig?
    var schedule: ScheduleConfig
    var patrol: PatrolSection
}

struct DeliveryConfig: Codable, Hashable {
    var minMessageIntervalMinutes: Int
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
    var message: String
    var checkpoints: [ServerCheckpoint]

    private enum CodingKeys: String, CodingKey {
        case message, checkpoints
    }

    init(message: String = "", checkpoints: [ServerCheckpoint] = []) {
        self.message = message
        self.checkpoints = checkpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        checkpoints = try container.decodeIfPresent([ServerCheckpoint].self, forKey: .checkpoints) ?? []
    }
}

// Legacy config representation used by public/patrol.html. iOS does not edit
// this array directly; server.js synchronizes it with /api/patrol/state.
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

struct SchedulerLogEntry: Decodable, Identifiable, Hashable {
    let id: String
    let type: String
    let category: String?
    let message: String
    let timestamp: String
    let label: String
    let accountId: String?
    let accountName: String?
}

enum ActivityClearScope: String {
    case all
    case schedule
    case patrol

    var title: String {
        switch self {
        case .all: return "All Activity"
        case .schedule: return "Scheduled Activity"
        case .patrol: return "Patrol Activity"
        }
    }
}

struct LogsResponse: Decodable {
    let logs: [SchedulerLogEntry]
}

struct ClearActivityResponse: Decodable {
    let ok: Bool
    let logs: [SchedulerLogEntry]
    let state: PatrolStateResponse
}

let weekdayLabels: [(value: Int, short: String)] = [
    (0, "Sun"), (1, "Mon"), (2, "Tue"), (3, "Wed"), (4, "Thu"), (5, "Fri"), (6, "Sat"),
]

struct PatrolStatusResponse: Decodable {
    let minMessageIntervalMinutes: Int
    let checkpointCooldownMinutes: Double?
    let lastSuccessfulSend: LastSend?
    let nextAvailableAt: String?
    let minutesUntilAvailable: Double

    struct LastSend: Decodable {
        let attemptedAt: String
        let chatName: String?
    }
}
