import Foundation
import WhisperDropCore

/// The destination and its file references are committed together in history.json.
struct LibrarySnapshot: Codable {
    var savedFolder: URL
    var jobs: [TranscriptionJob]
    var pendingPreviousFolder: URL? = nil
    /// Renames committed with the job URLs that rely on them. Relaunch finishes an interrupted list.
    var pendingRenames: [SavedLibrary.Rename]? = nil
}

enum SavedLibrary {
    struct Transfer {
        let source: URL
        let destination: URL
        let digest: String
    }

    struct Migration {
        var jobs: [TranscriptionJob]
        var transfers: [Transfer] = []
        var roots: [URL] = []

        /// Called only after the library has committed the new references atomically.
        func finish() throws {
            let fm = FileManager.default
            for file in transfers where fm.fileExists(atPath: file.source.path) {
                guard try sha256File(file.source) == file.digest,
                      try sha256File(file.destination) == file.digest else {
                    throw AppFailure("A saved file changed while it was moving. Both copies were kept.")
                }
                try fm.removeItem(at: file.source)
            }
            for root in roots { try Self.removeEmptyFolders(root) }
        }

        private static func removeEmptyFolders(_ folder: URL) throws {
            let fm = FileManager.default
            guard fm.fileExists(atPath: folder.path) else { return }
            let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true { try removeEmptyFolders(child) }
            }
            if try fm.contentsOfDirectory(atPath: folder.path).isEmpty { try fm.removeItem(at: folder) }
        }
    }

    struct Rename: Codable, Equatable {
        var from: URL
        var to: URL
    }

    /// A title as a folder or file name. Finder shows a colon as a slash, so neither is kept.
    static func fileName(for title: String) -> String {
        var name = String(title.map { character -> Character in
            if character == "/" || character == "\\" { return "-" }
            if character == ":" { return "." }
            return character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) } ? " " : character
        }).trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        // Leaves room for a speaker suffix and an extension inside the 255-byte limit.
        while name.utf8.count > 200 { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Note" : name
    }

    /// The recordings the app wrote in a note's audio folder, with the speaker each holds when a note has two.
    /// Other files in the folder belong to the user and are left alone.
    static func recordings(in folder: URL) -> [(file: URL, speaker: Speaker?)] {
        let name = folder.lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard ["caf", AudioCompressor.fileExtension].contains(file.pathExtension.lowercased()) else { return nil }
            switch file.deletingPathExtension().lastPathComponent {
            case name: return (file, nil)
            case "you", "\(name) - \(Speaker.you.label)": return (file, .you)
            case "others", "\(name) - \(Speaker.others.label)": return (file, .others)
            default: return nil
            }
        }
    }

    /// The renames that give a note's folders and recordings the name of its title. Nothing changes on disk until `apply`.
    /// A second note with the same title gets a number after its name.
    static func naming(_ job: TranscriptionJob, as title: String) -> (job: TranscriptionJob, renames: [Rename]) {
        guard job.resolvedKind == .note else { return (job, []) }
        let fm = FileManager.default
        func sibling(_ folder: URL, _ name: String) -> URL { folder.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true) }
        var folders = [job.source]
        if let audio = job.audioFile, audio.standardizedFileURL.path != job.source.standardizedFileURL.path { folders.insert(audio, at: 0) }
        let base = fileName(for: title)
        var name = base, attempt = 1
        while folders.contains(where: { fm.fileExists(atPath: sibling($0, name).path) && !sameItem(sibling($0, name), $0) }) {
            attempt += 1
            name = "\(base) \(attempt)"
        }
        var renames: [Rename] = []
        if let audio = job.audioFile {
            let recordings = recordings(in: audio)
            let labeled = Set(recordings.compactMap(\.speaker)).count == 2
            for (file, speaker) in recordings {
                let stem = labeled ? speaker.map { "\(name) - \($0.label)" } ?? name : name
                let target = audio.appendingPathComponent(stem).appendingPathExtension(file.pathExtension)
                if file.lastPathComponent != target.lastPathComponent, !fm.fileExists(atPath: target.path) { renames.append(Rename(from: file, to: target)) }
            }
        }
        renames += folders.filter { $0.lastPathComponent != name }.map { Rename(from: $0, to: sibling($0, name)) }
        var named = job
        named.source = sibling(job.source, name)
        if let audio = job.audioFile { named.audioFile = sibling(audio, name) }
        return (named, renames)
    }

    /// A step that already happened is skipped, so an interrupted list can be applied again.
    static func apply(_ renames: [Rename]) throws {
        let fm = FileManager.default
        for rename in renames where fm.fileExists(atPath: rename.from.path) {
            if fm.fileExists(atPath: rename.to.path) {
                // The same folder under another letter case keeps its name on a case-insensitive disk.
                if sameItem(rename.from, rename.to) { continue }
                throw AppFailure("A different item already exists at \(rename.to.path). Nothing was replaced.")
            }
            try fm.moveItem(at: rename.from, to: rename.to)
        }
    }

    /// Puts back the steps of a list that failed part way.
    static func revert(_ renames: [Rename]) {
        let fm = FileManager.default
        for rename in renames.reversed() where fm.fileExists(atPath: rename.to.path) && !fm.fileExists(atPath: rename.from.path) {
            try? fm.moveItem(at: rename.to, to: rename.from)
        }
    }

    private static func sameItem(_ first: URL, _ second: URL) -> Bool {
        guard let one = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let other = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return one.isEqual(other)
    }

    static func prepare(_ folder: URL) throws {
        guard folder.isFileURL else { throw AppFailure("Choose a folder on this Mac or a mounted drive.") }
        for name in ["Audio", "Transcripts"] {
            let child = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            guard FileManager.default.isWritableFile(atPath: child.path) else {
                throw AppFailure("WhisperDrop cannot write to \(child.path). Choose another folder.")
            }
        }
    }

    /// Copy and verify first. The caller commits history before removing any source files.
    static func migrate(jobs: [TranscriptionJob], from old: URL?, legacyRoot: URL?, to destination: URL) throws -> Migration {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let sources = [old, legacyRoot?.appendingPathComponent("Notes"), legacyRoot?.appendingPathComponent("Transcripts")].compactMap { $0 }
        for source in sources {
            let source = source.standardizedFileURL.resolvingSymlinksInPath()
            if source != target && (contains(target, in: source) || contains(source, in: target)) {
                throw AppFailure("Choose a separate folder, outside the current saved files and app data.")
            }
        }
        try prepare(target)
        var result = Migration(jobs: jobs)
        if let old, old.standardizedFileURL.resolvingSymlinksInPath() != target {
            for name in ["Audio", "Transcripts"] {
                let source = old.appendingPathComponent(name, isDirectory: true)
                try copyTree(source, to: target.appendingPathComponent(name, isDirectory: true), result: &result)
                result.roots.append(source)
            }
            for index in result.jobs.indices {
                result.jobs[index].source = remap(result.jobs[index].source, from: old, to: target)
                if let audio = result.jobs[index].audioFile { result.jobs[index].audioFile = remap(audio, from: old, to: target) }
            }
        }
        if let legacyRoot {
            let notes = legacyRoot.appendingPathComponent("Notes", isDirectory: true)
            let audio = target.appendingPathComponent("Audio", isDirectory: true)
            let transcripts = target.appendingPathComponent("Transcripts", isDirectory: true)
            if FileManager.default.fileExists(atPath: notes.path) {
                for note in try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                    let values = try note.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    for file in try FileManager.default.contentsOfDirectory(at: note, includingPropertiesForKeys: nil) {
                        let parent = MediaInput.extensions.contains(file.pathExtension.lowercased()) ? audio : transcripts
                        try copyTree(file, to: parent.appendingPathComponent(note.lastPathComponent, isDirectory: true).appendingPathComponent(file.lastPathComponent), result: &result)
                    }
                }
                result.roots.append(notes)
            }
            try copyTree(legacyRoot.appendingPathComponent("Transcripts", isDirectory: true), to: transcripts, result: &result)
            result.roots.append(legacyRoot.appendingPathComponent("Transcripts", isDirectory: true))
            for index in result.jobs.indices {
                if result.jobs[index].resolvedKind == .note, contains(result.jobs[index].source, in: notes) {
                    result.jobs[index].source = remap(result.jobs[index].source, from: notes, to: transcripts)
                } else {
                    result.jobs[index].source = remap(result.jobs[index].source, from: notes, to: audio)
                }
                if let file = result.jobs[index].audioFile { result.jobs[index].audioFile = remap(file, from: notes, to: audio) }
            }
        }
        return result
    }

    static func archive(_ job: TranscriptionJob, in folder: URL, preserveExistingRecovery: Bool = false) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = job.resolvedKind == .note ? TranscriptOutput.labeledText(job.segments, eachSentence: job.sentenceParagraphs == true) : job.transcript
        try text.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try TranscriptOutput.subtitles(job.segments, vtt: false).write(to: folder.appendingPathComponent("transcript.srt"), atomically: true, encoding: .utf8)
        try TranscriptOutput.subtitles(job.segments, vtt: true).write(to: folder.appendingPathComponent("transcript.vtt"), atomically: true, encoding: .utf8)
        let recovery = folder.appendingPathComponent("transcript.json")
        if job.resolvedKind == .note, !preserveExistingRecovery || !FileManager.default.fileExists(atPath: recovery.path) {
            try JSONEncoder().encode(job.segments).write(to: recovery, options: .atomic)
        }
    }

    private static func copyTree(_ source: URL, to destination: URL, result: inout Migration) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AppFailure("A saved folder contains a symbolic link. Its original files were kept.") }
        if values.isDirectory == true {
            for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try copyTree(file, to: destination.appendingPathComponent(file.lastPathComponent), result: &result)
            }
        } else {
            let digest = try sha256File(source)
            if fm.fileExists(atPath: destination.path) {
                guard try sha256File(destination) == digest else {
                    throw AppFailure("A different file already exists at \(destination.path). No original files were removed.")
                }
            } else {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(".moving-\(UUID().uuidString)")
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: source, to: temporary)
                guard try sha256File(temporary) == digest else { throw AppFailure("The saved file copy could not be verified. Its original was kept.") }
                try fm.moveItem(at: temporary, to: destination)
            }
            result.transfers.append(Transfer(source: source, destination: destination, digest: digest))
        }
    }

    private static func contains(_ file: URL, in folder: URL) -> Bool {
        let path = file.standardizedFileURL.path
        let root = folder.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private static func remap(_ file: URL, from source: URL, to destination: URL) -> URL {
        guard file.isFileURL, contains(file, in: source) else { return file }
        let suffix = String(file.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count))
        return URL(fileURLWithPath: destination.path + suffix, isDirectory: file.hasDirectoryPath)
    }
}
