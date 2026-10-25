import Foundation

/// Finds any of the user's names in caption text. Pure logic, so it can be
/// tested without audio.
///
/// - Case, accents and width are ignored; a name must be whole words, so
///   "Ram" is not found in "Ramp".
/// - Tamil adds case endings to the name itself (சுரேஷ் → சுரேஷை,
///   சுரேஷுக்கு), and the ending replaces the final pulli (்). So a word in
///   a non-Latin script also matches when it starts with the name minus any
///   final pulli.
public struct NameSpotter: Sendable {
    private let names: [(original: String, words: [String])]

    /// - Parameter names: the user's names and other spellings of them,
    ///   e.g. ["Priya", "பிரியா"]. Blank entries are ignored.
    public init(names: [String]) {
        self.names = names.compactMap { name in
            let words = Self.words(in: name)
            return words.isEmpty ? nil : (name.trimmingCharacters(in: .whitespaces), words)
        }
    }

    /// The comma-separated form Settings saves.
    public init(list: String) {
        self.init(names: list.split(separator: ",").map(String.init))
    }

    public var isEmpty: Bool { names.isEmpty }

    /// The first name found in `text`, as the user typed it.
    public func firstName(in text: String) -> String? {
        let words = Self.words(in: text)
        for name in names where words.count >= name.words.count {
            for start in 0...(words.count - name.words.count) {
                let found = zip(name.words, words[start...]).allSatisfy(Self.matches)
                if found { return name.original }
            }
        }
        return nil
    }

    private static func matches(name: String, word: String) -> Bool {
        if name == word { return true }
        guard !name.unicodeScalars.contains(where: { $0.isASCII }) else { return false }
        let pulli: Unicode.Scalar = "\u{0BCD}"
        var stem = name.unicodeScalars
        guard stem.last == pulli else {
            // Three letters at least, so a short stem does not match every word.
            return stem.count >= 3 && word.unicodeScalars.starts(with: stem)
        }
        stem.removeLast()
        if stem.count >= 3 && word.unicodeScalars.starts(with: stem) { return true }
        // The Tamil recogniser often drops a final dead consonant: "சுரேஷ்"
        // comes out as "சுரே". Only as the whole word, so "சுரேந்திரன்"
        // does not match; names ending in a vowel are never cut ("பிரியா"
        // would become the word "பிரி").
        stem.removeLast()
        return stem.count >= 3 && word.unicodeScalars.elementsEqual(stem)
    }

    private static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

/// Watches caption lines from the chosen sources for the user's names and
/// raises an alert. Fed by CaptionSession's `lineHeard`; knows nothing of
/// audio or windows. Reads the names on each line, so edits in Settings
/// apply at once.
@MainActor
public final class NameAlerts {
    /// The alert shown when a name is heard. Not in SoundAlertKind.all: it
    /// comes from captions, not the sound classifier, and has its own setting.
    public static let kind = SoundAlertKind(
        id: "name", title: "Someone said your name", systemImage: "person.wave.2.fill",
        labels: [], threshold: 1, windowsInARow: 1, confusedByMusic: false, onByDefault: false)

    /// Told about each alert; set by the app once it can show them.
    public var onAlert: ((SoundAlert) -> Void)?
    /// One alert per this many seconds: a name in a partial line and again
    /// in its settled line (about 2 s later), or called twice in a row, is
    /// one alert. Kept short: at 20 s a second call 16 s later was missed.
    public var quietSeconds: TimeInterval = 5

    private let sourceIDs: Set<String>
    private let names: () -> String
    private var lastAlert: Date?

    /// - Parameters:
    ///   - sourceIDs: caption sources to watch (people in the room, not videos).
    ///   - names: the comma-separated names, read on every line.
    public init(sourceIDs: Set<String>, names: @escaping () -> String) {
        self.sourceIDs = sourceIDs
        self.names = names
    }

    public func hear(_ text: String, from sourceID: String, at time: Date = Date()) {
        guard sourceIDs.contains(sourceID) else { return }
        if let lastAlert, time.timeIntervalSince(lastAlert) < quietSeconds { return }
        let spotter = NameSpotter(list: names())
        guard !spotter.isEmpty, spotter.firstName(in: text) != nil else { return }
        lastAlert = time
        Diagnostics.engine.info("name alert from \(sourceID, privacy: .public)")
        onAlert?(SoundAlert(kind: Self.kind, confidence: 1, time: time))
    }
}
