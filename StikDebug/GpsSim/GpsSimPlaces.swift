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
        id = GpsPlace.idKey(json["id"]) ?? GpsPlace.newID()
        let rawName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = rawName.isEmpty ? String(format: "%.5f, %.5f", lat, lon) : rawName
        if let r = GpsPlace.double(json["radius"]), r.isFinite, r > 0 { radius = r }
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
        // Keep a numeric id numeric (the web tool wrote it that way) when it is the same id.
        if let baseID = base["id"] as? NSNumber, GpsPlace.idKey(baseID) == id {
            d["id"] = baseID
        } else {
            d["id"] = id
        }
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

    /// The web tool's ids may be strings or numbers; the string form is the one key we compare by.
    static func idKey(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = double(value), n.isFinite, abs(n) < 1e15 { return String(Int(n)) }
        return nil
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
    /// Allowed radius for the default-radius setting (metres); web tool allows large radii too.
    static let radiusRange: ClosedRange<Double> = 5...5000

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

    enum CoordinateParse {
        case ok(CLLocationCoordinate2D)
        case notCoordinate
        case outOfRange(String)
    }

    /// "lat, lon" (half- or full-width comma, or whitespace). If the first number can't be a
    /// latitude but the second can (e.g. "120.97, 24.80" pasted lon-first), they are swapped.
    static func parseCoordinateResult(_ text: String) -> CoordinateParse {
        let normalized = text
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = normalized
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2, var lat = Double(parts[0]), var lon = Double(parts[1]),
              lat.isFinite, lon.isFinite else { return .notCoordinate }
        if abs(lat) > 90 && abs(lon) <= 90 { swap(&lat, &lon) }
        guard (-90.0...90.0).contains(lat) else { return .outOfRange("緯度必須在 -90 到 90 之間") }
        guard (-180.0...180.0).contains(lon) else { return .outOfRange("經度必須在 -180 到 180 之間") }
        return .ok(CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        if case .ok(let c) = parseCoordinateResult(text) { return c }
        return nil
    }
}

// MARK: - Store

@MainActor
final class GpsPlaceStore: ObservableObject {
    static let shared = GpsPlaceStore()

    @Published private(set) var places: [GpsPlace] = []
    /// The most recent place removed by delete(id:), so the UI can offer "復原".
    private struct DeletedEntry {
        let place: GpsPlace
        let index: Int
        let raw: [String: Any]
    }
    private var deletedEntry: DeletedEntry? { didSet { objectWillChange.send() } }
    var lastDeleted: GpsPlace? { deletedEntry?.place }
    @Published var lastLoadError: String?

    nonisolated static var fileURL: URL {
        URL.documentsDirectory.appendingPathComponent("places.json")
    }
    nonisolated static var importBackupURL: URL {
        URL.documentsDirectory.appendingPathComponent("places.json.bak")
    }
    nonisolated static var corruptCopyURL: URL {
        URL.documentsDirectory.appendingPathComponent("places.json.corrupt")
    }

    private init() {
        migrateBookmarksIfNeeded()
        reload()
        refreshImportBackupFlag()
    }

    var placeCount: Int { places.count }

    /// Published (not computed) so views refresh after import / restore.
    @Published private(set) var hasImportBackup = false

    private func refreshImportBackupFlag() {
        hasImportBackup = FileManager.default.fileExists(atPath: Self.importBackupURL.path)
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

    // MARK: Disk access
    // The PC can push places.json through house_arrest at any time, so every read/write goes
    // through NSFileCoordinator and every write is atomic (temp file + rename).

    private enum DiskState {
        case missing
        case ok([String: Any])
        case corrupt(String)
    }

    nonisolated private static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    nonisolated private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do { try data.write(to: writeURL, options: .atomic) } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }

    private func readDisk() -> DiskState {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Self.coordinatedRead(url)
            let obj = try JSONSerialization.jsonObject(with: data)
            if let root = obj as? [String: Any] { return .ok(root) }
            if let arr = obj as? [Any] { return .ok(["favorites": arr]) }   // tolerate a bare array
            return .corrupt("內容不是地點清單")
        } catch {
            return .corrupt(error.localizedDescription)
        }
    }

    /// Re-reads the file. Returns false (keeping the in-memory list) if the file is unreadable.
    @discardableResult
    func reload() -> Bool {
        switch readDisk() {
        case .missing:
            places = []
            return true
        case .ok(let root):
            places = Self.parseFavorites((root["favorites"] as? [Any]) ?? [])
            lastLoadError = nil
            return true
        case .corrupt(let reason):
            // Keep what we had; a half-written push from the PC shouldn't wipe the list.
            lastLoadError = "places.json 讀不懂：\(reason)"
            return false
        }
    }

    nonisolated static func parse(_ data: Data) throws -> [GpsPlace] {
        let obj = try JSONSerialization.jsonObject(with: data)
        if let root = obj as? [String: Any] {
            return parseFavorites((root["favorites"] as? [Any]) ?? [])
        } else if let arr = obj as? [Any] {
            return parseFavorites(arr)
        }
        return []
    }

    nonisolated static func parseFavorites(_ list: [Any]) -> [GpsPlace] {
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

    // MARK: Edits (always: reload from disk, apply by id, save)

    func upsert(_ place: GpsPlace) {
        guard reload() else { return }
        var incoming = place
        // Radius is only ever changed when the caller passes a valid new one. nil / invalid
        // (<=0, NaN) means "untouched": keep what the existing place has.
        if let r = incoming.radius, !(r.isFinite && r > 0) { incoming.radius = nil }
        if let i = places.firstIndex(where: { $0.id == incoming.id }) {
            if incoming.radius == nil { incoming.radius = places[i].radius }
            places[i] = incoming
        } else {
            // Same as web index.html: a new place goes to the top (min order - 1).
            if incoming.order == nil { incoming.order = nextOrder() }
            places.append(incoming)
        }
        save()
    }

    func delete(id: String) {
        guard reload() else { return }
        guard let index = places.firstIndex(where: { $0.id == id }) else { return }
        let removed = places[index]
        var raw: [String: Any] = [:]
        if case .ok(let root) = readDisk() {
            for item in (root["favorites"] as? [Any]) ?? [] {
                if let dict = item as? [String: Any], GpsPlace.idKey(dict["id"]) == id { raw = dict; break }
            }
        }
        places.remove(at: index)
        deletedEntry = DeletedEntry(place: removed, index: index, raw: raw)
        save()
    }

    /// Puts the place back at its old position with its old order and extra keys.
    func undoDelete() {
        guard let entry = deletedEntry, reload() else { return }
        if !places.contains(where: { $0.id == entry.place.id }) {
            places.insert(entry.place, at: min(entry.index, places.count))
            save(extraBases: [entry.place.id: entry.raw])
        }
        deletedEntry = nil
    }

    /// Order for a new place: one before the current smallest (nil if nobody uses manual order yet).
    func nextOrder() -> Int? {
        guard let smallest = places.compactMap({ $0.order }).min() else { return nil }
        return smallest - 1
    }

    // MARK: Import / restore

    /// Replace everything with an imported places.json (old file kept as places.json.bak).
    func importFile(_ url: URL) throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let parsed = try Self.parse(data)
        let fm = FileManager.default
        let dest = Self.fileURL
        if fm.fileExists(atPath: dest.path) {
            let bak = Self.importBackupURL
            try? fm.removeItem(at: bak)
            try fm.copyItem(at: dest, to: bak)
        }
        try Self.coordinatedWrite(data, to: dest)
        places = parsed
        lastLoadError = nil
        refreshImportBackupFlag()
        return parsed.count
    }

    /// Put back the file that importFile() replaced.
    func restoreImportBackup() {
        do {
            let data = try Data(contentsOf: Self.importBackupURL)
            _ = try Self.parse(data)
            try Self.coordinatedWrite(data, to: Self.fileURL)
            reload()
            refreshImportBackupFlag()
        } catch {
            lastLoadError = "還原匯入前的檔案失敗：\(error.localizedDescription)"
        }
    }

    /// Writes favorites back, keeping other top-level keys (recents, trash, ...), unknown
    /// per-place keys, and favorites this app can't parse, all as on disk right now.
    /// Refuses to overwrite a file it can't read (a PC push caught mid-write would be lost).
    func save(extraBases: [String: [String: Any]] = [:]) {
        var root: [String: Any] = [:]
        switch readDisk() {
        case .missing:
            break
        case .corrupt(let reason):
            let fm = FileManager.default
            try? fm.removeItem(at: Self.corruptCopyURL)
            try? fm.copyItem(at: Self.fileURL, to: Self.corruptCopyURL)
            lastLoadError = "places.json 讀不懂，沒有覆蓋（原檔已複製成 places.json.corrupt）：\(reason)"
            return
        case .ok(let existing):
            root = existing
        }
        var oldByID: [String: [String: Any]] = [:]
        var unparseable: [Any] = []
        for item in (root["favorites"] as? [Any]) ?? [] {
            if let dict = item as? [String: Any], GpsPlace(json: dict) != nil {
                if let key = GpsPlace.idKey(dict["id"]), oldByID[key] == nil { oldByID[key] = dict }
            } else {
                unparseable.append(item)
            }
        }
        var favorites: [Any] = places.map { $0.json(mergingInto: extraBases[$0.id] ?? oldByID[$0.id] ?? [:]) }
        favorites.append(contentsOf: unparseable)
        root["favorites"] = favorites
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try Self.coordinatedWrite(data, to: Self.fileURL)
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
