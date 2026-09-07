//
//  WeatherManager.swift
//  CNotch
//
//  Fetches current weather via Open-Meteo (no API key required) for the
//  device's current location. Opt-in: only starts once the user enables
//  it in Settings, since it needs Location access.
//

import CoreLocation
import Foundation

final class WeatherManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherManager()

    @Published private(set) var temperatureCelsius: Double?
    @Published private(set) var symbolName: String = "cloud"

    private let locationManager = CLLocationManager()
    private var refreshTimer: Timer?
    private var isRunning = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.locationManager.requestLocation()
        }
    }

    func stop() {
        isRunning = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        locationManager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isRunning else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { await fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silently ignore -- the header just omits the weather chip.
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        let current: Current
    }

    private func fetchWeather(latitude: Double, longitude: Double) async {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
        ]
        guard let url = components.url else { return }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        else { return }

        await MainActor.run {
            self.temperatureCelsius = response.current.temperature_2m
            self.symbolName = Self.symbolName(forWMOCode: response.current.weather_code)
        }
    }

    /// Maps a WMO weather code (https://open-meteo.com/en/docs) to an SF Symbol.
    private static func symbolName(forWMOCode code: Int) -> String {
        switch code {
        case 0: return "sun.max"
        case 1, 2, 3: return "cloud.sun"
        case 45, 48: return "cloud.fog"
        case 51, 53, 55, 56, 57: return "cloud.drizzle"
        case 61, 63, 65, 66, 67: return "cloud.rain"
        case 71, 73, 75, 77: return "cloud.snow"
        case 80, 81, 82: return "cloud.heavyrain"
        case 85, 86: return "cloud.snow"
        case 95, 96, 99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }
}
