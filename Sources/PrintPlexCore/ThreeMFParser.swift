import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CZlib

// MARK: - Private 3D vector

private struct Vec3 {
    let x, y, z: Double

    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(x: a.x-b.x, y: a.y-b.y, z: a.z-b.z) }

    func dot(_ o: Vec3) -> Double { x*o.x + y*o.y + z*o.z }

    func cross(_ o: Vec3) -> Vec3 {
        Vec3(x: y*o.z - z*o.y, y: z*o.x - x*o.z, z: x*o.y - y*o.x)
    }

    var length: Double { (x*x + y*y + z*z).squareRoot() }
}

// MARK: - Minimal ZIP reader

private struct ZipReader {
    let data: Data

    func u16(_ i: Int) -> UInt16 {
        UInt16(data[i]) | UInt16(data[i+1]) << 8
    }
    func u32(_ i: Int) -> UInt32 {
        UInt32(data[i]) | UInt32(data[i+1]) << 8 |
        UInt32(data[i+2]) << 16 | UInt32(data[i+3]) << 24
    }

    struct EOCD { let entries: Int; let cdOffset: Int }

    func findEOCD() -> EOCD? {
        guard data.count >= 22 else { return nil }
        let searchFrom = max(0, data.count - 65558)
        for i in stride(from: data.count - 22, through: searchFrom, by: -1) {
            guard i + 22 <= data.count else { continue }
            guard data[i] == 0x50, data[i+1] == 0x4B,
                  data[i+2] == 0x05, data[i+3] == 0x06 else { continue }
            return EOCD(entries: Int(u16(i+8)), cdOffset: Int(u32(i+16)))
        }
        return nil
    }

    struct CDEntry {
        let filename: String
        let compression: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localOffset: Int
        let totalSize: Int
    }

    func cdEntry(at off: Int) -> CDEntry? {
        guard off + 46 <= data.count,
              data[off] == 0x50, data[off+1] == 0x4B,
              data[off+2] == 0x01, data[off+3] == 0x02 else { return nil }
        let comp  = u16(off+10)
        let csz   = u32(off+20)
        let usz   = u32(off+24)
        let fnLen = Int(u16(off+28))
        let exLen = Int(u16(off+30))
        let cmLen = Int(u16(off+32))
        let loff  = Int(u32(off+42))
        guard off + 46 + fnLen <= data.count else { return nil }
        let fnData = data[(off+46)..<(off+46+fnLen)]
        let name = String(data: fnData, encoding: .utf8)
                ?? String(data: fnData, encoding: .isoLatin1)
                ?? ""
        return CDEntry(filename: name, compression: comp,
                       compressedSize: csz, uncompressedSize: usz,
                       localOffset: loff, totalSize: 46 + fnLen + exLen + cmLen)
    }

    func extract(_ entry: CDEntry) throws -> Data {
        let o = entry.localOffset
        guard o + 30 <= data.count,
              data[o] == 0x50, data[o+1] == 0x4B,
              data[o+2] == 0x03, data[o+3] == 0x04 else { throw ThreeMFParser.Failure.badZip }
        let fnLen = Int(u16(o+26))
        let exLen = Int(u16(o+28))
        let start = o + 30 + fnLen + exLen
        let end   = start + Int(entry.compressedSize)
        guard end <= data.count else { throw ThreeMFParser.Failure.badZip }
        let raw = data[start..<end]
        switch entry.compression {
        case 0: return Data(raw)
        case 8: return try inflateRaw(Data(raw), expecting: Int(entry.uncompressedSize))
        default: throw ThreeMFParser.Failure.unsupportedCompression
        }
    }

    // Raw DEFLATE decompression using zlib with windowBits = -15 (no zlib header/trailer).
    // ZIP method 8 stores raw DEFLATE — negative windowBits is the standard way to handle it.
    private func inflateRaw(_ input: Data, expecting expectedSize: Int) throws -> Data {
        var capacity = max(expectedSize, input.count * 4, 4096)

        for _ in 0..<4 {
            var output = Data(count: capacity)
            var written = 0

            let status: Int32 = input.withUnsafeBytes { srcBuf in
                output.withUnsafeMutableBytes { dstBuf -> Int32 in
                    guard let src = srcBuf.baseAddress?.assumingMemoryBound(to: Bytef.self),
                          let dst = dstBuf.baseAddress?.assumingMemoryBound(to: Bytef.self)
                    else { return Z_STREAM_ERROR }

                    var stream = z_stream()
                    stream.next_in   = UnsafeMutablePointer(mutating: src)
                    stream.avail_in  = uInt(input.count)
                    stream.next_out  = dst
                    stream.avail_out = uInt(capacity)

                    guard inflateInit2_(&stream, -15, ZLIB_VERSION,
                                        Int32(MemoryLayout<z_stream>.size)) == Z_OK
                    else { return Z_STREAM_ERROR }
                    defer { inflateEnd(&stream) }

                    let ret = inflate(&stream, Z_FINISH)
                    written = capacity - Int(stream.avail_out)
                    return ret
                }
            }

            if status == Z_STREAM_END { return output.prefix(written) }
            if status == Z_OK || status == Z_BUF_ERROR { capacity *= 2; continue }
            throw ThreeMFParser.Failure.decompression
        }

        throw ThreeMFParser.Failure.decompression
    }
}

// MARK: - Geometry SAX delegate
// Streams vertices/triangles; only processes objects with type="model" (skips modifiers, support
// blockers/enforcers). Each <mesh> resets per-mesh vertex indexing for multi-object files.

private final class MeshDelegate: NSObject, XMLParserDelegate {
    var vertices: [Vec3] = []
    var volumeSum:    Double = 0
    var surfaceSum:   Double = 0
    var triangleCount = 0
    var minX =  Double.infinity, minY =  Double.infinity, minZ =  Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity, maxZ = -Double.infinity

    private var meshVertexStart = 0
    private var inModelObject = true
    private var inV = false
    private var inT = false

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        switch el {
        case "object":
            inModelObject = (a["type"] ?? "model").lowercased() == "model"
            inV = false; inT = false
        case "mesh" where inModelObject:
            meshVertexStart = vertices.count
            inV = false; inT = false
        case "vertices"  where inModelObject: inV = true
        case "triangles" where inModelObject: inT = true
        case "vertex" where inV:
            guard let x = Double(a["x"] ?? ""),
                  let y = Double(a["y"] ?? ""),
                  let z = Double(a["z"] ?? "") else { return }
            vertices.append(Vec3(x: x, y: y, z: z))
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
            if z < minZ { minZ = z }; if z > maxZ { maxZ = z }
        case "triangle" where inT:
            guard let r1 = Int(a["v1"] ?? ""),
                  let r2 = Int(a["v2"] ?? ""),
                  let r3 = Int(a["v3"] ?? "") else { return }
            let i1 = meshVertexStart + r1
            let i2 = meshVertexStart + r2
            let i3 = meshVertexStart + r3
            guard i1 < vertices.count, i2 < vertices.count, i3 < vertices.count else { return }
            let v1 = vertices[i1], v2 = vertices[i2], v3 = vertices[i3]
            volumeSum  += v1.dot(v2.cross(v3)) / 6.0
            surfaceSum += (v2 - v1).cross(v3 - v1).length / 2.0
            triangleCount += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "object":    inModelObject = true; inV = false; inT = false
        case "vertices":  inV = false
        case "triangles": inT = false
        default: break
        }
    }
}

// MARK: - BambuStudio plate config delegate
// Parses Metadata/model_settings.config to detect multi-plate files and identify
// which scene object IDs (and how many instances) belong to each plate.

private final class PlateConfigDelegate: NSObject, XMLParserDelegate {
    /// plateIndex → sceneObjectId → number of instances on that plate
    var objectsByPlate: [Int: [Int: Int]] = [:]
    var plateCount = 1
    private var currentObjectId: Int? = nil

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        if el == "object" {
            currentObjectId = Int(a["id"] ?? "")
        }
        if el == "metadata",
           a["key"] == "plate_index",
           let value = a["value"],
           let plateIdx = Int(value),
           let objId = currentObjectId {
            plateCount = max(plateCount, plateIdx + 1)
            objectsByPlate[plateIdx, default: [:]][objId, default: 0] += 1
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "object" { currentObjectId = nil }
    }
}

// MARK: - Scene structure delegate
// Parses 3D/3dmodel.model to extract scene object ID → component file path mappings
// (production extension: each scene object references a geometry file via <component p:path="…">).

private final class SceneDelegate: NSObject, XMLParserDelegate {
    /// sceneObjectId → [component file paths]
    var componentsByObjectId: [Int: [String]] = [:]
    private var currentObjectId: Int? = nil

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        if el == "object" { currentObjectId = Int(a["id"] ?? "") }
        if el == "component", let objId = currentObjectId {
            // The production extension uses p:path (or prod:path with a different prefix);
            // fall back to scanning all attributes for a .model value.
            let path = a["p:path"] ?? a["prod:path"] ?? a["path"]
                ?? a.values.first(where: { $0.lowercased().hasSuffix(".model") })
            if let path { componentsByObjectId[objId, default: []].append(path) }
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        if el == "object" { currentObjectId = nil }
    }
}

// MARK: - Public API

public enum ThreeMFParser {

    public enum Failure: LocalizedError {
        case badZip, noModelFile, unsupportedCompression, decompression, badXML, emptyMesh

        public var errorDescription: String? {
            switch self {
            case .badZip:                 return "Archive .3MF invalide ou corrompue"
            case .noModelFile:            return "Fichier de modèle introuvable dans l'archive"
            case .unsupportedCompression: return "Algorithme de compression non supporté"
            case .decompression:          return "Echec de la décompression"
            case .badXML:                 return "Le XML du modèle est malformé"
            case .emptyMesh:              return "Le modèle ne contient aucune géométrie"
            }
        }
    }

    public struct Result: Sendable {
        public let volumeMM3:      Double
        public let surfaceAreaMM2: Double
        public let widthMM:  Double
        public let heightMM: Double
        public let depthMM:  Double
        public let triangleCount: Int
        public let vertexCount:   Int
        /// Number of print plates detected. 1 = standard 3MF or single-plate BambuStudio file.
        public let plateCount: Int
        /// Which plate (0-based) this Result describes. Always 0 for standard 3MF files.
        public let plateIndex: Int

        public init(volumeMM3: Double, surfaceAreaMM2: Double,
                    widthMM: Double, heightMM: Double, depthMM: Double,
                    triangleCount: Int, vertexCount: Int, plateCount: Int, plateIndex: Int = 0) {
            self.volumeMM3 = volumeMM3
            self.surfaceAreaMM2 = surfaceAreaMM2
            self.widthMM = widthMM
            self.heightMM = heightMM
            self.depthMM = depthMM
            self.triangleCount = triangleCount
            self.vertexCount = vertexCount
            self.plateCount = plateCount
            self.plateIndex = plateIndex
        }
    }

    /// Parses a .3MF file and returns geometry statistics for plate 0 only (or the whole
    /// model for standard 3MF files with no plate concept). Kept for callers that only
    /// care about a single result; see `parseAllPlates` for full multi-plate support.
    /// CPU-bound — call from a background task.
    public static func parse(_ url: URL) throws -> Result {
        let zipData = try Data(contentsOf: url)
        return try parse(data: zipData)
    }

    /// Same as `parse(_:)` but from in-memory data (useful for server streaming).
    public static func parse(data zipData: Data) throws -> Result {
        let all = try parseAllPlates(data: zipData)
        return all.first { $0.plateIndex == 0 } ?? all[0]
    }

    /// Parses every print plate in a .3MF file separately, so a multi-plate BambuStudio
    /// project file yields one `Result` per plate instead of merging every plate's geometry
    /// together (which would silently inflate weight/time/cost for the plates you didn't
    /// actually intend to estimate). Standard 3MF files (or BambuStudio files without
    /// multi-plate metadata) yield a single Result at plateIndex 0 covering the whole model.
    /// CPU-bound — call from a background task.
    public static func parseAllPlates(_ url: URL) throws -> [Result] {
        let zipData = try Data(contentsOf: url)
        return try parseAllPlates(data: zipData)
    }

    /// Same as `parseAllPlates(_:)` but from in-memory data.
    public static func parseAllPlates(data zipData: Data) throws -> [Result] {
        let zip = ZipReader(data: zipData)
        guard let eocd = zip.findEOCD() else { throw Failure.badZip }

        // Index all ZIP entries by normalised path (lowercase, no leading slash)
        var index: [String: ZipReader.CDEntry] = [:]
        var off = eocd.cdOffset
        for _ in 0..<eocd.entries {
            guard let e = zip.cdEntry(at: off) else { break }
            index[norm(e.filename)] = e
            off += e.totalSize
        }

        // ── Detect BambuStudio multi-plate format ────────────────────────────────
        // model_settings.config maps scene object IDs to plate indices and instance counts.
        if let cfgEntry = index["metadata/model_settings.config"],
           let cfgData = try? zip.extract(cfgEntry) {
            let plateDel = PlateConfigDelegate()
            let plateP   = XMLParser(data: cfgData)
            plateP.delegate = plateDel
            plateP.parse()

            if plateDel.plateCount > 1, !plateDel.objectsByPlate.isEmpty,
               let mainEntry = findMainModelEntry(in: index),
               let mainData  = try? zip.extract(mainEntry) {
                // Parse the scene file to get objectId → component file paths
                let sceneDel = SceneDelegate()
                let sceneP   = XMLParser(data: mainData)
                sceneP.delegate = sceneDel
                sceneP.parse()

                var results: [Result] = []
                for plateIdx in 0..<plateDel.plateCount {
                    var filesToParse: [(path: String, count: Int)] = []
                    for (objId, instanceCount) in plateDel.objectsByPlate[plateIdx] ?? [:] {
                        for path in sceneDel.componentsByObjectId[objId] ?? [] {
                            filesToParse.append((norm(path), instanceCount))
                        }
                    }
                    guard !filesToParse.isEmpty,
                          let geometry = parseGeometry(filesToParse, zip: zip, index: index)
                    else { continue }
                    results.append(Result(
                        volumeMM3: geometry.vol, surfaceAreaMM2: geometry.surf,
                        widthMM: geometry.width, heightMM: geometry.height, depthMM: geometry.depth,
                        triangleCount: geometry.tri, vertexCount: geometry.verts,
                        plateCount: plateDel.plateCount, plateIndex: plateIdx
                    ))
                }
                guard !results.isEmpty else { throw Failure.emptyMesh }
                return results
            }
        }

        // ── Standard 3MF / single-plate / unknown format: one Result, everything in it ──
        let filesToParse = index.keys.filter { $0.hasSuffix(".model") }.map { ($0, 1) }
        guard !filesToParse.isEmpty else { throw Failure.noModelFile }
        guard let geometry = parseGeometry(filesToParse, zip: zip, index: index) else {
            throw Failure.emptyMesh
        }
        return [Result(
            volumeMM3: geometry.vol, surfaceAreaMM2: geometry.surf,
            widthMM: geometry.width, heightMM: geometry.height, depthMM: geometry.depth,
            triangleCount: geometry.tri, vertexCount: geometry.verts,
            plateCount: 1, plateIndex: 0
        )]
    }

    /// Parses geometry for a set of resolved model files (each × its instance count on the
    /// plate) and aggregates them into one combined volume/surface/bounding box — shared by
    /// both the single-plate fallback and each plate's pass in `parseAllPlates`.
    private static func parseGeometry(
        _ filesToParse: [(path: String, count: Int)],
        zip: ZipReader, index: [String: ZipReader.CDEntry]
    ) -> (vol: Double, surf: Double, width: Double, height: Double, depth: Double, tri: Int, verts: Int)? {
        var totalVol:  Double = 0
        var totalSurf: Double = 0
        var totalTri   = 0
        var totalVerts = 0
        var gMinX = Double.infinity,  gMinY = Double.infinity,  gMinZ = Double.infinity
        var gMaxX = -Double.infinity, gMaxY = -Double.infinity, gMaxZ = -Double.infinity

        for (path, count) in filesToParse {
            guard let entry = index[path],
                  let xmlData = try? zip.extract(entry) else { continue }
            let d = MeshDelegate()
            let p = XMLParser(data: xmlData); p.delegate = d; _ = p.parse()
            guard d.triangleCount > 0 else { continue }

            totalVol   += abs(d.volumeSum)  * Double(count)
            totalSurf  += d.surfaceSum       * Double(count)
            totalTri   += d.triangleCount   * count
            totalVerts += d.vertices.count  * count

            // Bounding box: union across all parts (best single-piece fit estimate)
            if d.minX < gMinX { gMinX = d.minX }; if d.maxX > gMaxX { gMaxX = d.maxX }
            if d.minY < gMinY { gMinY = d.minY }; if d.maxY > gMaxY { gMaxY = d.maxY }
            if d.minZ < gMinZ { gMinZ = d.minZ }; if d.maxZ > gMaxZ { gMaxZ = d.maxZ }
        }

        guard totalTri > 0 else { return nil }
        return (totalVol, totalSurf, max(0, gMaxX - gMinX), max(0, gMaxY - gMinY), max(0, gMaxZ - gMinZ), totalTri, totalVerts)
    }

    // MARK: - Embedded thumbnail extraction

    /// Extracts the thumbnail PNG embedded in a .3MF archive, if any.
    /// Slicers (BambuStudio, PrusaSlicer, Cura) store a render under Metadata/.
    /// Replaces QuickLook on platforms that don't have it (Linux server).
    public static func extractThumbnail(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return extractThumbnail(data: data)
    }

    public static func extractThumbnail(data zipData: Data) -> Data? {
        let zip = ZipReader(data: zipData)
        guard let eocd = zip.findEOCD() else { return nil }

        var index: [String: ZipReader.CDEntry] = [:]
        var off = eocd.cdOffset
        for _ in 0..<eocd.entries {
            guard let e = zip.cdEntry(at: off) else { break }
            index[norm(e.filename)] = e
            off += e.totalSize
        }

        // Preferred well-known locations first, then any PNG under Metadata/,
        // then any PNG at all.
        let preferred = ["metadata/plate_1.png", "metadata/thumbnail.png", "thumbnail.png"]
        for name in preferred {
            if let entry = index[name], let data = try? zip.extract(entry) { return data }
        }
        let fallbacks = index.keys
            .filter { $0.hasSuffix(".png") }
            .sorted { ($0.hasPrefix("metadata/") ? 0 : 1, $0) < ($1.hasPrefix("metadata/") ? 0 : 1, $1) }
        for name in fallbacks {
            if let entry = index[name], let data = try? zip.extract(entry) { return data }
        }
        return nil
    }

    // MARK: - Private helpers

    private static func norm(_ path: String) -> String {
        path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func findMainModelEntry(in index: [String: ZipReader.CDEntry]) -> ZipReader.CDEntry? {
        index["3d/3dmodel.model"]
            ?? index.values.first { norm($0.filename).hasSuffix("3dmodel.model") }
    }
}

// MARK: - Geometry extraction (for on-screen previews, not estimation)

/// Raw triangle geometry for rendering — unlike `Result`, which only keeps
/// aggregate stats and discards the mesh, this keeps every vertex.
public struct RenderableGeometry: Sendable {
    /// Flat triangle positions: 3 floats per vertex, 3 vertices per triangle
    /// (no shared-vertex indexing — simplest to hand straight to a GPU).
    public let positions: [Float]
    /// Per-vertex face normals (flat shading), same layout/count as `positions`.
    public let normals: [Float]

    public init(positions: [Float], normals: [Float]) {
        self.positions = positions
        self.normals = normals
    }
}

extension ThreeMFParser {
    /// Extracts renderable geometry for plate 0 (or the whole model, for a
    /// standard 3MF file) — the same plate `parse(_:)` reports stats for,
    /// since a preview only ever shows one plate at a time anyway. Duplicates
    /// a little of `parseAllPlates`'s plate-resolution logic rather than
    /// threading a "collect geometry too" flag through the stats path, to
    /// keep the two concerns (estimation vs. preview) independent.
    public static func parseGeometryForPreview(_ url: URL) throws -> RenderableGeometry {
        let zipData = try Data(contentsOf: url)
        return try parseGeometryForPreview(data: zipData)
    }

    /// Same as `parseGeometryForPreview(_:)` but from in-memory data.
    public static func parseGeometryForPreview(data zipData: Data) throws -> RenderableGeometry {
        let zip = ZipReader(data: zipData)
        guard let eocd = zip.findEOCD() else { throw Failure.badZip }

        var index: [String: ZipReader.CDEntry] = [:]
        var off = eocd.cdOffset
        for _ in 0..<eocd.entries {
            guard let e = zip.cdEntry(at: off) else { break }
            index[norm(e.filename)] = e
            off += e.totalSize
        }

        var filesToParse: [(path: String, count: Int)] = []

        if let cfgEntry = index["metadata/model_settings.config"],
           let cfgData = try? zip.extract(cfgEntry) {
            let plateDel = PlateConfigDelegate()
            let plateP = XMLParser(data: cfgData)
            plateP.delegate = plateDel
            plateP.parse()

            if plateDel.plateCount > 1, let plate0Objects = plateDel.objectsByPlate[0], !plate0Objects.isEmpty,
               let mainEntry = findMainModelEntry(in: index),
               let mainData = try? zip.extract(mainEntry) {
                let sceneDel = SceneDelegate()
                let sceneP = XMLParser(data: mainData)
                sceneP.delegate = sceneDel
                sceneP.parse()

                for (objId, instanceCount) in plate0Objects {
                    for path in sceneDel.componentsByObjectId[objId] ?? [] {
                        filesToParse.append((norm(path), instanceCount))
                    }
                }
            }
        }

        if filesToParse.isEmpty {
            filesToParse = index.keys.filter { $0.hasSuffix(".model") }.map { ($0, 1) }
        }
        guard !filesToParse.isEmpty else { throw Failure.noModelFile }

        var positions: [Float] = []
        var normals: [Float] = []

        for (path, count) in filesToParse {
            guard let entry = index[path], let xmlData = try? zip.extract(entry) else { continue }
            let d = GeometryDelegate()
            let p = XMLParser(data: xmlData); p.delegate = d; _ = p.parse()
            guard !d.positions.isEmpty else { continue }
            for _ in 0..<count {
                positions.append(contentsOf: d.positions)
                normals.append(contentsOf: d.normals)
            }
        }
        guard !positions.isEmpty else { throw Failure.emptyMesh }
        return RenderableGeometry(positions: positions, normals: normals)
    }
}

/// SAX delegate collecting flat triangle position/normal arrays, mirroring
/// `MeshDelegate`'s traversal (same object/mesh/vertex/triangle handling,
/// same per-mesh vertex-index reset) but keeping the geometry instead of
/// reducing it to running stats.
private final class GeometryDelegate: NSObject, XMLParserDelegate {
    var positions: [Float] = []
    var normals: [Float] = []

    private var vertices: [Vec3] = []
    private var meshVertexStart = 0
    private var inModelObject = true
    private var inV = false
    private var inT = false

    func parser(_ parser: XMLParser, didStartElement el: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes a: [String: String]) {
        switch el {
        case "object":
            inModelObject = (a["type"] ?? "model").lowercased() == "model"
            inV = false; inT = false
        case "mesh" where inModelObject:
            meshVertexStart = vertices.count
            inV = false; inT = false
        case "vertices" where inModelObject: inV = true
        case "triangles" where inModelObject: inT = true
        case "vertex" where inV:
            guard let x = Double(a["x"] ?? ""),
                  let y = Double(a["y"] ?? ""),
                  let z = Double(a["z"] ?? "") else { return }
            vertices.append(Vec3(x: x, y: y, z: z))
        case "triangle" where inT:
            guard let r1 = Int(a["v1"] ?? ""),
                  let r2 = Int(a["v2"] ?? ""),
                  let r3 = Int(a["v3"] ?? "") else { return }
            let i1 = meshVertexStart + r1
            let i2 = meshVertexStart + r2
            let i3 = meshVertexStart + r3
            guard i1 < vertices.count, i2 < vertices.count, i3 < vertices.count else { return }
            let v1 = vertices[i1], v2 = vertices[i2], v3 = vertices[i3]
            let u = v2 - v1, v = v3 - v1
            var nx = u.y * v.z - u.z * v.y
            var ny = u.z * v.x - u.x * v.z
            var nz = u.x * v.y - u.y * v.x
            let len = (nx * nx + ny * ny + nz * nz).squareRoot()
            if len > 0 { nx /= len; ny /= len; nz /= len }
            for vertex in [v1, v2, v3] {
                positions.append(Float(vertex.x)); positions.append(Float(vertex.y)); positions.append(Float(vertex.z))
                normals.append(Float(nx)); normals.append(Float(ny)); normals.append(Float(nz))
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String,
                namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "object":    inModelObject = true; inV = false; inT = false
        case "vertices":  inV = false
        case "triangles": inT = false
        default: break
        }
    }
}
