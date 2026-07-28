import XCTest
@testable import PrintPlexCore

final class ThreeMFParserTests: XCTestCase {

    // MARK: - Minimal ZIP builder (stored entries, no compression)

    private func appendU16(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8))
    }
    private func appendU32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8(v >> 24))
    }

    /// Builds a valid ZIP archive with stored (uncompressed) entries.
    private func makeStoredZip(entries: [(name: String, content: Data)]) -> Data {
        var out = Data()
        var offsets: [UInt32] = []

        for (name, content) in entries {
            let nameData = Data(name.utf8)
            offsets.append(UInt32(out.count))
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])   // local header sig
            appendU16(&out, 20)                                 // version needed
            appendU16(&out, 0)                                  // flags
            appendU16(&out, 0)                                  // method: stored
            appendU16(&out, 0); appendU16(&out, 0)              // time, date
            appendU32(&out, 0)                                  // crc (not checked by reader)
            appendU32(&out, UInt32(content.count))              // compressed size
            appendU32(&out, UInt32(content.count))              // uncompressed size
            appendU16(&out, UInt16(nameData.count))             // name length
            appendU16(&out, 0)                                  // extra length
            out.append(nameData)
            out.append(content)
        }

        let cdOffset = UInt32(out.count)
        var cdSize: UInt32 = 0
        for (i, (name, content)) in entries.enumerated() {
            let nameData = Data(name.utf8)
            var cd = Data()
            cd.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])     // central dir sig
            appendU16(&cd, 20)                                  // version made by
            appendU16(&cd, 20)                                  // version needed
            appendU16(&cd, 0)                                   // flags
            appendU16(&cd, 0)                                   // method: stored
            appendU16(&cd, 0); appendU16(&cd, 0)                // time, date
            appendU32(&cd, 0)                                   // crc
            appendU32(&cd, UInt32(content.count))               // compressed size
            appendU32(&cd, UInt32(content.count))               // uncompressed size
            appendU16(&cd, UInt16(nameData.count))              // name length
            appendU16(&cd, 0)                                   // extra length
            appendU16(&cd, 0)                                   // comment length
            appendU16(&cd, 0)                                   // disk number
            appendU16(&cd, 0)                                   // internal attrs
            appendU32(&cd, 0)                                   // external attrs
            appendU32(&cd, offsets[i])                          // local header offset
            cd.append(nameData)
            cdSize += UInt32(cd.count)
            out.append(cd)
        }

        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])        // EOCD sig
        appendU16(&out, 0)                                      // disk number
        appendU16(&out, 0)                                      // cd start disk
        appendU16(&out, UInt16(entries.count))                  // entries on disk
        appendU16(&out, UInt16(entries.count))                  // total entries
        appendU32(&out, cdSize)                                 // cd size
        appendU32(&out, cdOffset)                               // cd offset
        appendU16(&out, 0)                                      // comment length
        return out
    }

    // MARK: - Fixture: 10 mm cube, outward-wound triangles

    private var cubeModelXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <object id="1" type="model">
           <mesh>
            <vertices>
             <vertex x="0" y="0" z="0"/>
             <vertex x="10" y="0" z="0"/>
             <vertex x="10" y="10" z="0"/>
             <vertex x="0" y="10" z="0"/>
             <vertex x="0" y="0" z="10"/>
             <vertex x="10" y="0" z="10"/>
             <vertex x="10" y="10" z="10"/>
             <vertex x="0" y="10" z="10"/>
            </vertices>
            <triangles>
             <triangle v1="0" v2="2" v3="1"/>
             <triangle v1="0" v2="3" v3="2"/>
             <triangle v1="4" v2="5" v3="6"/>
             <triangle v1="4" v2="6" v3="7"/>
             <triangle v1="0" v2="1" v3="5"/>
             <triangle v1="0" v2="5" v3="4"/>
             <triangle v1="2" v2="3" v3="7"/>
             <triangle v1="2" v2="7" v3="6"/>
             <triangle v1="0" v2="4" v3="7"/>
             <triangle v1="0" v2="7" v3="3"/>
             <triangle v1="1" v2="2" v3="6"/>
             <triangle v1="1" v2="6" v3="5"/>
            </triangles>
           </mesh>
          </object>
         </resources>
         <build><item objectid="1"/></build>
        </model>
        """
    }

    private func writeCube3MF() throws -> URL {
        let zip = makeStoredZip(entries: [
            ("3D/3dmodel.model", Data(cubeModelXML.utf8)),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("printplex-test-\(UUID().uuidString).3mf")
        try zip.write(to: url)
        return url
    }

    // MARK: - Fixture: 2-plate BambuStudio project (plate 0 = 10mm cube, plate 1 = 20mm cube)

    /// Same topology as `cubeModelXML` scaled to an arbitrary edge length, used as a
    /// standalone geometry file referenced via a `<component>` from the main scene —
    /// mirrors how BambuStudio splits each plate's objects into separate `3D/Objects/*.model`
    /// files instead of embedding meshes directly in `3D/3dmodel.model`.
    private func cubeObjectModelXML(edge: Double) -> String {
        let s = edge
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <object id="1" type="model">
           <mesh>
            <vertices>
             <vertex x="0" y="0" z="0"/>
             <vertex x="\(s)" y="0" z="0"/>
             <vertex x="\(s)" y="\(s)" z="0"/>
             <vertex x="0" y="\(s)" z="0"/>
             <vertex x="0" y="0" z="\(s)"/>
             <vertex x="\(s)" y="0" z="\(s)"/>
             <vertex x="\(s)" y="\(s)" z="\(s)"/>
             <vertex x="0" y="\(s)" z="\(s)"/>
            </vertices>
            <triangles>
             <triangle v1="0" v2="2" v3="1"/>
             <triangle v1="0" v2="3" v3="2"/>
             <triangle v1="4" v2="5" v3="6"/>
             <triangle v1="4" v2="6" v3="7"/>
             <triangle v1="0" v2="1" v3="5"/>
             <triangle v1="0" v2="5" v3="4"/>
             <triangle v1="2" v2="3" v3="7"/>
             <triangle v1="2" v2="7" v3="6"/>
             <triangle v1="0" v2="4" v3="7"/>
             <triangle v1="0" v2="7" v3="3"/>
             <triangle v1="1" v2="2" v3="6"/>
             <triangle v1="1" v2="6" v3="5"/>
            </triangles>
           </mesh>
          </object>
         </resources>
         <build><item objectid="1"/></build>
        </model>
        """
    }

    /// The main scene file for a multi-plate project: scene objects don't hold geometry
    /// directly, they reference a separate per-object `.model` file via `<component>`
    /// (BambuStudio's production-extension layout).
    private var multiPlateSceneXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
         <resources>
          <object id="1">
           <components>
            <component p:path="/3D/Objects/object_1.model" objectid="1"/>
           </components>
          </object>
          <object id="2">
           <components>
            <component p:path="/3D/Objects/object_2.model" objectid="1"/>
           </components>
          </object>
         </resources>
         <build>
          <item objectid="1"/>
          <item objectid="2"/>
         </build>
        </model>
        """
    }

    private var multiPlateConfigXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <config>
         <object id="1">
          <metadata key="plate_index" value="0"/>
         </object>
         <object id="2">
          <metadata key="plate_index" value="1"/>
         </object>
        </config>
        """
    }

    private func writeMultiPlate3MF() throws -> URL {
        let zip = makeStoredZip(entries: [
            ("3D/3dmodel.model", Data(multiPlateSceneXML.utf8)),
            ("3D/Objects/object_1.model", Data(cubeObjectModelXML(edge: 10).utf8)),
            ("3D/Objects/object_2.model", Data(cubeObjectModelXML(edge: 20).utf8)),
            ("Metadata/model_settings.config", Data(multiPlateConfigXML.utf8)),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("printplex-multiplate-\(UUID().uuidString).3mf")
        try zip.write(to: url)
        return url
    }

    // MARK: - Tests

    func testParsesCubeGeometry() throws {
        let url = try writeCube3MF()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ThreeMFParser.parse(url)

        XCTAssertEqual(result.volumeMM3, 1000, accuracy: 0.001)
        XCTAssertEqual(result.surfaceAreaMM2, 600, accuracy: 0.001)
        XCTAssertEqual(result.widthMM, 10, accuracy: 0.001)
        XCTAssertEqual(result.heightMM, 10, accuracy: 0.001)
        XCTAssertEqual(result.depthMM, 10, accuracy: 0.001)
        XCTAssertEqual(result.triangleCount, 12)
        XCTAssertEqual(result.vertexCount, 8)
        XCTAssertEqual(result.plateCount, 1)
    }

    func testParseGeometryForPreviewExtractsTriangles() throws {
        let url = try writeCube3MF()
        defer { try? FileManager.default.removeItem(at: url) }

        let geometry = try ThreeMFParser.parseGeometryForPreview(url)

        // 12 triangles × 3 vertices × 3 floats (x/y/z), same for normals.
        XCTAssertEqual(geometry.positions.count, 12 * 3 * 3)
        XCTAssertEqual(geometry.normals.count, geometry.positions.count)

        // Every normal must be unit length — a cheap sanity check that these
        // are real face normals, not leftover zeros from a degenerate triangle.
        for i in stride(from: 0, to: geometry.normals.count, by: 3) {
            let nx = geometry.normals[i], ny = geometry.normals[i + 1], nz = geometry.normals[i + 2]
            let length = (nx * nx + ny * ny + nz * nz).squareRoot()
            XCTAssertEqual(length, 1.0, accuracy: 0.01)
        }
    }

    func testExtractsEmbeddedThumbnail() {
        let png = Data("fake png bytes".utf8)
        let zip = makeStoredZip(entries: [
            ("3D/3dmodel.model", Data(cubeModelXML.utf8)),
            ("Metadata/plate_1.png", png),
            ("Metadata/other.png", Data("other".utf8)),
        ])
        XCTAssertEqual(ThreeMFParser.extractThumbnail(data: zip), png)

        let zipWithoutPNG = makeStoredZip(entries: [
            ("3D/3dmodel.model", Data(cubeModelXML.utf8)),
        ])
        XCTAssertNil(ThreeMFParser.extractThumbnail(data: zipWithoutPNG))
    }

    func testRejectsGarbageData() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("printplex-garbage-\(UUID().uuidString).3mf")
        try? Data("definitely not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ThreeMFParser.parse(url))
    }

    func testRejectsZipWithoutModel() throws {
        let zip = makeStoredZip(entries: [
            ("readme.txt", Data("hello".utf8)),
        ])
        XCTAssertThrowsError(try ThreeMFParser.parse(data: zip)) { error in
            guard case ThreeMFParser.Failure.noModelFile = error else {
                return XCTFail("Expected noModelFile, got \(error)")
            }
        }
    }

    func testParsesMultiplePlatesSeparately() throws {
        let url = try writeMultiPlate3MF()
        defer { try? FileManager.default.removeItem(at: url) }

        let plates = try ThreeMFParser.parseAllPlates(url)

        XCTAssertEqual(plates.count, 2)
        let plate0 = try XCTUnwrap(plates.first { $0.plateIndex == 0 })
        let plate1 = try XCTUnwrap(plates.first { $0.plateIndex == 1 })

        // Plate 0 = 10mm cube — must NOT include plate 1's geometry.
        XCTAssertEqual(plate0.volumeMM3, 1000, accuracy: 0.001)
        XCTAssertEqual(plate0.surfaceAreaMM2, 600, accuracy: 0.001)
        XCTAssertEqual(plate0.widthMM, 10, accuracy: 0.001)
        XCTAssertEqual(plate0.plateCount, 2)

        // Plate 1 = 20mm cube — must NOT include plate 0's geometry.
        XCTAssertEqual(plate1.volumeMM3, 8000, accuracy: 0.001)
        XCTAssertEqual(plate1.surfaceAreaMM2, 2400, accuracy: 0.001)
        XCTAssertEqual(plate1.widthMM, 20, accuracy: 0.001)
        XCTAssertEqual(plate1.plateCount, 2)

        // The single-result convenience API must only ever return plate 0 — combining every
        // plate into one estimate would silently inflate weight/time/cost.
        let single = try ThreeMFParser.parse(url)
        XCTAssertEqual(single.volumeMM3, 1000, accuracy: 0.001)
        XCTAssertEqual(single.plateIndex, 0)
        XCTAssertEqual(single.plateCount, 2)
    }

    func testSkipsNonModelObjects() throws {
        // Support blockers (type="support_blocker") must not contribute geometry
        let xml = cubeModelXML.replacingOccurrences(
            of: #"<object id="1" type="model">"#,
            with: #"<object id="1" type="support_blocker">"#
        )
        let zip = makeStoredZip(entries: [("3D/3dmodel.model", Data(xml.utf8))])
        XCTAssertThrowsError(try ThreeMFParser.parse(data: zip)) { error in
            guard case ThreeMFParser.Failure.emptyMesh = error else {
                return XCTFail("Expected emptyMesh, got \(error)")
            }
        }
    }
}
