import XCTest
import IntatisCore
@testable import IntatisProtocol

final class IntatisProtocolTests: XCTestCase {

    private let enc = Envelope.makeEncoder()
    private let dec = Envelope.makeDecoder()

    private func roundTrip(_ env: Envelope, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try enc.encode(env)
        let back = try dec.decode(Envelope.self, from: data)
        XCTAssertEqual(back, env, file: file, line: line)
    }

    func testEnvelopeRoundTripAllEvents() throws {
        let s = SessionID(rawValue: "sess_x")
        let m = MessageID(rawValue: "msg_1")
        try roundTrip(Envelope(seq: 1, ts: Date(timeIntervalSince1970: 1_700_000_000), session: s,
                               event: .userMessage(.init(text: "hi", to: AgentID(rawValue: "Rokurics")))))
        try roundTrip(Envelope(seq: 2, ts: Date(timeIntervalSince1970: 1_700_000_001), session: s,
                               event: .messageDelta(.init(messageId: m, role: .assistant, textDelta: "he"))))
        try roundTrip(Envelope(seq: 3, ts: Date(timeIntervalSince1970: 1_700_000_002), session: s,
                               event: .messageCompleted(.init(messageId: m, role: .assistant, text: "hello"))))
        try roundTrip(Envelope(seq: 4, ts: Date(timeIntervalSince1970: 1_700_000_003), session: s,
                               event: .error(.init(code: "provider", message: "boom", fatal: true))))
    }

    func testEnvelopeWireShapeIsFlat() throws {
        let env = Envelope(seq: 7, ts: Date(timeIntervalSince1970: 1_700_000_000),
                           session: SessionID(rawValue: "sess_x"),
                           event: .messageDelta(.init(messageId: MessageID(rawValue: "msg_1"),
                                                      role: .assistant, textDelta: "x")))
        let data = try enc.encode(env)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["seq"] as? Int, 7)
        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["type"] as? String, "message_delta")
        let payload = try XCTUnwrap(json["payload"] as? [String: Any])
        XCTAssertEqual(payload["textDelta"] as? String, "x")
        XCTAssertEqual(payload["role"] as? String, "assistant")
    }

    func testCommandRoundTrip() throws {
        let cmds: [Command] = [
            .sessionCreate(.init(kind: .chat, title: "Hello")),
            .sessionResume(.init(session: SessionID(rawValue: "sess_x"), fromSeq: 12)),
            .sessionList,
            .messageSend(.init(session: SessionID(rawValue: "sess_x"), text: "hi"))
        ]
        let e = JSONEncoder()
        let d = JSONDecoder()
        for cmd in cmds {
            let data = try e.encode(cmd)
            let back = try d.decode(Command.self, from: data)
            XCTAssertEqual(back, cmd)
        }
    }

    func testCommandMethodString() throws {
        let data = try JSONEncoder().encode(
            Command.messageSend(.init(session: SessionID(rawValue: "s"), text: "hi")))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["method"] as? String, "message.send")
    }
}
