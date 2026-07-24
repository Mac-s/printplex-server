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
