import Foundation
import Testing
import SapthamSigns
@testable import SignPackBuilder

/// A content folder as a Deaf partner would hand it over, with made-up clip
/// bytes. `durationMs` is given, since these bytes aren't real video.
struct TestContent {
    let root: URL
    var content: URL { root.appending(path: "content") }
    var output: URL { root.appending(path: "out") }

    static let packJSON = """
    { "packId": "ase-US-commissioned-2027.1", "signLanguage": "ase", "signLanguageName": "American Sign Language",
      "variety": "US / English Canada (not LSQ)", "region": "US", "defaultForRegions": ["US", "CA"],
      "headwordLanguages": ["en", "ta"],
      "source": { "organisation": "Commissioned by Nerttiyana Technologies", "kind": "commissioned" },
      "licenceId": "LicenseRef-Saptham-Commissioned-1", "version": "2027.1", "minAppVersion": "1.4" }
    """

    static let sheet = """
    idGloss,note,forms:en,forms:ta,clip,poster,durationMs,signerId,signerCredit,reviewStatus
    WATER,drinking water,water|waters,தண்ணீர்|தண்ணி|வாட்டர்,clips/water.mp4,clips/water.jpg,1800,S03,Signed by S03,approved
    BANK,money,bank,பேங்க்,clips/bank.mp4,,1500,S01,"Signed by Priya, Chennai",
    BANK,river,bank|riverbank,,clips/bank.mp4,,1500,S01,"Signed by Priya, Chennai",

    """

    init(sheet: String = TestContent.sheet, packJSON: String = TestContent.packJSON) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "signcontent-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "content/clips"), withIntermediateDirectories: true)
        try Data(packJSON.utf8).write(to: content.appending(path: "pack.json"))
        try Data(sheet.utf8).write(to: content.appending(path: "signs.csv"))
        try Data("Commissioning terms summary.\n".utf8).write(to: content.appending(path: "LICENSE.txt"))
        for name in ["water.mp4", "water.jpg", "bank.mp4"] {
            try Data((0..<300).map { _ in UInt8.random(in: 0...255) }).write(to: content.appending(path: "clips/\(name)"))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

struct SignPackBuilderTests {
    @Test func buildsAPackTheAppCanOpen() async throws {
        let t = try TestContent()
        defer { t.remove() }
        let built = try await SignPackBuilder.build(content: t.content, output: t.output)
        // Opened again from disk, the way the app will.
        let pack = try SignPackReader.open(t.output)
        #expect(pack.manifest == built.manifest)
        #expect(pack.manifest.normaliserVersion == SignWordNormaliser.version)
        #expect(pack.manifest.contentUse == .displayOnly)
        #expect(pack.entries.map(\.idGloss) == ["WATER", "BANK"])
        #expect(pack.entries[1].senses.map(\.note) == ["money", "river"])
        #expect(pack.entries[0].media == SignMedia(file: "media/water.mp4", poster: "media/water.jpg", durationMs: 1800, loop: true))
        #expect(pack.entries[0].reviewStatus == .approved)
        #expect(pack.entries[1].reviewStatus == .draft)
        #expect(pack.manifest.files.map(\.path) == ["LICENSE.txt", "credits.txt", "entries.json",
                                                    "media/bank.mp4", "media/water.jpg", "media/water.mp4"])
    }

    @Test func writesCredits() async throws {
        let t = try TestContent()
        defer { t.remove() }
        _ = try await SignPackBuilder.build(content: t.content, output: t.output)
        let credits = try String(contentsOf: t.output.appending(path: "credits.txt"), encoding: .utf8)
        #expect(credits.contains("American Sign Language (US / English Canada (not LSQ))"))
        #expect(credits.contains("Licence: LicenseRef-Saptham-Commissioned-1"))
        #expect(credits.contains("Not yet reviewed by a Deaf panel. Draft."))
        #expect(credits.contains("Signed by S03\nSigned by Priya, Chennai\n"))
        #expect(credits.components(separatedBy: "Signed by Priya").count == 2)
    }

    @Test func aBuiltPackFindsItsWords() async throws {
        let t = try TestContent()
        defer { t.remove() }
        let lookup = SignLookup(pack: try await SignPackBuilder.build(content: t.content, output: t.output),
                                includeUnapproved: true)
        #expect(await lookup.signs(for: "வாட்டர்").map(\.entry.idGloss) == ["WATER"])
        #expect(await lookup.signs(for: "bank").count == 2)
    }

    @Test func refusesAnExistingOutputFolder() async throws {
        let t = try TestContent()
        defer { t.remove() }
        try FileManager.default.createDirectory(at: t.output, withIntermediateDirectories: true)
        await #expect(throws: SignPackBuildError.self) { try await SignPackBuilder.build(content: t.content, output: t.output) }
    }

    @Test func leavesNothingBehindOnFailure() async throws {
        let t = try TestContent()
        defer { t.remove() }
        try FileManager.default.removeItem(at: t.content.appending(path: "clips/bank.mp4"))
        await #expect(throws: SignPackBuildError.sheet(line: 3, "clips/bank.mp4 isn't in the content folder")) {
            try await SignPackBuilder.build(content: t.content, output: t.output)
        }
        #expect(!FileManager.default.fileExists(atPath: t.output.path(percentEncoded: false)))
    }

    @Test func refusesSensesThatDisagreeOnTheSign() async throws {
        let sheet = TestContent.sheet.replacingOccurrences(of: "river,bank|riverbank,,clips/bank.mp4,,1500,S01",
                                                           with: "river,bank|riverbank,,clips/bank.mp4,,1500,S02")
        let t = try TestContent(sheet: sheet)
        defer { t.remove() }
        await #expect(throws: SignPackBuildError.self) { try await SignPackBuilder.build(content: t.content, output: t.output) }
    }

    @Test func refusesALanguageThePackDoesntList() async throws {
        let t = try TestContent(sheet: "idGloss,forms:hi,clip,durationMs,signerId,signerCredit\nWATER,पानी,clips/water.mp4,1800,S03,S03\n")
        defer { t.remove() }
        await #expect(throws: SignPackBuildError.sheet(line: 2, "forms:hi isn't in pack.json headwordLanguages [\"en\", \"ta\"]")) {
            try await SignPackBuilder.build(content: t.content, output: t.output)
        }
    }

    @Test func refusesTheSameFormTwiceInOneLanguage() async throws {
        let t = try TestContent(sheet: "idGloss,forms:en,clip,durationMs,signerId,signerCredit\nWATER,water|Water!,clips/water.mp4,1800,S03,S03\n")
        defer { t.remove() }
        await #expect(throws: SignPackBuildError.self) { try await SignPackBuilder.build(content: t.content, output: t.output) }
    }

    @Test func allowsTheSameFormInTwoLanguages() async throws {
        let t = try TestContent(sheet: "idGloss,forms:en,forms:ta,clip,durationMs,signerId,signerCredit\nOK,ok,ok|ஓகே,clips/water.mp4,900,S03,S03\n")
        defer { t.remove() }
        #expect(try await SignPackBuilder.build(content: t.content, output: t.output).entries.count == 1)
    }

    @Test func refusesAClipPathOutsideTheContent() async throws {
        let t = try TestContent(sheet: "idGloss,forms:en,clip,durationMs,signerId,signerCredit\nWATER,water,../secret.mp4,1800,S03,S03\n")
        defer { t.remove() }
        await #expect(throws: SignPackBuildError.sheet(line: 2, "\"../secret.mp4\" must be a path inside the content folder")) {
            try await SignPackBuilder.build(content: t.content, output: t.output)
        }
    }

    @Test func refusesAClipItCantMeasure() async throws {
        let t = try TestContent(sheet: "idGloss,forms:en,clip,signerId,signerCredit\nWATER,water,clips/water.mp4,S03,S03\n")
        defer { t.remove() }
        await #expect(throws: SignPackBuildError.sheet(line: 2, "couldn't read the clip's length; add a durationMs column")) {
            try await SignPackBuilder.build(content: t.content, output: t.output)
        }
    }

    @Test func refusesAMissingPackJSONField() async throws {
        let t = try TestContent(packJSON: "{ \"packId\": \"x\" }")
        defer { t.remove() }
        await #expect(throws: SignPackBuildError.content("pack.json is missing a field or isn't valid JSON")) {
            try await SignPackBuilder.build(content: t.content, output: t.output)
        }
    }
}

struct ContentSheetTests {
    @Test func readsQuotedCellsAndSpreadsheetBOM() throws {
        let csv = "\u{FEFF}idGloss,note,forms:en,clip,signerId,signerCredit\r\nHELLO,\"a greeting, \"\"hi\"\"\",hello,c.mp4,S1,\"Signed by A\nand B\"\r\n"
        let rows = try ContentSheet.rows(from: csv)
        #expect(rows.count == 1)
        #expect(rows.first?.note == "a greeting, \"hi\"")
        #expect(rows.first?.signerCredit == "Signed by A\nand B")
        #expect(rows.first?.reviewStatus == "draft")
    }

    @Test func skipsBlankLinesAndReportsTheRightLine() throws {
        let csv = "idGloss,forms:en,clip,signerId,signerCredit\n\nHELLO,hello,c.mp4,S1,A\n\nTEA,,c2.mp4,S1,A\n"
        #expect(throws: SignPackBuildError.sheet(line: 5, "TEA has no forms, so no word could reach it")) {
            try ContentSheet.rows(from: csv)
        }
    }

    @Test func needsTheRequiredColumns() {
        #expect(throws: SignPackBuildError.sheet(line: 1, "missing the signerCredit column")) {
            try ContentSheet.rows(from: "idGloss,forms:en,clip,signerId\nA,a,c.mp4,S1\n")
        }
        #expect(throws: SignPackBuildError.sheet(line: 1, "no forms:<language> column, for example forms:en")) {
            try ContentSheet.rows(from: "idGloss,clip,signerId,signerCredit\nA,c.mp4,S1,A\n")
        }
    }

    @Test func rejectsBadValues() {
        #expect(throws: SignPackBuildError.self) {
            try ContentSheet.rows(from: "idGloss,forms:en,clip,signerId,signerCredit,reviewStatus\nA,a,c.mp4,S1,A,maybe\n")
        }
        #expect(throws: SignPackBuildError.self) {
            try ContentSheet.rows(from: "idGloss,forms:en,clip,signerId,signerCredit,durationMs\nA,a,c.mp4,S1,A,-4\n")
        }
        #expect(throws: SignPackBuildError.sheet(line: 2, "a quoted cell is never closed")) {
            try ContentSheet.rows(from: "idGloss,forms:en,clip,signerId,signerCredit\nA,\"a,c.mp4,S1,A\n")
        }
    }
}

struct TestPatternContentTests {
    @Test func generatesRealClipsThatBuildIntoAPack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "testpattern-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try await TestPatternContent.write(to: root.appending(path: "content"))
        // No durationMs column: the builder measures the generated HEVC clips.
        let pack = try await SignPackBuilder.build(content: root.appending(path: "content"), output: root.appending(path: "pack"))
        #expect(pack.entries.count == 4)
        #expect(pack.entries.allSatisfy { abs($0.media.durationMs - 1200) <= 70 })
    }
}
