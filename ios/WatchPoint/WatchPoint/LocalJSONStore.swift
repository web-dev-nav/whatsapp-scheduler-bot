//
//  LocalJSONStore.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Foundation

enum LocalJSONStore {
    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
