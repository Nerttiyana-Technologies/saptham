import Foundation

/// User settings shared by the engine's composition root and the UI
/// (`@AppStorage(SapthamSettings.recordCalls)` etc.). Keys are persisted
/// in UserDefaults: renaming one loses the user's choice.
public enum SapthamSettings {
    /// Record call audio alongside transcripts. Off by default; the user
    /// turns it on once.
    public static let recordCalls = "recordCalls"
    public static let recordCallsDefault = false

    /// Listen for calls answered on this Mac whenever nothing else is being
    /// captioned, and show the caption window when one starts.
    public static let autoCaptionCalls = "autoCaptionCalls"
    public static let autoCaptionCallsDefault = true

    public static var autoCaptionCallsValue: Bool {
        UserDefaults.standard.object(forKey: autoCaptionCalls) as? Bool ?? autoCaptionCallsDefault
    }

    /// Days to keep transcripts and recordings; 0 keeps them forever.
    public static let keepDays = "transcriptKeepDays"
    public static let keepDaysDefault = 30
    public static let keepDaysChoices = [1, 7, 30, 90, 365, 0]

    public static var keepDaysValue: Int {
        UserDefaults.standard.object(forKey: keepDays) as? Int ?? keepDaysDefault
    }

    public static var recordCallsValue: Bool {
        UserDefaults.standard.object(forKey: recordCalls) as? Bool ?? recordCallsDefault
    }
}
