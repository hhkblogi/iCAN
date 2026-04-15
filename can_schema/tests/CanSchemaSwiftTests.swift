import XCTest
import Foundation

final class CANSchemaSwiftTests: XCTestCase {
    func testLoadsFixtureDBCTextFromFile() throws {
        var schema = CANSchema()
        let dbc = try loadFixtureDBC()

        let loaded = dbc.withCString { ptr in
            schema.loadDBCText(ptr)
        }

        XCTAssertTrue(loaded)
        XCTAssertTrue(schema.hasSchema())
    }

    func testRejectsDBCWithoutMessages() {
        var schema = CANSchema()
        let dbc = "VERSION \"1.0\"\n\nNS_ :\n\nBS_:\n\nBU_: ECM\n"

        let loaded = dbc.withCString { ptr in
            schema.loadDBCText(ptr)
        }

        XCTAssertFalse(loaded)
        XCTAssertFalse(schema.hasSchema())
    }

    func testAcceptsNonUtf8DBCBytes() {
        var schema = CANSchema()
        var dbc = Array("VERSION \"1.0\"\n\nNS_ :\n\nBS_:\n\nBU_: ECM\n\nBO_ 291 Demo : 8 ECM\n SG_ Temp : 0|8@1+ (1,0) [0|255] \"".utf8)
        dbc.append(0xB0)
        dbc.append(contentsOf: Array("C\" ECM\n".utf8))

        let loaded = dbc.withUnsafeBytes { buffer in
            schema.loadDBCText(
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }

        XCTAssertTrue(loaded)
        XCTAssertTrue(schema.hasSchema())
    }

    func testFailedReloadClearsPreviousSchema() throws {
        var schema = CANSchema()
        try loadSchema(&schema)
        XCTAssertTrue(schema.hasSchema())

        let invalid = "VERSION \"1.0\"\n\nNS_ :\n\nBS_:\n\nBU_: ECM\n"
        let loaded = invalid.withCString { ptr in
            schema.loadDBCText(ptr)
        }

        XCTAssertFalse(loaded)
        XCTAssertFalse(schema.hasSchema())

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 2)
        var signalCount = 99

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(makeFrame(), messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_NOT_READY.rawValue))
        XCTAssertFalse(message.matched)
        XCTAssertEqual(signalCount, 0)
    }

    func testDecodeStandardMessageFromFixtureFile() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 291
        frame.len = 8
        withUnsafeMutableBytes(of: &frame.data) { buffer in
            buffer[0] = 0x34
            buffer[1] = 0x12
            buffer[2] = 100
        }

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 4)
        var signalCount = 0

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_OK.rawValue))
        XCTAssertTrue(message.matched)
        XCTAssertEqual(signalCount, 2)
        XCTAssertEqual(stringView(message.messageName, message.messageNameLength), "Demo")
        XCTAssertEqual(stringView(signals[0].name, signals[0].nameLength), "Speed")
        XCTAssertEqual(stringView(signals[0].unit, signals[0].unitLength), "km/h")
        XCTAssertEqual(signals[0].value, 4660.0)
        XCTAssertEqual(stringView(signals[1].name, signals[1].nameLength), "Temp")
        XCTAssertEqual(stringView(signals[1].unit, signals[1].unitLength), "C")
        XCTAssertEqual(signals[1].value, 10.0)
    }

    func testDecodeExtendedMessageFromFixtureFile() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 0x80000000 | 419385573
        frame.len = 8
        withUnsafeMutableBytes(of: &frame.data) { buffer in
            buffer[0] = 7
        }

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 4)
        var signalCount = 0

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_OK.rawValue))
        XCTAssertTrue(message.matched)
        XCTAssertEqual(signalCount, 1)
        XCTAssertEqual(stringView(message.messageName, message.messageNameLength), "ExtStatus")
        XCTAssertEqual(stringView(signals[0].name, signals[0].nameLength), "Mode")
        XCTAssertEqual(signals[0].value, 7.0)
        XCTAssertEqual(stringView(signals[0].displayValue, signals[0].displayValueLength), "Active")
    }

    func testDecodeFloatMessageFromFixtureFile() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 800
        frame.len = 8
        withUnsafeMutableBytes(of: &frame.data) { buffer in
            buffer[0] = 0x00
            buffer[1] = 0x00
            buffer[2] = 0x80
            buffer[3] = 0x3f
        }

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 2)
        var signalCount = 0

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_OK.rawValue))
        XCTAssertTrue(message.matched)
        XCTAssertEqual(signalCount, 1)
        XCTAssertEqual(stringView(message.messageName, message.messageNameLength), "FloatStatus")
        XCTAssertEqual(stringView(signals[0].name, signals[0].nameLength), "Ratio")
        XCTAssertEqual(signals[0].value, 1.0)
    }

    func testDecodeMultiplexedMessageFromFixtureFile() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 600
        frame.len = 8
        withUnsafeMutableBytes(of: &frame.data) { buffer in
            buffer[0] = 0
            buffer[1] = 88
        }

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 4)
        var signalCount = 0

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_OK.rawValue))
        XCTAssertTrue(message.matched)
        XCTAssertEqual(signalCount, 2)
        XCTAssertEqual(stringView(message.messageName, message.messageNameLength), "MultiStatus")
        XCTAssertEqual(stringView(signals[0].name, signals[0].nameLength), "Page")
        XCTAssertEqual(stringView(signals[0].displayValue, signals[0].displayValueLength), "Drive")
        XCTAssertEqual(stringView(signals[1].name, signals[1].nameLength), "DriveSpeed")
        XCTAssertEqual(signals[1].value, 88.0)
    }

    func testDecodeReportsNoMatchForUnknownFrame() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 0x456
        frame.len = 8

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 1)
        var signalCount = 99

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_NO_MATCH.rawValue))
        XCTAssertFalse(message.matched)
        XCTAssertEqual(signalCount, 0)
    }

    func testDecodeAllowsNilSignalBufferProbe() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 291
        frame.len = 8
        withUnsafeMutableBytes(of: &frame.data) { buffer in
            buffer[0] = 0x34
            buffer[1] = 0x12
            buffer[2] = 100
        }

        var message = CANSchemaDecodedMessage()
        var signalCount = 99

        let status = withUnsafeMutablePointer(to: &message) { messagePtr in
            withUnsafeMutablePointer(to: &signalCount) { countPtr in
                schema.decode(frame, messagePtr, nil, 0, countPtr)
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_BUFFER_TOO_SMALL.rawValue))
        XCTAssertTrue(message.matched)
        XCTAssertEqual(signalCount, 2)
    }

    func testDecodeRejectsRemoteAndErrorFrames() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        for flag in [UInt32(CAN_RTR_FLAG), UInt32(CAN_ERR_FLAG)] {
            var frame = canfd_frame()
            frame.can_id = flag | 291
            frame.len = 8
            withUnsafeMutableBytes(of: &frame.data) { buffer in
                buffer[0] = 0x34
                buffer[1] = 0x12
                buffer[2] = 100
            }

            var message = CANSchemaDecodedMessage()
            var signals = Array(repeating: CANSchemaDecodedSignal(), count: 2)
            var signalCount = 99

            let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
                withUnsafeMutablePointer(to: &message) { messagePtr in
                    withUnsafeMutablePointer(to: &signalCount) { countPtr in
                        schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                    }
                }
            }

            XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_INVALID_ARGUMENT.rawValue))
            XCTAssertFalse(message.matched)
            XCTAssertEqual(signalCount, 0)
        }
    }

    func testDecodeRejectsTruncatedZeroSignalMessage() throws {
        var schema = CANSchema()
        try loadSchema(&schema)

        var frame = canfd_frame()
        frame.can_id = 700
        frame.len = 0

        var message = CANSchemaDecodedMessage()
        var signalCount = 99

        let status = withUnsafeMutablePointer(to: &message) { messagePtr in
            withUnsafeMutablePointer(to: &signalCount) { countPtr in
                schema.decode(frame, messagePtr, nil, 0, countPtr)
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_INVALID_ARGUMENT.rawValue))
        XCTAssertFalse(message.matched)
        XCTAssertEqual(signalCount, 0)
    }

    func testDecodeReportsMissingSchema() {
        let schema = CANSchema()
        var frame = canfd_frame()
        frame.can_id = 291
        frame.len = 8

        var message = CANSchemaDecodedMessage()
        var signals = Array(repeating: CANSchemaDecodedSignal(), count: 2)
        var signalCount = 7

        let status = signals.withUnsafeMutableBufferPointer { signalBuffer in
            withUnsafeMutablePointer(to: &message) { messagePtr in
                withUnsafeMutablePointer(to: &signalCount) { countPtr in
                    schema.decode(frame, messagePtr, signalBuffer.baseAddress, signalBuffer.count, countPtr)
                }
            }
        }

        XCTAssertEqual(status, Int32(ICAN_SCHEMA_STATUS_NOT_READY.rawValue))
        XCTAssertFalse(message.matched)
        XCTAssertEqual(signalCount, 0)
        if let error = schema.lastError() {
            XCTAssertEqual(String(cString: error), "schema is not loaded")
        } else {
            XCTFail("expected fallback error")
        }
    }

    private func loadSchema(_ schema: inout CANSchema) throws {
        let dbc = try loadFixtureDBC()

        let loaded = dbc.withCString { ptr in
            schema.loadDBCText(ptr)
        }
        XCTAssertTrue(loaded)
    }

    private func loadFixtureDBC() throws -> String {
        let env = ProcessInfo.processInfo.environment
        let testSrcDir = env["TEST_SRCDIR"] ?? ""
        let testWorkspace = env["TEST_WORKSPACE"] ?? ""
        let candidates = [
            "\(testSrcDir)/_main/can_schema/testdata/demo.dbc",
            "\(testSrcDir)/\(testWorkspace)/can_schema/testdata/demo.dbc",
        ]

        for path in candidates where !path.isEmpty {
            if let data = FileManager.default.contents(atPath: path),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }

        throw NSError(domain: "CANSchemaSwiftTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "failed to resolve can_schema/testdata/demo.dbc from Bazel runfiles",
        ])
    }

    private func stringView(_ ptr: UnsafePointer<CChar>?, _ len: Int) -> String {
        guard let ptr else { return "" }
        let buffer = UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: len)
        return String(decoding: buffer, as: UTF8.self)
    }

    private func makeFrame() -> canfd_frame {
        var frame = canfd_frame()
        frame.can_id = 0x123
        frame.len = 8
        return frame
    }
}
