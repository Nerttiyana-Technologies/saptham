// signpack: builds and checks sign-language dictionary packs (ADR 0003).
//
//   swift run signpack build <content folder> <new pack folder>
//   swift run signpack validate <pack folder>
//
// Hidden coupling 1: every form a pack lists is normalised with
// SapthamSigns' SignWordNormaliser here, at build time, and again by the app
// at lookup. Both import the same type, and the manifest stamps its version;
// the app refuses a pack built with another version. Changing the normaliser
// means bumping SignWordNormaliser.version and rebuilding every pack.
//
// Output names packs, files and counts only; never a sign's words.
import Foundation
import SapthamSigns
import SignPackBuilder

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("signpack: \(message)\n".utf8))
    exit(code)
}

func describe(_ pack: SignPack) -> String {
    let approved = pack.entries.filter { $0.reviewStatus == .approved }.count
    return "\(pack.manifest.packId): \(pack.entries.count) signs (\(approved) approved), \(pack.manifest.files.count) files"
}

let usage = """
usage: signpack build <content folder> <new pack folder>
       signpack validate <pack folder>
"""

let args = CommandLine.arguments.dropFirst().map { $0 }
switch args.first {
case "build" where args.count == 3:
    do {
        let pack = try await SignPackBuilder.build(content: URL(filePath: args[1]), output: URL(filePath: args[2]))
        print("built \(describe(pack))")
    } catch let error as SignPackBuildError {
        fail(error.description)
    } catch let error as SignPackError {
        fail("the built pack failed its own check: \(error)")
    } catch {
        fail(error.localizedDescription)
    }
case "validate" where args.count == 2:
    do {
        print("ok \(describe(try SignPackReader.open(URL(filePath: args[1]))))")
    } catch {
        fail("invalid pack: \(error)")
    }
default:
    fail(usage, code: 2)
}
