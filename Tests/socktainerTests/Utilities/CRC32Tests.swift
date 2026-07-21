import Foundation
import Testing

@testable import socktainer

@Suite("CRC32")
struct CRC32Tests {
    @Test("matches the standard CRC-32/ISO-HDLC check value")
    func standardCheckValue() {
        var crc = CRC32.Incremental()
        Array("123456789".utf8).withUnsafeBufferPointer { crc.update(UnsafeRawBufferPointer($0)) }
        #expect(crc.value == 0xCBF4_3926)
    }

    @Test("an empty input hashes to zero")
    func emptyInput() {
        let crc = CRC32.Incremental()
        #expect(crc.value == 0)
    }

    @Test("accumulating across multiple chunks matches one contiguous update")
    func incrementalMatchesWhole() {
        let data = Array("the quick brown fox jumps over the lazy dog".utf8)

        var whole = CRC32.Incremental()
        data.withUnsafeBufferPointer { whole.update(UnsafeRawBufferPointer($0)) }

        var chunked = CRC32.Incremental()
        for chunk in [data[0..<10], data[10..<20], data[20...]] {
            Array(chunk).withUnsafeBufferPointer { chunked.update(UnsafeRawBufferPointer($0)) }
        }

        #expect(whole.value == chunked.value)
    }
}
