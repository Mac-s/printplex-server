import Fluent
import Foundation
import PrintPlexCore

/// A configured scan root — Plex-style: the container mounts one generic
/// media volume (`AppConfig.mediaPath`), and the user picks specific folders
/// under it as "libraries" from the Settings UI, instead of the server having
/// a single hardcoded scan root fixed at boot via an environment variable.
final class LibraryModel: Model, @unchecked Sendable {
    static let schema = "libraries"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    /// Relative to `AppConfig.mediaPath` — never stored as an absolute path,
    /// so the config stays portable across containers/hosts. Empty string
    /// means "the whole media root is this one library".
    @Field(key: "relative_path") var relativePath: String
    @Field(key: "date_added") var dateAdded: Date
    @Field(key: "sort_order") var sortOrder: Int

    init() {}

    init(id: UUID = UUID(), name: String, relativePath: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.dateAdded = Date()
        self.sortOrder = sortOrder
    }

    /// Absolute path on disk, computed from the current media root — never persisted.
    func absolutePath(mediaPath: String) -> String {
        relativePath.isEmpty
            ? mediaPath
            : URL(fileURLWithPath: mediaPath).appendingPathComponent(relativePath).standardizedFileURL.path
    }

    func toDTO() -> LibraryDTO {
        LibraryDTO(id: id ?? UUID(), name: name, relativePath: relativePath, dateAdded: dateAdded)
    }
}
