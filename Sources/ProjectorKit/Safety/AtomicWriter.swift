import Foundation

/// Writes a file atomically (temp file in the same directory + rename), with an
/// optional sibling backup of the previous contents.
enum AtomicWriter {
    static func write(_ text: String, to url: URL, backup: Bool) throws {
        let directory = url.deletingLastPathComponent()

        if backup, FileManager.default.fileExists(atPath: url.path) {
            let backupURL = url.appendingPathExtension("projector-backup")
            _ = try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: url, to: backupURL)
        }

        // Temp file must be on the same volume as the target for rename(2) to be
        // atomic, hence the same directory.
        let tempURL = directory.appendingPathComponent(".projector-\(ProcessInfo.processInfo.globallyUniqueString).tmp")
        do {
            try Data(text.utf8).write(to: tempURL, options: .atomic)
            // Replace target atomically.
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            _ = try? FileManager.default.removeItem(at: tempURL)
            throw ProjectorError.writeFailure(path: url.path, reason: String(describing: error))
        }
    }
}
