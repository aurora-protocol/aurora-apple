import Foundation
import XCTest
@testable import AuroraKit

final class AuroraNativeProvisioningCoreTests: XCTestCase {
    func testNativeProvisioningStoreKeepsOpaqueBundleInCredentialStore() async throws {
        let credentialStore = MockSecureCredentialStore()
        let store = AuroraNativeProvisioningStore(credentialStore: credentialStore, validator: MockNativeProvisioningValidator())
        let provisioning = Data(repeating: 0x7a, count: 64)

        try await store.save(provisioning, identifier: "production-slot")

        let loaded = try await store.load(identifier: "production-slot")
        let stored = await credentialStore.savedData(
            service: AuroraNativeProvisioningStore.service,
            account: AuroraNativeProvisioningStore.account(identifier: "production-slot")
        )
        XCTAssertEqual(loaded, provisioning)
        XCTAssertEqual(
            stored,
            provisioning
        )
    }

    func testNativePacketTunnelCoreUsesOpaqueCoreSessionAndIssuerTransport() async throws {
        let credentialStore = MockSecureCredentialStore()
        let provisioning = Data(repeating: 0x6b, count: 64)
        let reservation = AuroraNativeProvisioningReservation(
            provisioning: provisioning,
            spentHintKey: Data(repeating: 0x51, count: 48),
            relayBucketID: Data(repeating: 0x61, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let provisioningStore = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator(),
            reserver: MockNativeProvisioningReserver(reservations: [reservation])
        )
        try await provisioningStore.save(provisioning, identifier: "production-slot")
        let driver = MockNativeSessionDriver(
            work: AuroraNativeIssuerWork(
                handle: 41,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/41",
                requestBody: Data([0x01, 0x02, 0x03])
            ),
            ingressPackets: [Data([0x45, 0x00, 0x00, 0x14])],
            nextPacket: Data([0x60, 0x00, 0x00, 0x00])
        )
        let issuer = MockNativeIssuerTransport(response: Data([0xaa, 0xbb]))
        let core = AuroraNativePacketTunnelCore(
            provisioningStore: provisioningStore,
            sessionDriver: driver,
            issuerTransport: issuer
        )
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            nativeProvisioningIdentifier: "production-slot"
        )

        try await core.connect(configuration: configuration)
        let immediate = try await core.ingestPacketBatch(AuroraPacketFlowBatch(
            packets: [Data([0x45, 0x00, 0x00, 0x14])],
            protocolNumbers: [2]
        ))
        let remote = try await core.nextOutboundPacketBatch()
        await core.close()

        let beginProvisioning = await driver.beginProvisioning
        let completedHandle = await driver.completedHandle
        let completedResponse = await driver.completedResponse
        let ingressPackets = await driver.ingressPackets
        let closedHandles = await driver.closedHandles
        let requestedURL = await issuer.requestedURL
        let requestedBody = await issuer.requestedBody
        XCTAssertEqual(beginProvisioning, provisioning)
        XCTAssertEqual(completedHandle, 41)
        XCTAssertEqual(completedResponse, Data([0xaa, 0xbb]))
        XCTAssertEqual(ingressPackets, [Data([0x45, 0x00, 0x00, 0x14])])
        XCTAssertEqual(closedHandles, [41])
        XCTAssertEqual(requestedURL?.path, "/assets/issue/41")
        XCTAssertEqual(requestedBody, Data([0x01, 0x02, 0x03]))
        XCTAssertEqual(immediate.protocolNumbers, [2])
        XCTAssertEqual(remote.protocolNumbers, [30])
    }

    func testNativeProvisioningStorePersistsReservationsAcrossInstances() async throws {
        let credentials = MockSecureCredentialStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa1, count: 64),
            spentHintKey: Data(repeating: 0x11, count: 48),
            relayBucketID: Data(repeating: 0x21, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let second = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xa2, count: 64),
            spentHintKey: Data(repeating: 0x12, count: 48),
            relayBucketID: Data(repeating: 0x21, count: 16),
            accessHintExpiryUnix: 1_800_003_600
        )
        let firstReserver = MockNativeProvisioningReserver(reservations: [first])
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: firstReserver
        )
        try await store.save(Data(repeating: 0xaa, count: 128), identifier: "recovery-slot")
        let firstResult = try await store.reserve(identifier: "recovery-slot", now: now)
        XCTAssertEqual(firstResult, first)

        let secondReserver = MockNativeProvisioningReserver(reservations: [second])
        let restoredStore = AuroraNativeProvisioningStore(
            credentialStore: credentials,
            validator: MockNativeProvisioningValidator(),
            reserver: secondReserver
        )
        let secondResult = try await restoredStore.reserve(identifier: "recovery-slot", now: now)
        XCTAssertEqual(secondResult, second)
        let secondReservedSpentHintKeys = await secondReserver.reservedSpentHintKeys
        XCTAssertEqual(secondReservedSpentHintKeys, [[first.spentHintKey]])

        let storedLedgerData = await credentials.savedData(
            service: AuroraNativeProvisioningStore.reservationService,
            account: AuroraNativeProvisioningStore.reservationAccount(identifier: "recovery-slot")
        )
        let ledgerData = try XCTUnwrap(storedLedgerData)
        let ledger = try JSONDecoder().decode(AuroraNativeProvisioningReservationLedger.self, from: ledgerData)
        XCTAssertEqual(ledger.entries.map(\.spentHintKey), [first.spentHintKey, second.spentHintKey])
        XCTAssertFalse(ledgerData.contains(Data(repeating: 0xaa, count: 8)))
    }

    func testNativePacketTunnelCoreUsesFreshReservationAfterReconnect() async throws {
        let credentials = MockSecureCredentialStore()
        let first = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xb1, count: 64),
            spentHintKey: Data(repeating: 0x31, count: 48),
            relayBucketID: Data(repeating: 0x41, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let second = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xb2, count: 64),
            spentHintKey: Data(repeating: 0x32, count: 48),
            relayBucketID: Data(repeating: 0x41, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let reserver = MockNativeProvisioningReserver(reservations: [first, second])
        let store = AuroraNativeProvisioningStore(credentialStore: credentials, validator: MockNativeProvisioningValidator(), reserver: reserver)
        try await store.save(Data(repeating: 0xbb, count: 128), identifier: "recovery-slot")
        let driver = MockNativeSessionDriver(
            work: AuroraNativeIssuerWork(
                handle: 51,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/51",
                requestBody: Data([0x01])
            ),
            ingressPackets: [],
            nextPacket: Data([0x60, 0x00, 0x00, 0x00])
        )
        let core = AuroraNativePacketTunnelCore(
            provisioningStore: store,
            sessionDriver: driver,
            issuerTransport: MockNativeIssuerTransport(response: Data([0xaa]))
        )
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            nativeProvisioningIdentifier: "recovery-slot"
        )

        try await core.connect(configuration: configuration)
        await core.close()
        try await core.connect(configuration: configuration)
        await core.close()

        let begunProvisionings = await driver.begunProvisionings
        let reservedSpentHintKeys = await reserver.reservedSpentHintKeys
        XCTAssertEqual(begunProvisionings, [first.provisioning, second.provisioning])
        XCTAssertEqual(reservedSpentHintKeys, [[], [first.spentHintKey]])
    }

    func testNativePacketTunnelCoreRejectsConcurrentConnectBeforeSecondCoreSession() async throws {
        let credentialStore = MockSecureCredentialStore()
        let first = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xc1, count: 64),
            spentHintKey: Data(repeating: 0x41, count: 48),
            relayBucketID: Data(repeating: 0x51, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let second = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xc2, count: 64),
            spentHintKey: Data(repeating: 0x42, count: 48),
            relayBucketID: Data(repeating: 0x51, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator(),
            reserver: MockNativeProvisioningReserver(reservations: [first, second])
        )
        try await store.save(Data(repeating: 0xcc, count: 128), identifier: "concurrent-slot")
        let driver = BlockingNativeSessionDriver(works: [
            AuroraNativeIssuerWork(
                handle: 61,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/61",
                requestBody: Data([0x01])
            ),
            AuroraNativeIssuerWork(
                handle: 62,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/62",
                requestBody: Data([0x02])
            ),
        ])
        let core = AuroraNativePacketTunnelCore(
            provisioningStore: store,
            sessionDriver: driver,
            issuerTransport: MockNativeIssuerTransport(response: Data([0xaa]))
        )
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            nativeProvisioningIdentifier: "concurrent-slot"
        )

        let firstConnect = Task { try await core.connect(configuration: configuration) }
        for _ in 0..<20 {
            if await driver.hasPendingFirstBegin {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let hasPendingFirstBegin = await driver.hasPendingFirstBegin
        XCTAssertTrue(hasPendingFirstBegin)

        let secondResult = await Task { () -> Result<Void, any Error> in
            do {
                try await core.connect(configuration: configuration)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        await driver.resumeFirstBegin()
        try await firstConnect.value
        await core.close()

        switch secondResult {
        case .success:
            XCTFail("concurrent native tunnel connection unexpectedly succeeded")
        case let .failure(error):
            XCTAssertEqual(error as? AuroraNativeTunnelError, .invalidProvisioning)
        }
        let beginCount = await driver.beginCount
        let completedHandles = await driver.completedHandles
        let closedHandles = await driver.closedHandles
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(completedHandles, [61])
        XCTAssertEqual(closedHandles, [61])
    }

    func testNativePacketTunnelCoreCleansDelayedCoreHandleAfterConnectCancellation() async throws {
        let credentialStore = MockSecureCredentialStore()
        let reservation = AuroraNativeProvisioningReservation(
            provisioning: Data(repeating: 0xd1, count: 64),
            spentHintKey: Data(repeating: 0x43, count: 48),
            relayBucketID: Data(repeating: 0x53, count: 16),
            accessHintExpiryUnix: UInt64(Date().addingTimeInterval(3_600).timeIntervalSince1970)
        )
        let store = AuroraNativeProvisioningStore(
            credentialStore: credentialStore,
            validator: MockNativeProvisioningValidator(),
            reserver: MockNativeProvisioningReserver(reservations: [reservation])
        )
        try await store.save(Data(repeating: 0xdd, count: 128), identifier: "cancelled-slot")
        let driver = BlockingNativeSessionDriver(works: [
            AuroraNativeIssuerWork(
                handle: 71,
                issuerURL: URL(string: "https://issuer.example")!,
                issuerCarrierPath: "/assets/issue/71",
                requestBody: Data([0x03])
            ),
        ])
        let core = AuroraNativePacketTunnelCore(
            provisioningStore: store,
            sessionDriver: driver,
            issuerTransport: MockNativeIssuerTransport(response: Data([0xbb]))
        )
        let configuration = AuroraConfiguration(
            endpoint: URL(string: "https://relay.example:9443")!,
            nativeProvisioningIdentifier: "cancelled-slot"
        )

        let connect = Task { try await core.connect(configuration: configuration) }
        for _ in 0..<20 {
            if await driver.hasPendingFirstBegin {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let hasPendingFirstBegin = await driver.hasPendingFirstBegin
        XCTAssertTrue(hasPendingFirstBegin)

        connect.cancel()
        await driver.resumeFirstBegin()
        let result = await connect.result
        await core.close()

        switch result {
        case .success:
            XCTFail("cancelled native tunnel connection unexpectedly succeeded")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError)
        }
        let completedHandles = await driver.completedHandles
        let closedHandles = await driver.closedHandles
        XCTAssertTrue(completedHandles.isEmpty)
        XCTAssertEqual(closedHandles, [71])
    }

    func testNativeIssuerRedirectDelegateRejectsRedirects() {
        let sourceURL = URL(string: "https://issuer.example/assets/issue/41")!
        let redirectedURL = URL(string: "https://redirect.example/assets/issue/41")!
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: sourceURL)
        let response = HTTPURLResponse(
            url: sourceURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": redirectedURL.absoluteString]
        )!
        let decision = NativeIssuerRedirectDecision()

        AuroraNoRedirectSessionDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            decision.set(request)
        }

        XCTAssertNil(decision.value)
    }

    func testNativeIssuerTransportRejectsOversizedResponseBeforeCoreCompletion() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssuerURLProtocol.self]
        let transport = URLSessionAuroraNativeIssuerTransport(configuration: configuration)
        IssuerURLProtocol.setResponses([
            IssuerURLProtocol.Response(
                path: "/assets/issue/41",
                contentType: "application/octet-stream",
                body: Data(repeating: 0xa1, count: (1 << 20) + 1)
            ),
        ])

        do {
            _ = try await transport.postIssuerWork(
                url: URL(string: "https://issuer.example/assets/issue/41")!,
                body: Data([0x01, 0x02, 0x03])
            )
            XCTFail("oversized native issuer response unexpectedly succeeded")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testNativeIssuerTransportRejectsNonBinaryContentType() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IssuerURLProtocol.self]
        let transport = URLSessionAuroraNativeIssuerTransport(configuration: configuration)
        IssuerURLProtocol.setResponses([
            IssuerURLProtocol.Response(
                path: "/assets/issue/42",
                contentType: "text/html",
                body: Data([0x50, 0x60])
            ),
        ])

        do {
            _ = try await transport.postIssuerWork(
                url: URL(string: "https://issuer.example/assets/issue/42")!,
                body: Data([0x01, 0x02, 0x03])
            )
            XCTFail("non-binary native issuer response unexpectedly succeeded")
        } catch {
            XCTAssertNotNil(error)
        }
    }

}
