//
//  StikDebugTests.swift
//  StikDebugTests
//
//  Created by Stephen on 3/26/25.
//

import Foundation
import CoreLocation
import Testing
@testable import StikDebug

struct StikDebugTests {

    // 上游 iOS 26.6 TXM 偵測的 4 個測試已移除：它們呼叫的是新版 hasTXMSupport(isIOS266OrNewer:hasTXMClassic:hardwareIdentifier:)，本分支的上游程式還是舊版只收 hardwareIdentifier，整個測試目標因此編不過。

    @Test func deviceVersionParsesSupportedIdentifiers() async throws {
        #expect(ProcessInfo.processInfo.deviceVersion(from: "iPhone14,2") == 14.2)
        #expect(ProcessInfo.processInfo.deviceVersion(from: "iPad14,5") == 14.5)
        #expect(ProcessInfo.processInfo.deviceVersion(from: "Mac14,2") == nil)
    }

    private func near(_ text: String, _ lat: Double, _ lon: Double) -> Bool {
        guard let c = GpsGeo.parseCoordinate(text) else { return false }
        return abs(c.latitude - lat) < 1e-6 && abs(c.longitude - lon) < 1e-6
    }

    @Test func coordinateParsesCompactHemisphereLetters() async throws {
        #expect(near("25.03N121.56E", 25.03, 121.56))
        #expect(near("33.86S151.21E", -33.86, 151.21))
        #expect(near("25.03S121.56W", -25.03, -121.56))
        #expect(GpsGeo.parseCoordinate("Pier 39 North") == nil)
        #expect(GpsGeo.parseCoordinate("Taipei 101") == nil)
    }

    @Test func coordinateParsesDegreesMinutesSeconds() async throws {
        let lat: Double = 25 + 2.0 / 60 + 1.2 / 3600
        let lon: Double = 121 + 33.0 / 60 + 54.0 / 3600
        #expect(near("25°2'1.2\"N 121°33'54\"E", lat, lon))
        #expect(near("25°2′1.2″N 121°33′54″E", lat, lon))
        #expect(near("25°2'1.2N 121°33'54E", lat, lon))
        #expect(near("25°2'1.2'' N, 121°33'54'' E", lat, lon))
        // Computed outside #expect: inside the macro Xcode 26 timed out type-checking the arithmetic.
        let sydneyLat: Double = -(33 + 52.0 / 60 + 10.0 / 3600)
        let sydneyLon: Double = 151 + 12.0 / 60 + 30.0 / 3600
        #expect(near("-33°52'10\", 151°12'30\"", sydneyLat, sydneyLon))
        #expect(GpsGeo.parseCoordinate("25°61'0\"N 121°0'0\"E") == nil)
    }

}
