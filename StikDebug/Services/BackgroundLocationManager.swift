//
//  BackgroundLocationManager.swift
//  StikDebug
//

import CoreLocation
import UIKit

final class BackgroundLocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private let locationManager = CLLocationManager()
    private var isRunning = false
    private var activityCount = 0
    private var isRequestingAuthorization = false
    private var isShowingPrimer = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = CLLocationDistanceMax
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
    }

    func configurationDidChange() {
        refreshRunningState()
    }

    func requestStart() {
        activityCount += 1
        refreshRunningState()
    }

    func requestStop() {
        activityCount = max(activityCount - 1, 0)
        refreshRunningState()
    }

    func requestAuthorizationIfNeeded() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .notDetermined:
            requestAuthorizationWithPrimer()
        case .denied, .restricted:
            restoreAudioFallback()
        @unknown default:
            restoreAudioFallback()
        }
    }

    private func refreshRunningState() {
        let shouldRun = activityCount > 0 && UserDefaults.standard.bool(forKey: "keepAliveLocation")
        guard shouldRun != isRunning else { return }

        isRunning = shouldRun
        guard shouldRun else {
            locationManager.stopUpdatingLocation()
            return
        }

        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .notDetermined:
            requestAuthorizationWithPrimer()
        case .denied, .restricted:
            restoreAudioFallback()
        @unknown default:
            restoreAudioFallback()
        }
    }

    /// First-time only (status .notDetermined): one line on why, then the system prompt.
    /// 「暫時不要」 asks nothing; the next simulation start shows this again.
    private func requestAuthorizationWithPrimer() {
        guard !isShowingPrimer else { return }
        isShowingPrimer = true
        showAlert(
            title: "為了在鎖螢幕或切到別的 App 時讓定位模擬不中斷，下一步系統會詢問定位權限。",
            message: "",
            showOk: false,
            showTryAgain: true,
            primaryButtonText: "繼續",
            secondaryButtonText: "暫時不要"
        ) { [weak self] proceed in
            guard let self else { return }
            self.isShowingPrimer = false
            guard proceed, self.locationManager.authorizationStatus == .notDetermined else { return }
            self.isRequestingAuthorization = true
            self.locationManager.requestAlwaysAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            isRequestingAuthorization = false
            if isRunning {
                manager.startUpdatingLocation()
            }
        case .denied, .restricted:
            if isRunning || isRequestingAuthorization {
                isRequestingAuthorization = false
                restoreAudioFallback()
            }
        case .notDetermined:
            return
        @unknown default:
            if isRunning || isRequestingAuthorization {
                isRequestingAuthorization = false
                restoreAudioFallback()
            }
        }
    }

    private func restoreAudioFallback() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "keepAliveLocation")
        defaults.set(true, forKey: "keepAliveAudio")
        refreshRunningState()
        BackgroundAudioManager.shared.configurationDidChange()

        showAlert(
            title: "Location Access Refused",
            message: "Location access was refused. Open Settings to enable it.",
            showOk: false,
            showTryAgain: true,
            primaryButtonText: "Settings"
        ) { openSettings in
            guard openSettings,
                  let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
                return
            }
            UIApplication.shared.open(settingsURL)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location fixes may fail (e.g. no GPS indoors) — that's fine.
        // The manager just needs to be running, not actually fix a location.
    }
}
