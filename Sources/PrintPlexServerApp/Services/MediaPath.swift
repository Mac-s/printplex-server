import Vapor
import PrintPlexCore

/// Defense in depth: never resolve a path outside the mounted media root
/// (every configured library lives under it, by construction). Shared by
/// FileController (downloads/thumbnails) and ShopifyController (attaching a
/// project's own photos to a duplicated product).
enum MediaPath {
    static func safePath(for file: FileModel, in config: AppConfig) throws -> String {
        let standardized = URL(fileURLWithPath: file.path).standardizedFileURL.path
        guard standardized == config.mediaPath || standardized.hasPrefix(config.mediaPath + "/") else {
            throw Abort(.forbidden, reason: "Chemin hors du répertoire média")
        }
        return standardized
    }
}
