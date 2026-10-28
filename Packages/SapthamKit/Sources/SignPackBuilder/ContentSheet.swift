import Foundation

/// One row of `signs.csv`: one sense of one sign. Rows sharing an `idGloss`
/// are senses of the same sign and must agree on its clip and signer.
///
/// Columns (header names; order is free):
///
/// | Column | Required | Meaning |
/// |---|---|---|
/// | `idGloss` | yes | The sign's gloss, for example `WATER` |
/// | `forms:<lang>` | at least one | Written forms for that language, separated by `\|`, for example `forms:ta` |
/// | `clip` | yes | Video path inside the content folder |
/// | `signerId` | yes | Pseudonymous signer ID |
/// | `signerCredit` | yes | The credit the signer chose |
/// | `note` | no | The sense, for example "drinking water" |
/// | `poster`, `durationMs`, `lemmaId`, `variantOf`, `regionalTag`, `clipLicence` | no | As in `entries.json` |
/// | `reviewStatus` | no | `approved`, `draft` (default) or `rejected` |
struct ContentRow {
    /// 1-based line in `signs.csv`, for error messages.
    let line: Int
    let idGloss: String
    let lemmaId: String
    let note: String?
    /// Language and its forms, in column order.
    let forms: [(lang: String, text: [String])]
    let clip: String
    let poster: String?
    let durationMs: Int?
    let signerId: String
    let signerCredit: String
    let reviewStatus: String
    let variantOf: String?
    let regionalTag: String?
    let clipLicence: String?
}

enum ContentSheet {
    static let formsPrefix = "forms:"

    static func rows(from text: String) throws -> [ContentRow] {
        let table = try parseCSV(text)
        guard let header = table.first?.cells.map({ $0.trimmingCharacters(in: .whitespaces) }) else {
            throw SignPackBuildError.sheet(line: 1, "signs.csv is empty")
        }
        for required in ["idGloss", "clip", "signerId", "signerCredit"] where !header.contains(required) {
            throw SignPackBuildError.sheet(line: 1, "missing the \(required) column")
        }
        let formColumns = header.enumerated().filter { $0.element.hasPrefix(formsPrefix) }
        guard !formColumns.isEmpty else {
            throw SignPackBuildError.sheet(line: 1, "no forms:<language> column, for example forms:en")
        }

        return try table.dropFirst().compactMap { record in
            let cells = record.cells
            guard cells.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
            func value(_ name: String) -> String? {
                guard let i = header.firstIndex(of: name), i < cells.count else { return nil }
                let v = cells[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            func required(_ name: String) throws -> String {
                guard let v = value(name) else { throw SignPackBuildError.sheet(line: record.line, "\(name) is empty") }
                return v
            }
            let idGloss = try required("idGloss")
            let forms = formColumns.map { column -> (lang: String, text: [String]) in
                let raw = column.offset < cells.count ? cells[column.offset] : ""
                let text = raw.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return (String(column.element.dropFirst(formsPrefix.count)), text)
            }.filter { !$0.text.isEmpty }
            guard !forms.isEmpty else {
                throw SignPackBuildError.sheet(line: record.line, "\(idGloss) has no forms, so no word could reach it")
            }
            var duration: Int?
            if let raw = value("durationMs") {
                guard let ms = Int(raw), ms > 0 else {
                    throw SignPackBuildError.sheet(line: record.line, "durationMs must be a positive whole number")
                }
                duration = ms
            }
            let status = value("reviewStatus") ?? "draft"
            guard ["approved", "draft", "rejected"].contains(status) else {
                throw SignPackBuildError.sheet(line: record.line, "reviewStatus must be approved, draft or rejected")
            }
            return ContentRow(line: record.line, idGloss: idGloss, lemmaId: value("lemmaId") ?? idGloss,
                              note: value("note"), forms: forms, clip: try required("clip"), poster: value("poster"),
                              durationMs: duration, signerId: try required("signerId"),
                              signerCredit: try required("signerCredit"), reviewStatus: status,
                              variantOf: value("variantOf"), regionalTag: value("regionalTag"),
                              clipLicence: value("clipLicence"))
        }
    }

    struct Record {
        /// 1-based line where the record starts.
        let line: Int
        let cells: [String]
    }

    /// RFC 4180 CSV: quoted cells may hold commas, quotes ("") and line breaks.
    /// A leading byte-order mark, as spreadsheets write, is skipped.
    static func parseCSV(_ text: String) throws -> [Record] {
        var records: [Record] = []
        var cells: [String] = [], cell = "", quoted = false, afterQuote = false
        var line = 1, start = 1
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { cell.append("\""); i += 1 } else { quoted = false; afterQuote = true }
                } else {
                    if c == "\n" || c == "\r\n" { line += 1 }
                    cell.append(c)
                }
            } else if c == "\"" {
                guard cell.isEmpty, !afterQuote else { throw SignPackBuildError.sheet(line: line, "a quote in the middle of a cell") }
                quoted = true
            } else if c == "," {
                cells.append(cell); cell = ""; afterQuote = false
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                cells.append(cell)
                records.append(Record(line: start, cells: cells))
                cells = []; cell = ""; afterQuote = false
                line += 1; start = line
            } else {
                guard !afterQuote else { throw SignPackBuildError.sheet(line: line, "text after a closing quote") }
                cell.append(c)
            }
            i += 1
        }
        guard !quoted else { throw SignPackBuildError.sheet(line: start, "a quoted cell is never closed") }
        // The appended newline adds an empty last record when the file ended with one.
        while let last = records.last, last.cells.allSatisfy(\.isEmpty) { records.removeLast() }
        return records
    }
}
