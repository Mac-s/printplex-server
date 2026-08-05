import Foundation

/// Shells out to `vipsthumbnail` (libvips-tools) to produce a small, heavily
/// compressed JPEG copy of a photo for grid/browsing views — with ~200
/// projects in the library, loading every cover photo at full resolution is
/// what was making the grid slow to load.
///
/// Never throws: if vips isn't installed (e.g. local `swift run` on a
/// machine without it) or can't decode an exotic source format, callers fall
/// back to serving the original file so a missing codec never breaks the
/// image entirely — it just loses the size savings.
enum ImageThumbnailer {
    static func generateThumbnail(
        sourcePath: String, destinationPath: String,
        maxDimension: Int = 480, quality: Int = 78
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "vipsthumbnail", sourcePath,
            "--size", "\(maxDimension)",
            "--output", "\(destinationPath)[Q=\(quality),strip]",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
