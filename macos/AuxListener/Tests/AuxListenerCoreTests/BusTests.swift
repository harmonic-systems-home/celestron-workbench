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
    #expect(anomalies(framer.flush(at: 60 * ms)) == [.truncated])
    // The next packet frames normally.
    #expect(
        packets(framer.feed(Aux.encode(source: hc, destination: azm, id: 0x01), at: 70 * ms)).count
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

@Test func aReplySplitAcrossUSBBatchesStaysWhole() {
    // Seen on the mount: the first two bytes, then the rest 33 ms later.
    var framer = Framer()
    let whole = Aux.encode(source: azm, destination: 0x0e, id: 0x25)
    var events = framer.feed(Array(whole[..<2]), at: 0)
    events += framer.flush(at: 33 * ms)
    events += framer.feed(Array(whole[2...]), at: 33 * ms)
    #expect(anomalies(events).isEmpty)
    #expect(packets(events).first?.raw == whole)
}

@Test func accessoriesNotHeardFromAreNotFaults() {
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    // The hand controller asks for a focuser and a camera still starting up.
    for address in [UInt8(0x12), 0xb4] {
        let probe = AuxPacket(raw: Aux.encode(source: 0x0e, destination: address, id: 0xfe))!
        _ = monitor.process(.packet(probe, at: 0))
    }
    #expect(monitor.expire(at: 600 * ms).isEmpty)
    // Once the camera has answered, a missed reply counts.
    let ask = AuxPacket(raw: Aux.encode(source: 0x0e, destination: 0xb4, id: 0x05))!
    let answer = AuxPacket(raw: Aux.encode(source: 0xb4, destination: 0x0e, id: 0x05, data: [1]))!
    _ = monitor.process(.packet(ask, at: 700 * ms))
    _ = monitor.process(.packet(answer, at: 710 * ms))
    _ = monitor.process(.packet(ask, at: 800 * ms))
    guard case .anomaly(let a) = monitor.expire(at: 1_400 * ms).first else {
        Issue.record("expected a no-reply anomaly")
        return
    }
    #expect(a.detail == "No reply: StarSense HC → StarSense  msg 0x05")
}

@Test func aLateAnswerIsNotANewRequest() {
    // Seen on the mount: the camera answered 1.09 s after the request.
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    let ask = AuxPacket(raw: Aux.encode(source: 0x0e, destination: 0xb4, id: 0x05))!
    let answer = AuxPacket(raw: Aux.encode(source: 0xb4, destination: 0x0e, id: 0x05, data: [1]))!
    _ = monitor.process(.packet(ask, at: 0))
    guard case .packet(let late) = monitor.process(.packet(answer, at: 1_090 * ms)).last else {
        Issue.record("expected a packet")
        return
    }
    #expect(late.isReply && late.latencyMs == nil)
    #expect(late.text == "StarSense → StarSense HC  msg 0x05 [01] (late)")
    #expect(monitor.expire(at: 2_000 * ms).isEmpty)
}

@Test func aProbeRepeatedWithChecksumZeroIsKnownNotAFault() {
    // From the mount at startup: a focuser probe, then 0.5 s later the same
    // header with 00 where the checksum (DF) belongs.
    var framer = Framer()
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    let probe = Aux.encode(source: 0x0e, destination: 0x12, id: 0xfe)
    #expect(probe == [0x3b, 0x03, 0x0e, 0x12, 0xfe, 0xdf])
    let run = { (bytes: [UInt8], t: UInt64) in
        framer.feed(bytes, at: t).flatMap { monitor.process($0) }
    }
    _ = run(probe, 0)
    let repeated = run([0x3b, 0x03, 0x0e, 0x12, 0xfe, 0x00], 495 * ms)
    guard case .known(let k) = repeated.last, repeated.count == 1 else {
        Issue.record("expected one known frame, got \(repeated)")
        return
    }
    #expect(k.kind == "probe_checksum_00")
    #expect(k.text == "StarSense HC → Focuser  msg 0xFE repeated, checksum 00 (unanswered probe)")
    // Anything else ending 00 is still a fault: no matching request here.
    let other = run([0x3b, 0x03, 0x0e, 0x17, 0x10, 0x00], 600 * ms)
    guard case .anomaly(let a) = other.last else {
        Issue.record("expected a bad checksum")
        return
    }
    #expect(a.kind == .badChecksum)
}

@Test func aPacketSplitByAReplyDecodesBoth() {
    // From the mount with SkySafari over Wi-Fi: its altitude position request
    // stopped after three bytes and the azimuth's reply came in the gap.
    var framer = Framer()
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    let run = { (bytes: [UInt8], t: UInt64) in
        framer.feed(bytes, at: t).flatMap { monitor.process($0) }
    }
    _ = run(Aux.encode(source: 0x20, destination: azm, id: 0x01), 0)
    let woven: [UInt8] = [
        0x3b, 0x03, 0x20, 0x3b, 0x06, 0x10, 0x20, 0x01, 0xff, 0xff, 0xff, 0xcc, 0x11, 0x01, 0xcb,
    ]
    let events = run(woven, 16 * ms)
    var texts: [String] = []
    for event in events {
        switch event {
        case .known(let k): texts.append(k.text)
        case .packet(let p): texts.append(p.text)
        case .anomaly(let a): Issue.record("unexpected anomaly \(a.detail)")
        }
    }
    #expect(
        texts == [
            "App (Wi-Fi) → Altitude  GET_POSITION split by Azimuth → App (Wi-Fi)  GET_POSITION",
            "Azimuth → App (Wi-Fi)  GET_POSITION = 359.99998° (16 ms)",
            "App (Wi-Fi) → Altitude  GET_POSITION",
        ])
    // The split request still expects its answer.
    let answer = run(
        Aux.encode(source: alt, destination: 0x20, id: 0x01, data: [0, 0, 0]), 32 * ms)
    guard case .packet(let p) = answer.last else {
        Issue.record("expected the altitude reply")
        return
    }
    #expect(p.isReply && p.latencyMs == 16)
}

@Test func aSplitAfterTheLengthByteDecodesToo() {
    // Also seen: the reply came after only the preamble and length.
    var framer = Framer()
    let woven: [UInt8] = [
        0x3b, 0x06, 0x3b, 0x03, 0x10, 0x20, 0x06, 0xc7, 0x20, 0x10, 0x06, 0x00, 0x00, 0x00, 0xc4,
    ]
    guard case .split(let outer, let inner, let raw, _, _) = framer.feed(woven, at: 0).first else {
        Issue.record("expected a split packet")
        return
    }
    #expect(outer.raw == Aux.encode(source: 0x20, destination: azm, id: 0x06, data: [0, 0, 0]))
    #expect(inner.raw == Aux.encode(source: azm, destination: 0x20, id: 0x06))
    #expect(raw == woven)
}

@Test func aBadFrameThatIsNotTwoPacketsStaysABadChecksum() {
    // A wrong checksum with a 3B inside that doesn't make two packets: the
    // frame is a bad checksum and the next packet still frames.
    var framer = Framer()
    let bad: [UInt8] = [0x3b, 0x03, 0x0d, 0x3b, 0x03, 0x10]
    let good = Aux.encode(source: hc, destination: azm, id: 0x01)
    let events = framer.feed(bad + good, at: 0)
    #expect(anomalies(events) == [.badChecksum])
    #expect(packets(events) == [AuxPacket(raw: good)!])
    // And when the line goes quiet partway, nothing is lost or invented.
    var quiet = Framer()
    let partial = quiet.feed(bad + [0x3b, 0x03], at: 0)
    #expect(partial.isEmpty)
    let flushed = quiet.flush(at: 100 * ms)
    #expect(anomalies(flushed) == [.badChecksum, .truncated])
}

@Test func aCaptureMayTakeSecondsToAnswer() {
    // On the mount: SkySafari reset and started a capture; the camera
    // answered 2.8 s and 5.0 s later.
    var monitor = BusMonitor(replyTimeoutNs: 500 * ms)
    let hello = AuxPacket(raw: Aux.encode(source: 0xb4, destination: 0x20, id: 0x3f, data: [0]))!
    _ = monitor.process(.packet(hello, at: 0))
    let start = AuxPacket(raw: Aux.encode(source: 0x20, destination: 0xb4, id: 0x94, data: [0]))!
    _ = monitor.process(.packet(start, at: 100 * ms))
    #expect(monitor.expire(at: 3_000 * ms).isEmpty)
    let done = AuxPacket(raw: Aux.encode(source: 0xb4, destination: 0x20, id: 0x94, data: [9, 9]))!
    guard case .packet(let p) = monitor.process(.packet(done, at: 5_100 * ms)).last else {
        Issue.record("expected the capture answer")
        return
    }
    #expect(p.latencyMs == 5_000)
    // Other messages to the camera keep the short timeout.
    let ask = AuxPacket(raw: Aux.encode(source: 0x20, destination: 0xb4, id: 0x3f, data: [0]))!
    _ = monitor.process(.packet(ask, at: 6_000 * ms))
    #expect(monitor.expire(at: 6_600 * ms).count == 1)
}

@Test func aBulkFrameIsKeptNotStray() {
    // The shape of the 3C frame seen after GET_CAPTURE_DATA: 3C, a 4-byte
    // big-endian length, the data, and a packet-style checksum.
    let data: [UInt8] = [0x34, 0x04, 0x48, 0x44, 0x6b, 0x89, 0x55, 0x00]
    let body: [UInt8] = [0, 0, 0, UInt8(data.count)] + data
    let frame = [Bulk.preamble] + body + [Aux.checksum(body)]
    var framer = Framer()
    var monitor = BusMonitor()
    let reply = Aux.encode(source: 0xb4, destination: 0x20, id: 0x92, data: [9, 9])
    let events = framer.feed(reply + frame + reply, at: 0).flatMap { monitor.process($0) }
    let known = events.compactMap { if case .known(let k) = $0 { k } else { nil } }
    #expect(known.map(\.kind) == ["bulk_3c"])
    #expect(known.first?.bytes == frame)
    #expect(events.allSatisfy { if case .anomaly = $0 { false } else { true } })
    // A 3C with an impossible length is a stray byte, and framing recovers.
    var other = Framer()
    let stray = other.feed([0x3c, 0xff, 0xff, 0xff, 0xff] + reply, at: 0)
    #expect(anomalies(stray) == [.noise])
    #expect(packets(stray) == [AuxPacket(raw: reply)!])
}

@Test func starSenseMessagesDecode() {
    var monitor = BusMonitor()
    func text(_ request: [UInt8], _ id: UInt8, _ data: [UInt8]) -> String? {
        let ask = AuxPacket(
            raw: Aux.encode(source: 0x0e, destination: 0xb4, id: id, data: request))!
        let answer = AuxPacket(
            raw: Aux.encode(source: 0xb4, destination: 0x0e, id: id, data: data))!
        _ = monitor.process(.packet(ask, at: 0))
        guard case .packet(let p) = monitor.process(.packet(answer, at: 16 * ms)).first else {
            return nil
        }
        return p.text
    }
    #expect(
        text([0], 0x3f, [0x47, 0x03, 0, 0, 0x7d, 0x01, 0, 0])
            == "StarSense → StarSense HC  GET_ALIGN_CENTER = x 839, y 381 (16 ms)")
    #expect(
        text([], 0x91, [1, 0])
            == "StarSense → StarSense HC  GET_STATUS = status 1, 0 stars (16 ms)")
    #expect(text([], 0x05, [1]) == "StarSense → StarSense HC  msg 0x05 [01] (16 ms)")
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

@Test func batteryRepliesDecodeTheirVoltageAndCountAsPolling() {
    var monitor = BusMonitor()
    let request = AuxPacket(raw: Aux.encode(source: hc, destination: 0xb6, id: 0x10))!
    // As the bench mount answered on 2026-11-10: 10.056 V.
    let reply = AuxPacket(
        raw: Aux.encode(
            source: 0xb6, destination: hc, id: 0x10, data: [0x02, 0x02, 0x00, 0x99, 0x71, 0x40]))!
    let a = monitor.process(.packet(request, at: 0))
    let b = monitor.process(.packet(reply, at: 20 * ms))
    guard case .packet(let q) = a.first, case .packet(let r) = b.first else {
        Issue.record("expected two packets")
        return
    }
    #expect(q.isPolling && r.isPolling)
    #expect(r.text == "Battery → Hand control+  GET_VOLTAGE = 10.06 V, level 2, state 2 (20 ms)")
    #expect(BusMonitor.battery(r) == BatteryMessage.Reading(volts: 10.056, level: 2, state: 2))
    #expect(BusMonitor.battery(q) == nil)
}

@Test func aRequestThatPausesPartwayIsOneAnomalyNotThree() {
    // As heard on 2026-11-10: the HC sends five bytes of a position read,
    // pauses about 0.5 s, then the checksum and the request again with 00
    // for its checksum; the motor answers after that.
    let hcStarSense: UInt8 = 0x0e
    let request = Aux.encode(source: hcStarSense, destination: alt, id: 0x01)
    let reply = Aux.encode(source: alt, destination: hcStarSense, id: 0x01, data: [0, 0, 1])
    var framer = Framer()
    var joiner = PauseJoiner()
    var monitor = BusMonitor()
    var events: [BusEvent] = []
    func run(_ e: [FramerEvent], _ t: UInt64) {
        events += joiner.process(e, at: t).flatMap { monitor.process($0) }
    }
    run(framer.feed(Array(request.prefix(5)), at: 0), 0)
    run(framer.flush(at: 200 * ms), 200 * ms)
    run(framer.feed([request[5]] + request.dropLast() + [0x00], at: 500 * ms), 500 * ms)
    run(framer.feed(reply, at: 525 * ms), 525 * ms)
    run(framer.flush(at: 3000 * ms), 3000 * ms)
    let found = events.compactMap { if case .anomaly(let a) = $0 { a } else { nil } }
    #expect(found.map(\.kind) == [.paused])
    #expect(found.first?.detail.contains("StarSense HC → Altitude  GET_POSITION") == true)
    #expect(found.first?.detail.contains("500 ms") == true)
    #expect(found.first?.bytes.count == 12)
    #expect(events.contains { if case .packet(let p) = $0 { p.packet.source == alt } else { false } })
}

@Test func aFrameCutShortWithNothingAfterStaysCutShort() {
    var framer = Framer()
    var joiner = PauseJoiner()
    let whole = Aux.encode(source: hc, destination: azm, id: 0x17, data: [1, 2, 3])
    #expect(joiner.process(framer.feed(Array(whole.prefix(5)), at: 0), at: 0).isEmpty)
    // Held through its window, then passed on unchanged.
    #expect(joiner.process(framer.flush(at: 100 * ms), at: 100 * ms).isEmpty)
    #expect(anomalies(joiner.process(framer.flush(at: 1600 * ms), at: 1600 * ms)) == [.truncated])
}

@Test func strayBytesOnTheirOwnAreNotHeld() {
    var framer = Framer()
    var joiner = PauseJoiner()
    #expect(anomalies(joiner.process(framer.feed([0xDD], at: 0), at: 0)).isEmpty)
    #expect(anomalies(joiner.process(framer.flush(at: 100 * ms), at: 100 * ms)) == [.noise])
}
