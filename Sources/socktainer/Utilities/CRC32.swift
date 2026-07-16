/// CRC-32/ISO-HDLC — the checksum variant gzip's trailer requires (RFC 1952 §2.3).
enum CRC32 {
    private static let polynomial: UInt32 = 0xEDB8_8320
    private static let initialAndFinalXOR: UInt32 = 0xFFFF_FFFF

    private static let table: [UInt32] = (0..<256).map { byte in
        var remainder = UInt32(byte)
        for _ in 0..<8 {
            remainder = (remainder & 1 != 0) ? (polynomial ^ (remainder >> 1)) : (remainder >> 1)
        }
        return remainder
    }

    struct Incremental {
        private var crc: UInt32 = CRC32.initialAndFinalXOR

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            for byte in bytes {
                crc = CRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }

        var value: UInt32 { crc ^ CRC32.initialAndFinalXOR }
    }
}
