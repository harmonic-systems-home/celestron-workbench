import Foundation
import Network
import Synchronization
import Testing

@testable import ImuLoggerCore

/// End-to-end over loopback TCP against `FakeReceiver`.
@Suite(.serialized) struct UplinkTests {
    final class StatusBox: Sendable {
        let latest = Mutex<Uplink.Status?>(nil)
        var state: Uplink.State? { latest.withLock { $0?.state } }
        var reconnects: Int { latest.withLock { $0?.reconnects ?? 0 } }
    }

    private func makeUplink(
        _ receiver: FakeReceiver, log: URL?, maxPending: Int = 600
    ) async -> (Uplink, StatusBox) {
        let box = StatusBox()
        let uplink = Uplink(
            endpoint: await receiver.endpoint, hello: testHello(), logURL: log,
            maxPendingBatches: maxPending
        ) { status in box.latest.withLock { $0 = status } }
        return (uplink, box)
    }

    @Test func streamsBatchesAndFinishesWithBye() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let (uplink, box) = await makeUplink(receiver, log: nil)
        uplink.start()
        #expect(await eventually { box.state == .streaming })
        for start in stride(from: Seq(0), to: 100, by: 10) {
            uplink.send(batch: batch(start...(start + 9)))
        }
        uplink.finish(
            with: Bye(
                protocolVersion: protocolVersion, sessionId: testSession, deviceId: testDevice,
                lastSeq: 99, reason: .operatorStop))
        #expect(await eventually { box.state == .finished })
        let state = receiver.state.withLock { $0 }
        #expect(state.stored == Set(0..<100))
        #expect(state.byes == 1)
    }

    @Test func recoversFromConnectionLossWithoutLosingSamples() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let directory = try temporaryDirectory()
        let log = try SessionLog(creating: directory.appendingPathComponent("s.ndjson"))
        let (uplink, box) = await makeUplink(receiver, log: log.url)
        uplink.start()
        #expect(await eventually { box.state == .streaming })
        var next: Seq = 0
        func sendBatches(_ count: Int) throws {
            for _ in 0..<count {
                let b = batch(next...(next + 9))
                try log.append(.sampleBatch(b))
                uplink.send(batch: b)
                next += 10
            }
        }
        try sendBatches(5)
        #expect(await eventually { receiver.state.withLock { $0.stored.count } == 50 })
        receiver.dropConnection()
        try sendBatches(5)  // sent while the connection is failing
        #expect(await eventually { box.reconnects >= 1 && box.state == .streaming })
        try sendBatches(5)
        #expect(await eventually { receiver.state.withLock { $0.stored } == Set(0..<150) })
        #expect(receiver.state.withLock { $0.hellos } >= 2)
        uplink.cancel()
    }

    @Test func resendsFromTheLogWhenTheReceiverLostData() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let directory = try temporaryDirectory()
        let log = try SessionLog(creating: directory.appendingPathComponent("s.ndjson"))
        let (uplink, box) = await makeUplink(receiver, log: log.url, maxPending: 2)
        uplink.start()
        #expect(await eventually { box.state == .streaming })
        for start in stride(from: Seq(0), to: 100, by: 10) {
            let b = batch(start...(start + 9))
            try log.append(.sampleBatch(b))
            uplink.send(batch: b)
        }
        #expect(await eventually { receiver.state.withLock { $0.stored.count } == 100 })
        receiver.forget(after: 29)  // Mac restarted and lost everything after seq 29
        receiver.dropConnection()
        #expect(await eventually { receiver.state.withLock { $0.stored } == Set(0..<100) })
        uplink.cancel()
    }

    @Test func queuesMarkersWhileDisconnected() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let (uplink, box) = await makeUplink(receiver, log: nil)
        let marker = Message.marker(
            Marker(
                protocolVersion: protocolVersion, sessionId: testSession, deviceId: testDevice,
                markerId: "44444444-4444-4444-8444-444444444444", label: "start", tNs: 1,
                notes: nil))
        uplink.send(marker)  // before connecting
        uplink.start()
        #expect(await eventually { receiver.state.withLock { $0.others } == [marker] })
        #expect(box.state == .streaming)
        uplink.cancel()
    }

    @Test func runsClockExchangesWhileConnected() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        let results = Mutex<[ClockResult]>([])
        let uplink = Uplink(
            endpoint: await receiver.endpoint, hello: testHello(), logURL: nil,
            clockInterval: 0.05, onClockResult: { result in results.withLock { $0.append(result) } }
        ) { _ in }
        uplink.start()
        // The burst is never slower than the interval, so this is all 50 ms apart.
        #expect(await eventually(timeout: 10) { results.withLock { $0.count } >= 8 })
        let completed = results.withLock { $0 }
        #expect(completed.map(\.exchangeIndex) == Array(0..<UInt64(completed.count)))
        for result in completed {
            #expect(result.sessionId == testSession && result.deviceId == testDevice)
            #expect(result.macClockBootId == FakeReceiver.clockBootId)
            #expect(result.phoneReceiveNs >= result.phoneSendNs)
        }

        // Exchanges start again after a reconnect, with new indexes.
        let before = completed.count
        receiver.dropConnection()
        #expect(await eventually(timeout: 10) { results.withLock { $0.count } >= before + 2 })
        let indexes = results.withLock { $0.map(\.exchangeIndex) }
        #expect(Set(indexes).count == indexes.count)
        uplink.cancel()
    }

    @Test func stopsWhenTheReceiverRejectsTheSession() async throws {
        let receiver = try FakeReceiver()
        defer { receiver.stop() }
        receiver.state.withLock { $0.acceptSessions = false }
        let (uplink, box) = await makeUplink(receiver, log: nil)
        uplink.start()
        #expect(await eventually { box.state == .rejected("test rejection") })
        try await Task.sleep(for: .milliseconds(500))
        #expect(receiver.state.withLock { $0.hellos } == 1)  // no retry loop
    }

    @Test func retriesUntilTheReceiverAppears() async throws {
        // Reserve a port, then close it so the first attempts are refused.
        let probe = try FakeReceiver()
        let endpoint = await probe.endpoint
        probe.stop()
        let box = StatusBox()
        let uplink = Uplink(endpoint: endpoint, hello: testHello(), logURL: nil) { status in
            box.latest.withLock { $0 = status }
        }
        uplink.start()
        #expect(
            await eventually {
                if case .waitingToRetry = box.state { return true }
                return false
            })
        uplink.cancel()
        #expect(await eventually { box.state == .finished })
    }

    @Test func anUnadvertisedReceiverIsRetriedRatherThanAwaitedForever() async throws {
        // A Bonjour name nobody advertises never fails; it waits to resolve.
        let endpoint = NWEndpoint.service(
            name: "cwb-test-\(UUID().uuidString)", type: "_cwb-imu._tcp", domain: "local.",
            interface: nil)
        let box = StatusBox()
        let uplink = Uplink(
            endpoint: endpoint, hello: testHello(), logURL: nil, connectTimeout: 0.2
        ) { status in
            box.latest.withLock { $0 = status }
        }
        uplink.start()
        #expect(
            await eventually {
                box.latest.withLock { $0?.lastError?.contains("no receiver answered") ?? false }
            })
        uplink.cancel()
        #expect(await eventually { box.state == .finished })
    }
}
