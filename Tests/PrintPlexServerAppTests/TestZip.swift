import Foundation

/// Builds minimal valid .3MF fixtures (stored ZIP + cube mesh) for server tests.
/// Mirrors the helper in PrintPlexCoreTests.
enum TestZip {

    static func cube3MF() -> Data {
        makeStoredZip(entries: [("3D/3dmodel.model", Data(cubeModelXML.utf8))])
    }

    private static let cubeModelXML = """
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

    private static func appendU16(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8(v >> 8))
    }
    private static func appendU32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8(v >> 24))
    }

    static func makeStoredZip(entries: [(name: String, content: Data)]) -> Data {
        var out = Data()
        var offsets: [UInt32] = []

        for (name, content) in entries {
            let nameData = Data(name.utf8)
            offsets.append(UInt32(out.count))
            out.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            appendU16(&out, 20)
            appendU16(&out, 0)
            appendU16(&out, 0)
            appendU16(&out, 0); appendU16(&out, 0)
            appendU32(&out, 0)
            appendU32(&out, UInt32(content.count))
            appendU32(&out, UInt32(content.count))
            appendU16(&out, UInt16(nameData.count))
            appendU16(&out, 0)
            out.append(nameData)
            out.append(content)
        }

        let cdOffset = UInt32(out.count)
        var cdSize: UInt32 = 0
        for (i, (name, content)) in entries.enumerated() {
            let nameData = Data(name.utf8)
            var cd = Data()
            cd.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])
            appendU16(&cd, 20)
            appendU16(&cd, 20)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0); appendU16(&cd, 0)
            appendU32(&cd, 0)
            appendU32(&cd, UInt32(content.count))
            appendU32(&cd, UInt32(content.count))
            appendU16(&cd, UInt16(nameData.count))
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU16(&cd, 0)
            appendU32(&cd, 0)
            appendU32(&cd, offsets[i])
            cd.append(nameData)
            cdSize += UInt32(cd.count)
            out.append(cd)
        }

        out.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])
        appendU16(&out, 0)
        appendU16(&out, 0)
        appendU16(&out, UInt16(entries.count))
        appendU16(&out, UInt16(entries.count))
        appendU32(&out, cdSize)
        appendU32(&out, cdOffset)
        appendU16(&out, 0)
        return out
    }
}
