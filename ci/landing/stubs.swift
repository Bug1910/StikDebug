// Minimal copy of the app's LocationBookmark (StikDebug/Views/MapSelectionView.swift) so
// GpsSimPlaces.swift compiles alone; only the bookmark-migration code refers to it.
import Foundation

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double? = nil
}
