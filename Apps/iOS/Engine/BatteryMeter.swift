import Foundation
import Observation
import UIKit

/// Measures how much battery each captioning session used, so the real
/// cost can be read off rather than guessed. Battery level is only known
/// to 1 %, so a figure is given only for sessions of 10 minutes or more.
@MainActor
@Observable
final class BatteryMeter {
    struct Reading: Codable, Equatable, Identifiable {
        var id: Date { startedAt }
        let startedAt: Date
        let minutes: Double
        /// Percentage points of battery used.
        let used: Double
        /// While charging the figure means nothing; such sessions are kept out.
        var percentPerHour: Double { minutes > 0 ? used / minutes * 60 : 0 }
    }

    /// Newest first; the last 10 measurable sessions.
    private(set) var readings: [Reading] = []

    @ObservationIgnored private var start: (date: Date, level: Float)?
    @ObservationIgnored private static let key = "batteryReadings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Reading].self, from: data) {
            readings = saved
        }
    }

    func captioningStarted() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        start = level >= 0 && UIDevice.current.batteryState == .unplugged ? (Date(), level) : nil
    }

    func captioningStopped() {
        defer { start = nil }
        guard let start, UIDevice.current.batteryState == .unplugged else { return }
        let minutes = Date().timeIntervalSince(start.date) / 60
        let used = Double(start.level - UIDevice.current.batteryLevel) * 100
        guard minutes >= 10, used >= 0 else { return }
        readings.insert(Reading(startedAt: start.date, minutes: minutes, used: used), at: 0)
        readings = Array(readings.prefix(10))
        if let data = try? JSONEncoder().encode(readings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
