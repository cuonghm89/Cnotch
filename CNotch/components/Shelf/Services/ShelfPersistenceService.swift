//
//  ShelfPersistenceService.swift
//  CNotch
//
//  Created by Alexander on 2025-09-24.
//

import Foundation

// Access model types
@_exported import struct Foundation.URL


final class ShelfPersistenceService {
    static let shared = ShelfPersistenceService()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        let fm = FileManager.default
        let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let storageIdentifier = Bundle.main.bundleIdentifier ?? "CNotch"
        let dir = (support ?? fm.temporaryDirectory).appendingPathComponent(storageIdentifier, isDirectory: true).appendingPathComponent("Shelf", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("items.json")
        encoder.outputFormatting = [.prettyPrinted]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func load() -> [ShelfItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        
        // Try to decode as array first (normal case)
        if let items = try? decoder.decode([ShelfItem].self, from: data) {
            return items
        }
        
        // If array decoding fails, try to decode individual items
        do {
            // Parse as JSON array to get individual item data
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                return []
            }
            
            var validItems: [ShelfItem] = []
            for jsonItem in jsonArray {
                do {
                    let itemData = try JSONSerialization.data(withJSONObject: jsonItem)
                    let item = try decoder.decode(ShelfItem.self, from: itemData)
                    validItems.append(item)
                } catch {
                    // A single unreadable entry shouldn't cost the user the
                    // rest of the shelf, so it's skipped and the others load.
                    continue
                }
            }

            return validItems
        } catch {
            return []
        }
    }

    func save(_ items: [ShelfItem]) {
        do {
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
        }
    }
}
