import Foundation
import SapthamSigns

/// Settings' words for one pack (ADR 0003 §2.9), the same on iPhone and Mac.
extension SignPackListing.Row {
    /// For example "US / English Canada · Suggested for your region · 92 MB · In use".
    var detail: String {
        var parts: [String] = []
        if !variety.isEmpty { parts.append(variety) }
        if isSuggested { parts.append("Suggested for your region") }
        if let bytes { parts.append(bytes.formatted(.byteCount(style: .file))) }
        parts.append(status)
        return parts.joined(separator: " · ")
    }

    var status: String {
        switch state {
        case .ready: isActive ? "In use" : "Downloaded"
        case .damaged(let error): error.userMessage
        case .notDownloaded: "Not downloaded"
        }
    }

    var isReady: Bool {
        if case .ready = state { true } else { false }
    }

    var isInstalled: Bool {
        if case .notDownloaded = state { false } else { true }
    }

    var pack: SignPack? {
        if case .ready(let pack) = state { pack } else { nil }
    }
}
