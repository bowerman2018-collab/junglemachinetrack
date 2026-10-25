import XCTest
@testable import APRSCore

final class APRSParserTests: XCTestCase {
    func testUncompressedPosition() throws {
        let packet = try XCTUnwrap(TNC2.decode("N0CALL>APRS,WIDE1-1:!4903.50N/07201.75W-Test 001234"))
        let report = try XCTUnwrap(APRSParser.parse(packet))
        XCTAssertEqual(report.station, "N0CALL")
        XCTAssertEqual(report.position.latitude, 49.058333, accuracy: 1e-5)
        XCTAssertEqual(report.position.longitude, -72.029167, accuracy: 1e-5)
        XCTAssertEqual(report.position.symbolCode, "-")
        XCTAssertEqual(report.position.comment, "Test 001234")
    }

    func testTimestampedPositionWithCourseSpeedAltitude() throws {
        let packet = try XCTUnwrap(TNC2.decode("KD8ABC-7>APRS:@092345z3741.20N/08159.40Wj088/036/A=001500 on the trail"))
        let p = try XCTUnwrap(APRSParser.parse(packet)).position
        XCTAssertEqual(p.latitude, 37.686667, accuracy: 1e-5)
        XCTAssertEqual(p.longitude, -81.99, accuracy: 1e-5)
        XCTAssertEqual(p.courseDegrees, 88)
        XCTAssertEqual(p.speedKnots, 36)
        XCTAssertEqual(p.altitudeFeet, 1500)
        XCTAssertEqual(p.comment, "on the trail")
    }

    func testCompressedPosition() throws {
        // Example from the APRS 1.01 spec: 49 30.00N, 72 45.00W, course 88, speed 36.2 knots.
        let packet = APRSPacket(source: "N0CALL", destination: "APRS", info: "=/5L!!<*e7>7P[")
        let p = try XCTUnwrap(APRSParser.parse(packet)).position
        XCTAssertEqual(p.latitude, 49.5, accuracy: 1e-4)
        XCTAssertEqual(p.longitude, -72.75, accuracy: 1e-4)
        XCTAssertEqual(p.courseDegrees, 88)
        XCTAssertEqual(try XCTUnwrap(p.speedKnots), 36.2, accuracy: 0.1)
    }

    func testMicE() throws {
        // Example from the APRS 1.01 spec: 33 25.64N, 112 07.74W, 20 knots, course 251, jeep symbol.
        let packet = APRSPacket(source: "N0CALL", destination: "S32U6T", info: "`(_fn\"Oj/")
        let p = try XCTUnwrap(APRSParser.parse(packet)).position
        XCTAssertEqual(p.latitude, 33 + 25.64 / 60, accuracy: 1e-5)
        XCTAssertEqual(p.longitude, -(112 + 7.74 / 60), accuracy: 1e-5)
        XCTAssertEqual(p.speedKnots, 20)
        XCTAssertEqual(p.courseDegrees, 251)
        XCTAssertEqual(p.symbolCode, "j")
        XCTAssertEqual(p.symbolTable, "/")
    }

    func testObject() throws {
        let packet = APRSPacket(source: "N0CALL", destination: "APRS", info: ";CAMP     *092345z3741.20N/08159.40W;Base camp")
        let report = try XCTUnwrap(APRSParser.parse(packet))
        XCTAssertEqual(report.station, "CAMP")
        XCTAssertTrue(report.isObject)
        XCTAssertEqual(report.position.comment, "Base camp")
    }

    func testNMEA() throws {
        let packet = APRSPacket(source: "N0CALL", destination: "GPS",
                                info: "$GPRMC,123519,A,3741.200,N,08159.400,W,022.4,084.4,230394,003.1,W*6A")
        let p = try XCTUnwrap(APRSParser.parse(packet)).position
        XCTAssertEqual(p.latitude, 37.686667, accuracy: 1e-5)
        XCTAssertEqual(p.longitude, -81.99, accuracy: 1e-5)
        XCTAssertEqual(p.courseDegrees, 84)
    }

    func testThirdParty() throws {
        let packet = APRSPacket(source: "IGATE", destination: "APRS", info: "}N0CALL>APRS,TCPIP:!3741.20N/08159.40W>")
        XCTAssertEqual(try XCTUnwrap(APRSParser.parse(packet)).station, "N0CALL")
    }

    func testStatusIsNotAPosition() {
        let packet = APRSPacket(source: "N0CALL", destination: "APRS", info: ">Just a status")
        XCTAssertNil(APRSParser.parse(packet))
    }
}

final class FramingTests: XCTestCase {
    func testAX25RoundTrip() throws {
        let packet = APRSPacket(source: "KD8ABC-7", destination: "APRS", path: ["WIDE1-1*", "WIDE2-1"],
                                info: "!3741.20N/08159.40Wj")
        let decoded = try XCTUnwrap(AX25.decode(AX25.encode(packet)))
        XCTAssertEqual(decoded, packet)
    }

    func testKISSEscapingAndChunking() {
        let payload: [UInt8] = [0x01, KISS.fend, 0x02, KISS.fesc, 0x03]
        let stream = KISS.encode(payload) + KISS.encode([0x09])
        var decoder = KISSDecoder()
        var frames: [[UInt8]] = []
        for byte in stream { frames += decoder.feed([byte]) }
        XCTAssertEqual(frames, [payload, [0x09]])
    }

    func testStreamDecoderKISS() throws {
        let packet = APRSPacket(source: "KD8ABC", destination: "APRS", info: "!3741.20N/08159.40Wj")
        let bytes = KISS.encode(AX25.encode(packet))
        var decoder = RadioStreamDecoder()
        var out = decoder.feed(Array(bytes[0..<10]))
        out += decoder.feed(Array(bytes[10...]))
        XCTAssertEqual(out, [packet])
        XCTAssertEqual(decoder.mode, .kiss)
    }

    func testStreamDecoderTextAcrossChunks() {
        var decoder = RadioStreamDecoder()
        var out = decoder.feed(Latin1.bytes("KD8ABC>APRS:!3741.20N/0815"))
        XCTAssertTrue(out.isEmpty)
        out += decoder.feed(Latin1.bytes("9.40Wj\r\nKD8XYZ>APRS:!3741.00N/08159.00Wj\r\n"))
        XCTAssertEqual(out.map(\.source), ["KD8ABC", "KD8XYZ"])
        XCTAssertEqual(decoder.mode, .text)
    }

    func testStreamDecoderFlushWithoutNewline() {
        var decoder = RadioStreamDecoder()
        XCTAssertTrue(decoder.feed(Latin1.bytes("KD8ABC>APRS:!3741.20N/08159.40Wj")).isEmpty)
        XCTAssertEqual(decoder.flush().map(\.source), ["KD8ABC"])
    }

    func testTNC2WithPrefix() {
        XCTAssertEqual(TNC2.decode("[RX] KD8ABC-9>APRS,WIDE1-1:!3741.20N/08159.40Wj")?.source, "KD8ABC-9")
    }
}
