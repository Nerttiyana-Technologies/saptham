import Foundation

/// iPhone-only settings (UserDefaults keys; renaming one loses the choice).
enum PhoneSettings {
    /// Experimental: capture in stereo and show which side a voice comes
    /// from. Off by default; changes how the microphone is set up.
    static let soundDirection = "soundDirection"
    static let soundDirectionDefault = false

    static var soundDirectionValue: Bool {
        UserDefaults.standard.object(forKey: soundDirection) as? Bool ?? soundDirectionDefault
    }

    /// Show live captions on the Lock Screen and in the Dynamic Island.
    static let liveActivity = "liveActivity"
    static let liveActivityDefault = true

    static var liveActivityValue: Bool {
        UserDefaults.standard.object(forKey: liveActivity) as? Bool ?? liveActivityDefault
    }
}
