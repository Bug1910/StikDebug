// One "app launch": a fresh process picks the first landing for one place, like the first tap
// after reopening PinFly. Prints "lat lon metres-from-centre". Test coordinates only (public repo).
import Foundation
import CoreLocation

let place = GpsPlace(id: "t1", name: "test", lat: 48.8584, lon: 2.2945, radius: 25, county: nil, hidden: nil, order: nil)
let neighbour = GpsPlace(id: "t2", name: "near", lat: 48.8587, lon: 2.2945, radius: 25, county: nil, hidden: nil, order: nil)
let all = CommandLine.arguments.contains("--overlap") ? [place, neighbour] : [place]
let p = GpsGeo.sampleLanding(place, among: all)
print(String(format: "%.7f %.7f %.2f", p.latitude, p.longitude, GpsGeo.meters(place.coordinate, p)))
