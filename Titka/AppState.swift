import Foundation
import CoreLocation
import UserNotifications
import UIKit
import SwiftUI

func fmtDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

enum GPSMode: String, CaseIterable, Identifiable {
    case never, whenOpen, every10min, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Ніколи"
        case .whenOpen: return "Коли програма відкрита"
        case .every10min: return "Раз на 10 хвилин"
        case .always: return "Завжди"
        }
    }

    var subtitle: String {
        switch self {
        case .never: return "GPS не використовується, тривога не спрацює"
        case .whenOpen: return "Стежить, поки ти в застосунку"
        case .every10min: return "У фоні, перевірка позиції раз на 10 хв, економніше"
        case .always: return "У фоні постійно, з повідомленням «Тітка в шкафу»"
        }
    }
}

final class AppState: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppState()

    // MARK: стан
    @Published private(set) var alarmActive: Bool
    @Published private(set) var alarmSince: Date?
    @Published private(set) var alarmAuto: Bool
    @Published private(set) var lastDuration: TimeInterval
    @Published private(set) var house: CLLocationCoordinate2D?
    @Published private(set) var radius: Double
    @Published private(set) var mode: GPSMode
    @Published private(set) var devMode: Bool
    @Published private(set) var userLocation: CLLocation?
    @Published private(set) var auth: CLAuthorizationStatus
    @Published private(set) var notifAllowed: Bool = false

    private let lm: CLLocationManager
    private let defaults = UserDefaults.standard
    private var inside: Bool? = nil
    private var lastProcessed = Date.distantPast
    private var foreground = true
    private let regionId = "aunt-house"
    private let tickMinutes = [1, 5, 10, 15, 30, 45, 60]

    private override init() {
        let d = UserDefaults.standard
        let manager = CLLocationManager()
        lm = manager
        alarmActive = d.bool(forKey: "alarmActive")
        alarmSince = d.object(forKey: "alarmSince") as? Date
        alarmAuto = d.bool(forKey: "alarmAuto")
        lastDuration = d.double(forKey: "lastDuration")
        if d.object(forKey: "houseLat") != nil {
            house = CLLocationCoordinate2D(latitude: d.double(forKey: "houseLat"),
                                           longitude: d.double(forKey: "houseLng"))
        } else {
            house = nil
        }
        let r = d.double(forKey: "radius")
        radius = r > 0 ? r : 100
        mode = GPSMode(rawValue: d.string(forKey: "mode") ?? "") ?? .always
        devMode = d.bool(forKey: "devMode")
        auth = manager.authorizationStatus
        super.init()
    }

    // MARK: запуск
    func start() {
        lm.delegate = self
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermission()
        configureLocation()
    }

    func sceneChanged(_ phase: ScenePhase) {
        foreground = (phase == .active)
        if mode == .whenOpen {
            if foreground && isAuthorized { lm.startUpdatingLocation() } else { lm.stopUpdatingLocation() }
        }
        if phase == .active { refreshNotifStatus() }
    }

    private var isAuthorized: Bool {
        auth == .authorizedAlways || auth == .authorizedWhenInUse
    }

    var needsAlwaysFix: Bool {
        (mode == .always || mode == .every10min)
            && auth != .authorizedAlways && auth != .notDetermined
    }

    // MARK: налаштування
    func setMode(_ m: GPSMode) {
        mode = m
        defaults.set(m.rawValue, forKey: "mode")
        configureLocation()
    }

    func setRadius(_ r: Double) {
        radius = min(max(r, 10), 5000)
        defaults.set(radius, forKey: "radius")
        configureLocation()
    }

    func setHouse(_ c: CLLocationCoordinate2D) {
        guard house == nil else { return }   // точка ставиться лише один раз
        house = c
        defaults.set(c.latitude, forKey: "houseLat")
        defaults.set(c.longitude, forKey: "houseLng")
        configureLocation()
    }

    func resetHouse() {
        house = nil
        defaults.removeObject(forKey: "houseLat")
        defaults.removeObject(forKey: "houseLng")
        configureLocation()
    }

    func login(_ pw: String) -> Bool {
        guard pw == "6767" else { return false }
        devMode = true
        defaults.set(true, forKey: "devMode")
        return true
    }

    func setDev(_ on: Bool) {
        devMode = on
        defaults.set(on, forKey: "devMode")
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: геолокація
    private func configureLocation() {
        lm.stopUpdatingLocation()
        lm.stopMonitoringSignificantLocationChanges()
        for region in lm.monitoredRegions { lm.stopMonitoring(for: region) }
        inside = nil

        guard mode != .never else {
            lm.allowsBackgroundLocationUpdates = false
            userLocation = nil
            return
        }

        let st = lm.authorizationStatus
        switch mode {
        case .never:
            break
        case .whenOpen:
            lm.allowsBackgroundLocationUpdates = false
            if st == .notDetermined { lm.requestWhenInUseAuthorization() }
            lm.desiredAccuracy = kCLLocationAccuracyBest
            lm.distanceFilter = kCLDistanceFilterNone
            if foreground && isAuthorized { lm.startUpdatingLocation() }
        case .every10min, .always:
            if st == .notDetermined || st == .authorizedWhenInUse { lm.requestAlwaysAuthorization() }
            lm.allowsBackgroundLocationUpdates = true
            lm.pausesLocationUpdatesAutomatically = false
            lm.showsBackgroundLocationIndicator = true
            lm.desiredAccuracy = (mode == .always) ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
            lm.distanceFilter = (mode == .always) ? 10 : 100
            if isAuthorized {
                lm.startUpdatingLocation()
                lm.startMonitoringSignificantLocationChanges()
            }
            startRegionMonitoring()
        }
    }

    /// Зона навколо дому тітки. iOS сама будить програму, навіть закриту.
    private func startRegionMonitoring() {
        guard let h = house,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let r = min(radius, lm.maximumRegionMonitoringDistance)
        let region = CLCircularRegion(center: h, radius: r, identifier: regionId)
        region.notifyOnEntry = true
        region.notifyOnExit = true
        lm.startMonitoring(for: region)
        lm.requestState(for: region)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        DispatchQueue.main.async {
            let changed = st != self.auth
            self.auth = st
            if changed { self.configureLocation() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        userLocation = loc
        if mode == .every10min {
            guard Date().timeIntervalSince(lastProcessed) >= 600 else { return }
        }
        lastProcessed = Date()
        evaluate(loc)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == regionId else { return }
        enterZone()
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == regionId else { return }
        exitZone()
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard region.identifier == regionId else { return }
        if state == .inside { enterZone() } else if state == .outside { exitZone() }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    private func evaluate(_ loc: CLLocation) {
        guard let h = house else { return }
        let d = loc.distance(from: CLLocation(latitude: h.latitude, longitude: h.longitude))
        let now: Bool
        if let ins = inside {
            now = ins ? (d <= radius + 15) : (d <= radius)   // запас 15 м проти «дрижання» GPS
        } else {
            now = d <= radius
        }
        if inside == now { return }
        if now { enterZone() } else { exitZone() }
    }

    private func enterZone() {
        inside = true
        if !alarmActive { startAlarm(auto: true) }
    }

    private func exitZone() {
        inside = false
        // Відбій дається лише для тривоги, яку ввімкнула сама зона.
        if alarmActive && alarmAuto { endAlarm() }
    }

    // MARK: тривога
    func toggleManual() {
        if alarmActive { endAlarm() } else { startAlarm(auto: false) }
    }

    private func startAlarm(auto: Bool) {
        guard !alarmActive else { return }
        alarmActive = true
        alarmSince = Date()
        alarmAuto = auto
        persistAlarm()
        let body = (mode == .always) ? "Увага! Штурмова тривога! Тітка в шкафу!" : "Тітка в небезпеці"
        post(title: "Штурмова тривога", body: body, sound: true, id: "start")
        scheduleTicks()
    }

    private func endAlarm() {
        guard alarmActive else { return }
        let dur = Date().timeIntervalSince(alarmSince ?? Date())
        alarmActive = false
        alarmSince = nil
        alarmAuto = false
        lastDuration = dur
        persistAlarm()
        cancelTicks()
        post(title: "Відбій тривоги", body: "Тривала \(fmtDuration(dur))", sound: true, id: "end")
    }

    private func persistAlarm() {
        defaults.set(alarmActive, forKey: "alarmActive")
        defaults.set(alarmSince, forKey: "alarmSince")
        defaults.set(alarmAuto, forKey: "alarmAuto")
        defaults.set(lastDuration, forKey: "lastDuration")
    }

    // MARK: сповіщення
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { self.notifAllowed = granted }
        }
    }

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { st in
            DispatchQueue.main.async { self.notifAllowed = (st.authorizationStatus == .authorized) }
        }
    }

    private func post(title: String, body: String, sound: Bool, id: String, delay: TimeInterval? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.threadIdentifier = "alarm"
        if sound { c.sound = .default }
        var trigger: UNNotificationTrigger? = nil
        if let delay = delay {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: trigger))
    }

    /// Сповіщення про тривалість заздалегідь планується в iOS, тому приходить, навіть коли програма закрита.
    private func scheduleTicks() {
        for m in tickMinutes {
            post(title: "Штурмова тривога", body: "Триває вже \(m) хв", sound: false,
                 id: "tick-\(m)", delay: TimeInterval(m * 60))
        }
    }

    private func cancelTicks() {
        let ids = tickMinutes.map { "tick-\($0)" }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
