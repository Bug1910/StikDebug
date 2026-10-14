//
//  GpsSimPlaces.swift
//  StikDebug (GpsSim fork)
//
//  Saved places, stored in Documents/places.json with the same shape as the
//  GpsSim web tool ({"favorites":[{id,name,lat,lon,radius,county,hidden,order}]}).
//  A file (not UserDefaults) so the PC can push it through house_arrest without
//  cfprefsd serving a stale cached copy.
//

import Foundation
import CoreLocation

struct GpsPlace: Identifiable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var radius: Double?
    var county: String?
    var hidden: Bool?
    var order: Int?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var isHidden: Bool { hidden == true }

    /// Lenient parse: the web tool writes numbers as ints or doubles (and older
    /// files sometimes as strings), and any field except lat/lon may be missing.
    init?(json: [String: Any]) {
        guard let lat = GpsPlace.double(json["lat"]),
              let lon = GpsPlace.double(json["lon"]),
              (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        self.lat = lat
        self.lon = lon
        if let s = json["id"] as? String, !s.isEmpty {
            id = s
        } else if let n = GpsPlace.double(json["id"]) {
            id = String(Int(n))
        } else {
            id = GpsPlace.newID()
        }
        let rawName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = rawName.isEmpty ? String(format: "%.5f, %.5f", lat, lon) : rawName
        if let r = GpsPlace.double(json["radius"]), r > 0 { radius = r }
        if let c = json["county"] as? String, !c.isEmpty { county = c }
        if let h = json["hidden"] as? Bool { hidden = h }
        if let o = GpsPlace.double(json["order"]) { order = Int(o) }
    }

    init(id: String = GpsPlace.newID(), name: String, lat: Double, lon: Double,
         radius: Double? = nil, county: String? = nil, hidden: Bool? = nil, order: Int? = nil) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lon = lon
        self.radius = radius
        self.county = county
        self.hidden = hidden
        self.order = order
    }

    /// Writes our known fields over `base`, so keys we don't model (e.g. "used") survive a save.
    func json(mergingInto base: [String: Any]) -> [String: Any] {
        var d = base
        d["id"] = id
        d["name"] = name
        d["lat"] = lat
        d["lon"] = lon
        if let radius {
            if radius.rounded() == radius, radius < 1_000_000 {
                d["radius"] = Int(radius)
            } else {
                d["radius"] = radius
            }
        } else {
            d.removeValue(forKey: "radius")
        }
        if let county { d["county"] = county } else { d.removeValue(forKey: "county") }
        if let hidden, hidden { d["hidden"] = true } else { d.removeValue(forKey: "hidden") }
        if let order { d["order"] = order } else { d.removeValue(forKey: "order") }
        return d
    }

    static func newID() -> String {
        "p" + String(Int(Date().timeIntervalSince1970 * 1000)) + String(Int.random(in: 100...999))
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber {
            // JSONSerialization gives booleans as NSNumber too; don't treat true as 1.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

// MARK: - Geometry (ported 1:1 from GpsSim index.html: radOf / offsetR / metersBetween / sampleLanding)

enum GpsGeo {
    static let defaultRadiusKey = "gpssimDefaultRadius"
    static let driftKey = "gpssimDrift"
    /// Drift radius around the landing point (web: JITTER = 4).
    static let jitter = 4.0

    static var defaultRadius: Double {
        let v = UserDefaults.standard.double(forKey: defaultRadiusKey)
        return v > 0 ? v : 25
    }

    static func radius(of p: GpsPlace) -> Double {
        if let r = p.radius, r > 0 { return r }
        return defaultRadius
    }

    /// Uniform random point within R metres (sqrt keeps points from bunching at the centre).
    static func offset(_ lat: Double, _ lon: Double, _ r: Double) -> CLLocationCoordinate2D {
        guard r > 0 else { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        let ang = Double.random(in: 0..<(2 * Double.pi))
        let d = Double.random(in: 0..<1).squareRoot() * r
        return CLLocationCoordinate2D(
            latitude: lat + (d * sin(ang)) / 111_320,
            longitude: lon + (d * cos(ang)) / (111_320 * cos(lat * Double.pi / 180))
        )
    }

    static func meters(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let dLat = (bLat - aLat) * 111_320
        let dLon = (bLon - aLon) * 111_320 * cos((aLat + bLat) / 2 * Double.pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot()
    }

    static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        meters(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    /// Random landing for a place. If other places' circles overlap it, the point may land
    /// anywhere in the union: area-weighted circle pick + accept with 1/k (k = circles covering
    /// the point) keeps the union uniform; 24 tries, then fall back to the place's own circle.
    static func sampleLanding(_ place: GpsPlace, among all: [GpsPlace]) -> CLLocationCoordinate2D {
        let r = radius(of: place)
        var circles: [(lat: Double, lon: Double, r: Double)] = [(place.lat, place.lon, r)]
        for q in all {
            if q.id == place.id || (q.lat == place.lat && q.lon == place.lon) { continue }
            let rq = radius(of: q)
            if meters(place.lat, place.lon, q.lat, q.lon) < r + rq {
                circles.append((q.lat, q.lon, rq))
            }
        }
        if circles.count == 1 { return offset(place.lat, place.lon, r) }
        let areas = circles.map { $0.r * $0.r }
        let total = areas.reduce(0, +)
        for _ in 0..<24 {
            var x = Double.random(in: 0..<max(total, 1e-9))
            var idx = 0
            while idx < areas.count - 1 && x > areas[idx] {
                x -= areas[idx]
                idx += 1
            }
            let c = circles[idx]
            let pt = offset(c.lat, c.lon, c.r)
            var k = 0
            for cc in circles where meters(pt.latitude, pt.longitude, cc.lat, cc.lon) <= cc.r { k += 1 }
            if k <= 1 || Double.random(in: 0..<1) < 1 / Double(k) { return pt }
        }
        return offset(place.lat, place.lon, r)
    }

    /// "lat, lon" (half- or full-width comma, or whitespace) → coordinate, else nil.
    static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Store

final class GpsPlaceStore: ObservableObject {
    static let shared = GpsPlaceStore()

    @Published private(set) var places: [GpsPlace] = []
    @Published var lastLoadError: String?

    static var fileURL: URL {
        URL.documentsDirectory.appendingPathComponent("places.json")
    }

    private init() {
        migrateBookmarksIfNeeded()
        reload()
    }

    /// Sorted for display: by `order`, then by position in the file (insertion order).
    var sorted: [GpsPlace] {
        places.enumerated()
            .sorted { a, b in
                let oa = a.element.order ?? Int.max
                let ob = b.element.order ?? Int.max
                return oa != ob ? oa < ob : a.offset < b.offset
            }
            .map { $0.element }
    }

    func reload() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            places = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            places = try Self.parse(data)
            lastLoadError = nil
        } catch {
            // Keep what we had; a half-written push from the PC shouldn't wipe the list.
            lastLoadError = "places.json 讀不懂：\(error.localizedDescription)"
        }
    }

    static func parse(_ data: Data) throws -> [GpsPlace] {
        let obj = try JSONSerialization.jsonObject(with: data)
        let list: [Any]
        if let root = obj as? [String: Any] {
            list = (root["favorites"] as? [Any]) ?? []
        } else if let arr = obj as? [Any] {
            list = arr   // tolerate a bare array
        } else {
            list = []
        }
        var seen = Set<String>()
        var result: [GpsPlace] = []
        for item in list {
            guard let dict = item as? [String: Any], var p = GpsPlace(json: dict) else { continue }
            if seen.contains(p.id) { p.id = GpsPlace.newID() }
            seen.insert(p.id)
            result.append(p)
        }
        return result
    }

    func upsert(_ place: GpsPlace) {
        if let i = places.firstIndex(where: { $0.id == place.id }) {
            places[i] = place
        } else {
            places.append(place)
        }
        save()
    }

    func delete(id: String) {
        places.removeAll { $0.id == id }
        save()
    }

    /// Next order value for a new place (only if the list already uses manual order).
    func nextOrder() -> Int? {
        let orders = places.compactMap { $0.order }
        return orders.isEmpty ? nil : (orders.max() ?? 0) + 1
    }

    /// Replace everything with an imported places.json (old file kept as places.json.bak).
    func importFile(_ url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let parsed = try Self.parse(data)
        let fm = FileManager.default
        let dest = Self.fileURL
        if fm.fileExists(atPath: dest.path) {
            let bak = dest.deletingLastPathComponent().appendingPathComponent("places.json.bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: dest, to: bak)
        }
        try data.write(to: dest, options: .atomic)
        places = parsed
        lastLoadError = nil
        return parsed.count
    }

    /// Writes favorites back, keeping other top-level keys (recents, trash, ...) and
    /// unknown per-place keys from the file as it is on disk right now.
    func save() {
        let url = Self.fileURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var oldByID: [String: [String: Any]] = [:]
        for item in (root["favorites"] as? [Any]) ?? [] {
            if let d = item as? [String: Any], let id = d["id"] as? String { oldByID[id] = d }
        }
        root["favorites"] = places.map { $0.json(mergingInto: oldByID[$0.id] ?? [:]) }
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            lastLoadError = "存檔失敗：\(error.localizedDescription)"
        }
    }

    /// First launch: carry over stock StikDebug bookmarks (UserDefaults "locationBookmarks").
    private func migrateBookmarksIfNeeded() {
        guard !FileManager.default.fileExists(atPath: Self.fileURL.path),
              let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let bookmarks = try? JSONDecoder().decode([LocationBookmark].self, from: data),
              !bookmarks.isEmpty else { return }
        places = bookmarks.map {
            GpsPlace(id: $0.id.uuidString, name: $0.name, lat: $0.latitude, lon: $0.longitude, radius: $0.radius)
        }
        save()
    }
}
