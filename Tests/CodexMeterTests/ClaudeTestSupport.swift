import Foundation

/// A new empty folder for one test. Symlinks are resolved, so its paths compare equal to
/// the ones the code under test builds from it.
func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "CodexMeterTests-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
