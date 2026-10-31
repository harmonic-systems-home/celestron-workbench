import Foundation
import Testing

@testable import AuxListenerCore

private let ms: UInt64 = 1_000_000
private let hc: UInt8 = 0x0d
private let azm: UInt8 = 0x10
private let alt: UInt8 = 0x11
private let wifi: UInt8 = 0xb5

private func packets(_ events: [FramerEvent]) -> [AuxPacket] {
    events.compactMap { if case .packet(let p, _) = $0 { p } else { nil } }
}

private func anomalies(_ events: [FramerEvent]) -> [AnomalyKind] {
    events.compactMap { if case .anomaly(let k, _, _) = $0 { k } else { nil } }
}

@Test func checksumIsTheTwosComplementOfTheSum() {
    // GET_POSITION from the hand control to azimuth: 0x03 + 0x04 + 0x10 + 0x01 = 0x18, so 0xE8.
    let bytes = Aux.encode(source: 0x04, destination: 0x10, id: 0x01)
    #expect(bytes == [0x3B, 0x03, 0x04, 0x10, 0x01, 0xE8])
    #expect(AuxPacket(raw: bytes)?.id == 0x01)
}

@Test func cleanTrafficFromSeveralDevicesFrames() {
    var framer = Framer()
    let stream =
        Aux.encode(source: hc, destination: azm, id: 0x01)
        + Aux.encode(source: azm, destination: hc, id: 0x01, data: [0x01, 0x02, 0x03])
        + Aux.encode(source: wifi, destination: alt, id: 0x24, data: [5])
        + Aux.encode(source: alt, destination: wifi, id: 0x24)
    // Split mid-packet, as reads do.
    let events = framer.feed(Array(stream[0..<7]), at: 0) + framer.feed(Array(stream[7...]), at: ms)
    let got = packets(events)
    #expect(got.map(\.source) == [hc, azm, wifi, alt])
    #expect(got[1].data == [0x01, 0x02, 0x03])
    #expect(anomalies(events).isEmpty)
}

@Test func aPreambleByteInsideDataDoesNotSplitTheFrame() {
    var framer = Framer()
    let bytes = Aux.encode(source: azm, destination: hc, id: 0x01, data: [0x3B, 0x3B, 0x00])
    #expect(packets(framer.feed(bytes, at: 0)).count == 1)
}

@Test func aCorruptedChecksumIsReportedAndFramingRecovers() {
    var framer = Framer()
    var bad = Aux.encode(source: hc, destination: azm, id: 0x01)
    bad[bad.count - 1] ^= 0xFF
    let events = framer.feed(bad + Aux.encode(source: hc, destination: alt, id: 0x01), at: 0)
    #expect(anomalies(events) == [.badChecksum])
    #expect(packets(events).map(\.destination) == [alt])
}

@Test func aFrameCutShortIsReportedAfterTheLineGoesQuiet() {
    var framer = Framer()
    let whole = Aux.encode(source: hc, destination: azm, id: 0x17, data: [1, 2, 3])
    #expect(framer.feed(Array(whole.prefix(5)), at: 0).isEmpty)
    // Still within the gap: nothing yet.
    #expect(framer.flush(at: 10 * ms).isEmpty)
    #expect(anomalies(framer.flush(at: 30 * ms)) == [.truncated])
    // The next packet frames normally.
    #expect(
        packets(framer.feed(Aux.encode(source: hc, destination: azm, id: 0x01), at: 40 * ms)).count
            == 1)
}

@Test func strayBytesBetweenFramesAreReported() {
    var framer = Framer()
    let events = framer.feed(
        [0x00, 0xFF, 0x12] + Aux.encode(source: hc, destination: azm, id: 0x01), at: 0)
    #expect(anomalies(events) == [.noise])
    #expect(packets(events).count == 1)
}

@Test func anImpossibleLengthIsReported() {
    var framer = Framer()
    #expect(anomalies(framer.feed([0x3B, 0x01], at: 0)) == [.badLength])
    #expect(anomalies(framer.feed([0x3B, 0xF0], at: ms)) == [.badLength])
}

@Test func repliesPairWithTheirRequestsAndDecode() {
    var monitor = BusMonitor()
    let request = AuxPacket(raw: Aux.encode(source: hc, destination: azm, id: 0x01))!
    // 0x400000 is a quarter turn: 90°.
    let reply = AuxPacket(
        raw: Aux.encode(source: azm, destination: hc, id: 0x01, data: [0x40, 0, 0]))!
    let a = monitor.process(.packet(request, at: 0))
    let b = monitor.process(.packet(reply, at: 52 * ms))
    guard case .packet(let q) = a.first, case .packet(let r) = b.first else {
        Issue.record("expected two packets")
        return
    }
    #expect(!q.isReply && q.isPolling)
    #expect(r.isReply && r.latencyMs == 52)
    #expect(r.text == "Azimuth → Hand control+  GET_POSITION = 90.00000° (52 ms)")
}

@Test func keypadMovesReadAsRatesAndStops() {
    var monitor = BusMonitor()
    let move = AuxPacket(raw: Aux.encode(source: hc, destination: alt, id: 0x25, data: [3]))!
    let stop = AuxPacket(raw: Aux.encode(source: hc, destination: alt, id: 0x25, data: [0]))!
    let texts = (monitor.process(.packet(move, at: 0)) + monitor.process(.packet(stop, at: ms)))
        .compactMap { if case .packet(let p) = $0 { p.text } else { nil } }
    #expect(
        texts == [
            "Hand control+ → Altitude  MOVE_NEG rate 3", "Hand control+ → Altitude  MOVE_NEG stop",
        ])
}

@Test func anUnansweredRequestBecomesAnAnomaly() {
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    let request = AuxPacket(raw: Aux.encode(source: wifi, destination: alt, id: 0xfe))!
    _ = monitor.process(.packet(request, at: 0))
    #expect(monitor.expire(at: 400 * ms).isEmpty)
    let late = monitor.expire(at: 600 * ms)
    guard case .anomaly(let a) = late.first else {
        Issue.record("expected a no-reply anomaly")
        return
    }
    #expect(a.kind == .noReply)
    #expect(a.detail == "No reply: Wi-Fi → Altitude  GET_VERSION")
    #expect(monitor.expire(at: 700 * ms).isEmpty)
}

@Test func announcementsToAnyExpectNoReply() {
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    let hello = AuxPacket(raw: Aux.encode(source: 0xb0, destination: 0x00, id: 0x01))!
    _ = monitor.process(.packet(hello, at: 0))
    #expect(monitor.expire(at: 2_000 * ms).isEmpty)
}

@Test func logLinesKeepRawBytesAndTimes() throws {
    var monitor = BusMonitor()
    let p = AuxPacket(raw: Aux.encode(source: hc, destination: azm, id: 0x24, data: [5]))!
    guard case .packet(let d) = monitor.process(.packet(p, at: 123)).first else {
        Issue.record("expected a packet")
        return
    }
    let line = LogLine.packet(d, utc: Date(timeIntervalSince1970: 0))
    let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    #expect(json["event"] as? String == "packet")
    #expect(json["hex"] as? String == hexBytes(p.raw))
    #expect(json["t_ns"] as? Int == 123)
    #expect(json["utc"] as? String == "1970-01-01T00:00:00.000Z")
    #expect(json["text"] as? String == "Hand control+ → Azimuth  MOVE_POS rate 5")
}

@Test func demoTrafficFramesAndShowsEachAnomalyKind() {
    var demo = DemoTraffic(start: 0)
    var framer = Framer()
    var monitor = BusMonitor()
    var kinds = Set<AnomalyKind>()
    var commands = 0
    var t: UInt64 = 0
    while t < 35_000 * ms {
        t += 50 * ms
        for (bytes, at) in demo.advance(to: t) {
            for e in framer.feed(bytes, at: at) {
                for b in monitor.process(e) {
                    switch b {
                    case .anomaly(let a): kinds.insert(a.kind)
                    case .packet(let p) where !p.isPolling: commands += 1
                    default: break
                    }
                }
            }
        }
        for b in monitor.expire(at: t) {
            if case .anomaly(let a) = b { kinds.insert(a.kind) }
        }
    }
    #expect(kinds == [.badChecksum, .noReply])
    #expect(commands > 4)
}
