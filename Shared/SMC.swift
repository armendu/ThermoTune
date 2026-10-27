import Foundation
import IOKit

/// Errors raised while talking to the System Management Controller.
enum SMCError: LocalizedError {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case smcResult(key: String, code: UInt8)
    case unsupportedType(key: String, type: String)
    case sizeMismatch(key: String)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found."
        case .openFailed(let r): return "Could not open AppleSMC (0x\(String(r, radix: 16)))."
        case .callFailed(let r): return "SMC call failed (0x\(String(r, radix: 16)))."
        case .smcResult(let key, let code):
            return code == 0x84 ? "SMC key \(key) not found." : "SMC returned error 0x\(String(code, radix: 16)) for \(key)."
        case .unsupportedType(let key, let type): return "SMC key \(key) has unsupported type '\(type)'."
        case .sizeMismatch(let key): return "Encoded value has the wrong size for SMC key \(key)."
        }
    }
}

struct SMCKeyInfo: Sendable {
    let size: Int
    let type: String
}

extension UInt32 {
    init(fourCC: String) {
        var value: UInt32 = 0
        for byte in fourCC.utf8.prefix(4) { value = value << 8 | UInt32(byte) }
        self = value
    }

    var fourCC: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Thin wrapper around the AppleSMC user client.
///
/// The kernel expects an 80-byte `SMCKeyData_t` struct. Rather than relying on
/// Swift's struct layout, the packet is built as a raw buffer with the C offsets.
final class SMC {
    private enum Command: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private enum Offset {
        static let key = 0
        static let dataSize = 28
        static let dataType = 32
        static let result = 40
        static let data8 = 42
        static let data32 = 44
        static let bytes = 48
        static let packetSize = 80
    }

    private static let handleYPCEvent: UInt32 = 2

    private var connection: io_connect_t = 0
    private var infoCache: [String: SMCKeyInfo] = [:]

    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.openFailed(result) }
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: Raw access

    private func call(_ command: Command, key: String, configure: (inout [UInt8]) -> Void = { _ in }) throws -> [UInt8] {
        var input = [UInt8](repeating: 0, count: Offset.packetSize)
        Self.store(UInt32(fourCC: key), in: &input, at: Offset.key)
        input[Offset.data8] = command.rawValue
        configure(&input)

        var output = [UInt8](repeating: 0, count: Offset.packetSize)
        var outputSize = Offset.packetSize
        let result = input.withUnsafeBytes { inBuf in
            output.withUnsafeMutableBytes { outBuf in
                IOConnectCallStructMethod(connection, Self.handleYPCEvent,
                                          inBuf.baseAddress, Offset.packetSize,
                                          outBuf.baseAddress, &outputSize)
            }
        }
        guard result == kIOReturnSuccess else { throw SMCError.callFailed(result) }
        guard output[Offset.result] == 0 else { throw SMCError.smcResult(key: key, code: output[Offset.result]) }
        return output
    }

    private static func store(_ value: UInt32, in buffer: inout [UInt8], at offset: Int) {
        buffer.withUnsafeMutableBytes { $0.storeBytes(of: value, toByteOffset: offset, as: UInt32.self) }
    }

    private static func load(from buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    func keyInfo(_ key: String) throws -> SMCKeyInfo {
        if let cached = infoCache[key] { return cached }
        let output = try call(.keyInfo, key: key)
        let info = SMCKeyInfo(size: Int(Self.load(from: output, at: Offset.dataSize)),
                              type: Self.load(from: output, at: Offset.dataType).fourCC)
        infoCache[key] = info
        return info
    }

    func hasKey(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    func readBytes(_ key: String) throws -> (info: SMCKeyInfo, bytes: [UInt8]) {
        let info = try keyInfo(key)
        let output = try call(.readBytes, key: key) { Self.store(UInt32(info.size), in: &$0, at: Offset.dataSize) }
        let size = min(info.size, 32)
        return (info, Array(output[Offset.bytes ..< Offset.bytes + size]))
    }

    func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == info.size, bytes.count <= 32 else { throw SMCError.sizeMismatch(key: key) }
        _ = try call(.writeBytes, key: key) { packet in
            Self.store(UInt32(info.size), in: &packet, at: Offset.dataSize)
            packet.replaceSubrange(Offset.bytes ..< Offset.bytes + bytes.count, with: bytes)
        }
    }

    // MARK: Typed values

    func read(_ key: String) throws -> Double {
        let (info, bytes) = try readBytes(key)
        guard let value = Self.decode(bytes, type: info.type) else {
            throw SMCError.unsupportedType(key: key, type: info.type)
        }
        return value
    }

    func write(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        guard let bytes = Self.encode(value, type: info.type, size: info.size) else {
            throw SMCError.unsupportedType(key: key, type: info.type)
        }
        try writeBytes(key, bytes)
    }

    static func decode(_ b: [UInt8], type: String) -> Double? {
        func be(_ count: Int) -> UInt64? {
            guard b.count >= count else { return nil }
            return b.prefix(count).reduce(0) { $0 << 8 | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78": return be(2).map { Double(Int16(bitPattern: UInt16($0))) / 256 }
        case "fpe2": return be(2).map { Double($0) / 4 }
        case "fp88": return be(2).map { Double($0) / 256 }
        case "ui8 ", "flag": return be(1).map { Double($0) }
        case "ui16": return be(2).map { Double($0) }
        case "ui32": return be(4).map { Double($0) }
        default: return nil
        }
    }

    static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        func be(_ v: UInt64, _ count: Int) -> [UInt8] {
            (0..<count).reversed().map { UInt8((v >> UInt64($0 * 8)) & 0xFF) }
        }
        guard value.isFinite, value >= 0 else { return nil }
        let bytes: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)]
        case "fpe2": bytes = be(UInt64(min(value * 4, 65535)), 2)
        case "ui8 ", "flag": bytes = be(UInt64(min(value, 255)), 1)
        case "ui16": bytes = be(UInt64(min(value, 65535)), 2)
        case "ui32": bytes = be(UInt64(min(value, 4294967295)), 4)
        default: return nil
        }
        return bytes.count == size ? bytes : nil
    }

    // MARK: Key enumeration

    func keyCount() throws -> Int {
        Int(try read("#KEY"))
    }

    func key(at index: Int) throws -> String {
        let output = try call(.keyAtIndex, key: "\0\0\0\0") {
            Self.store(UInt32(index), in: &$0, at: Offset.data32)
        }
        return Self.load(from: output, at: Offset.key).fourCC
    }

    func allKeys() -> [String] {
        guard let count = try? keyCount() else { return [] }
        return (0..<count).compactMap { try? key(at: $0) }
    }
}
