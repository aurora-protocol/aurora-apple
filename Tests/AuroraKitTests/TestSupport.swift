import Foundation
import XCTest
@testable import AuroraKit

struct WorkflowSecurityPolicy {
    let actionReferences: [String]
    let contentsPermission: String?
    let checkoutDisablesCredentialPersistence: [Bool]
}

func workflowSecurityPolicy(at workflowURL: URL) throws -> WorkflowSecurityPolicy {
    let rubyURL = URL(fileURLWithPath: "/usr/bin/ruby")
    guard FileManager.default.isExecutableFile(atPath: rubyURL.path) else {
        throw NSError(domain: "AuroraKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ruby YAML parser is unavailable"])
    }

    let script = #"""
    require "json"
    require "yaml"

    def collect_workflow_policy(value, references, checkout_credential_persistence)
      case value
      when Hash
        uses = value["uses"]
        if uses.is_a?(String)
          references << uses
          if uses.start_with?("actions/checkout@")
            checkout_credential_persistence << (value.dig("with", "persist-credentials") == false)
          end
        end
        value.each_value { |child| collect_workflow_policy(child, references, checkout_credential_persistence) }
      when Array
        value.each { |child| collect_workflow_policy(child, references, checkout_credential_persistence) }
      end
    end

    workflow = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false)
    references = []
    checkout_credential_persistence = []
    collect_workflow_policy(workflow, references, checkout_credential_persistence)
    contents_permission = workflow.dig("permissions", "contents") if workflow.is_a?(Hash)
    STDOUT.write(JSON.generate({
      "actionReferences" => references,
      "contentsPermission" => contents_permission,
      "checkoutDisablesCredentialPersistence" => checkout_credential_persistence,
    }))
    """#
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = rubyURL
    process.arguments = ["-e", script, workflowURL.path]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let message = String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "AuroraKitTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let actionReferences = decoded["actionReferences"] as? [String],
        let checkoutDisablesCredentialPersistence = decoded["checkoutDisablesCredentialPersistence"] as? [Bool]
    else {
        throw NSError(domain: "AuroraKitTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ruby YAML parser returned an invalid workflow policy"])
    }

    return WorkflowSecurityPolicy(
        actionReferences: actionReferences,
        contentsPermission: decoded["contentsPermission"] as? String,
        checkoutDisablesCredentialPersistence: checkoutDisablesCredentialPersistence
    )
}

final class MockPortableProfileStore: AuroraPortableProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profileText: String?

    init(initialProfileText: String? = nil) {
        profileText = initialProfileText
    }

    var savedProfileText: String? {
        lock.lock()
        defer { lock.unlock() }
        return profileText
    }

    func loadPortableProfile() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return profileText
    }

    func savePortableProfile(_ profileText: String) throws {
        lock.lock()
        defer { lock.unlock() }
        self.profileText = profileText
    }
}

struct MockServerClient: AuroraServerClient {
    var status: AuroraServerStatus

    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        status
    }
}

struct FailingServerClient: AuroraServerClient {
    func fetchStatus(endpoint: URL) async throws -> AuroraServerStatus {
        throw AuroraClientError.unavailable
    }
}

actor MockIssuerClient: AuroraIssuerClient {
    private let issuedToken: AuroraIssuedAdmissionToken?
    private let error: (any Error)?
    private let spentKey: Data
    private(set) var requestedEndpoint: URL?
    private(set) var requestedIssue: AuroraBlindRSAIssueRequest?
    private(set) var requestedSpendEndpoint: URL?
    private(set) var spentAdmissionProofs: [Data] = []

    init(issuedToken: AuroraIssuedAdmissionToken, spentKey: Data = Data(repeating: 0x7b, count: 48)) {
        self.issuedToken = issuedToken
        self.spentKey = spentKey
        self.error = nil
    }

    init(error: any Error) {
        self.issuedToken = nil
        self.spentKey = Data(repeating: 0x7b, count: 48)
        self.error = error
    }

    func fetchIssuerMetadata(endpoint: URL) async throws -> AuroraIssuerMetadataEnvelope {
        AuroraIssuerMetadataEnvelope(
            issuerMetadata: Data(repeating: 0x45, count: 32),
            issuerMetadataHash: Data(repeating: 0x46, count: 48)
        )
    }

    func issueBlindRSAAdmissionToken(endpoint: URL, request: AuroraBlindRSAIssueRequest) async throws -> AuroraIssuedAdmissionToken {
        requestedEndpoint = endpoint
        requestedIssue = request
        if let error {
            throw error
        }
        return issuedToken ?? AuroraIssuedAdmissionToken(
            admissionProof: Data(),
            relayBucketID: Data(repeating: 0x81, count: 16),
            tokenAuthenticator: Data(),
            expiryUnix: request.expiryUnix
        )
    }

    func spendAdmissionToken(endpoint: URL, admissionProof: Data) async throws -> Data {
        requestedSpendEndpoint = endpoint
        spentAdmissionProofs.append(admissionProof)
        if let error {
            throw error
        }
        return spentKey
    }
}

actor MockSecureCredentialStore: AuroraSecureCredentialStore {
    struct Key: Hashable {
        var service: String
        var account: String
    }

    private var entries: [Key: Data] = [:]
    private(set) var lastSave: Key?
    private(set) var deletedKeys: [Key] = []

    func save(_ data: Data, service: String, account: String) async throws {
        let key = Key(service: service, account: account)
        entries[key] = data
        lastSave = key
    }

    func load(service: String, account: String) async throws -> Data? {
        entries[Key(service: service, account: account)]
    }

    func delete(service: String, account: String) async throws {
        let key = Key(service: service, account: account)
        entries.removeValue(forKey: key)
        deletedKeys.append(key)
    }

    func savedData(service: String, account: String) -> Data? {
        entries[Key(service: service, account: account)]
    }
}

struct MockNativeProvisioningValidator: AuroraNativeProvisioningValidator {
    func validate(source: Data, now: Date) async throws {}
}

actor MockNativeProvisioningReserver: AuroraNativeProvisioningReserver {
    private var reservations: [AuroraNativeProvisioningReservation]
    private(set) var reservedSpentHintKeys: [[Data]] = []

    init(reservations: [AuroraNativeProvisioningReservation]) {
        self.reservations = reservations
    }

    func reserve(
        source: Data,
        spentHintKeys: [Data],
        now: Date
    ) async throws -> AuroraNativeProvisioningReservation {
        guard !source.isEmpty, now.timeIntervalSince1970 > 0, !reservations.isEmpty else {
            throw AuroraNativeTunnelError.invalidProvisioning
        }
        reservedSpentHintKeys.append(spentHintKeys)
        return reservations.removeFirst()
    }
}

final class IssuerURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var path: String
        var contentType: String
        var body: Data
    }

    struct RecordedRequest: Sendable {
        var request: URLRequest
        var body: Data?
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [Response] = []
        private var requests: [RecordedRequest] = []

        func setResponses(_ responses: [Response]) {
            lock.lock()
            defer { lock.unlock() }
            self.responses = responses
            requests = []
        }

        func record(request: URLRequest, body: Data?) -> Response {
            lock.lock()
            defer { lock.unlock() }
            requests.append(RecordedRequest(request: request, body: body))
            if !responses.isEmpty {
                return responses.removeFirst()
            }
            return Response(path: request.url?.path ?? "", contentType: "application/json", body: Data())
        }

        func recordedRequests() -> [RecordedRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private static let state = State()

    static var recordedRequests: [RecordedRequest] {
        state.recordedRequests()
    }

    static func setResponses(_ responses: [Response]) {
        state.setResponses(responses)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? PacketExchangeURLProtocol.readBodyStream(request.httpBodyStream)
        let configured = Self.state.record(request: request, body: body)
        let statusCode = request.url?.path == configured.path ? 200 : 404
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": configured.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: configured.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class NativeIssuerRedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }

    var value: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

actor MockPacketExchangeClient: AuroraPacketExchangeClient {
    private let outboundBatch: AuroraPacketFlowBatch?
    private let error: (any Error)?
    private(set) var requestedEndpoint: URL?
    private(set) var requestedBatch: AuroraPacketFlowBatch?

    init(outboundBatch: AuroraPacketFlowBatch) {
        self.outboundBatch = outboundBatch
        self.error = nil
    }

    init(error: any Error) {
        self.outboundBatch = nil
        self.error = error
    }

    func exchangePacketBatch(endpoint: URL, batch: AuroraPacketFlowBatch) async throws -> AuroraPacketFlowBatch {
        requestedEndpoint = endpoint
        requestedBatch = batch
        if let error {
            throw error
        }
        return outboundBatch ?? AuroraPacketFlowBatch(packets: [], protocolNumbers: [])
    }
}

actor MockNativeSessionDriver: AuroraNativeSessionDriver {
    private let work: AuroraNativeIssuerWork
    private let responses: [Data]
    private let remotePacket: Data
    private(set) var beginProvisioning: Data?
    private(set) var begunProvisionings: [Data] = []
    private(set) var completedHandle: UInt64?
    private(set) var completedResponse: Data?
    private(set) var ingressPackets: [Data] = []
    private(set) var closedHandles: [UInt64] = []

    init(work: AuroraNativeIssuerWork, ingressPackets: [Data], nextPacket: Data) {
        self.work = work
        responses = ingressPackets
        remotePacket = nextPacket
    }

    func begin(provisioning: Data) async throws -> AuroraNativeIssuerWork {
        beginProvisioning = provisioning
        begunProvisionings.append(provisioning)
        return work
    }

    func complete(handle: UInt64, issuerResponse: Data) async throws {
        completedHandle = handle
        completedResponse = issuerResponse
    }

    func ingress(handle: UInt64, packet: Data) async throws -> [Data] {
        guard handle == work.handle else {
            throw AuroraNativeTunnelError.coreOperationFailed
        }
        ingressPackets.append(packet)
        return responses
    }

    func nextLocalPacket(handle: UInt64) async throws -> Data {
        guard handle == work.handle else {
            throw AuroraNativeTunnelError.coreOperationFailed
        }
        return remotePacket
    }

    func close(handle: UInt64) async {
        closedHandles.append(handle)
    }
}

actor BlockingNativeSessionDriver: AuroraNativeSessionDriver {
    private let works: [AuroraNativeIssuerWork]
    private var firstBeginContinuation: CheckedContinuation<Void, Never>?
    private(set) var beginCount = 0
    private(set) var completedHandles: [UInt64] = []
    private(set) var closedHandles: [UInt64] = []

    init(works: [AuroraNativeIssuerWork]) {
        self.works = works
    }

    var hasPendingFirstBegin: Bool {
        firstBeginContinuation != nil
    }

    func begin(provisioning: Data) async throws -> AuroraNativeIssuerWork {
        let index = beginCount
        beginCount += 1
        guard works.indices.contains(index) else {
            throw AuroraNativeTunnelError.coreOperationFailed
        }
        if index == 0 {
            await withCheckedContinuation { continuation in
                firstBeginContinuation = continuation
            }
        }
        return works[index]
    }

    func complete(handle: UInt64, issuerResponse: Data) async throws {
        completedHandles.append(handle)
    }

    func ingress(handle: UInt64, packet: Data) async throws -> [Data] {
        throw AuroraNativeTunnelError.coreOperationFailed
    }

    func nextLocalPacket(handle: UInt64) async throws -> Data {
        throw AuroraNativeTunnelError.coreOperationFailed
    }

    func close(handle: UInt64) async {
        closedHandles.append(handle)
    }

    func resumeFirstBegin() {
        firstBeginContinuation?.resume()
        firstBeginContinuation = nil
    }
}

actor MockNativeIssuerTransport: AuroraNativeIssuerTransport {
    private let response: Data
    private(set) var requestedURL: URL?
    private(set) var requestedBody: Data?

    init(response: Data) {
        self.response = response
    }

    func postIssuerWork(url: URL, body: Data) async throws -> Data {
        requestedURL = url
        requestedBody = body
        return response
    }
}

actor AsyncCompletionSignal {
    private var signaled = false

    func signal() {
        signaled = true
    }

    var isSignaled: Bool {
        signaled
    }
}

final class OversizedPacketResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let maximumPacketBatchResponseBytes = 64 * (2 + 4 + 65_535) + 2

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(Self.maximumPacketBatchResponseBytes + 1)",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {}
}

final class OversizedIssuerResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let maximumIssuerResponseBytes = 1 << 20

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(Self.maximumIssuerResponseBytes + 1)",
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {}
}

final class PacketExchangeURLProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var response = Data()
        var contentType = "application/octet-stream"
        var lastRequest: URLRequest?
        var lastBody: Data?

        func setResponse(_ data: Data, contentType: String) {
            lock.lock()
            defer { lock.unlock() }
            response = data
            self.contentType = contentType
            lastRequest = nil
            lastBody = nil
        }

        func record(request: URLRequest, body: Data?) -> (body: Data, contentType: String) {
            lock.lock()
            defer { lock.unlock() }
            lastRequest = request
            lastBody = body
            return (response, contentType)
        }

        func request() -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return lastRequest
        }

        func body() -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lastBody
        }
    }

    private static let state = State()

    static var lastRequest: URLRequest? {
        state.request()
    }

    static var lastBody: Data? {
        state.body()
    }

    static func setResponse(_ data: Data, contentType: String = "application/octet-stream") {
        state.setResponse(data, contentType: contentType)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let configured = Self.state.record(request: request, body: body)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": configured.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: configured.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    fileprivate static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

// Builds cover-carrier server responses ([type][payload]) the way the portable
// core encodes them, so the transport tests can exercise the real carrier codec.
enum CarrierFixture {
    static func metadataResponse(metadata: Data, hash: Data) -> Data {
        var out = Data([0x03])
        let len = UInt32(metadata.count)
        out.append(UInt8((len >> 24) & 0xff))
        out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 8) & 0xff))
        out.append(UInt8(len & 0xff))
        out.append(metadata)
        out.append(hash)
        return out
    }

    static func issueResponse(_ admissionProof: Data) -> Data {
        Data([0x05]) + admissionProof
    }

    static func spendResponse(_ spentKey: Data) -> Data {
        Data([0x07]) + spentKey
    }
}

func makeAdmissionProof(
    relayBucketID: Data,
    tokenAuthenticator: Data,
    expiryUnix: UInt64,
    issuerMetadataHash: Data = Data(repeating: 0x46, count: 48)
) -> Data {
    var proof = Data()
    let tokenKeyID = Data(repeating: 0x22, count: 32)
    proof.appendVarint(0x000200)
    proof.appendVarint(0x0002)
    proof.append(Data(repeating: 0x11, count: 16))
    proof.append(tokenKeyID)
    proof.append(relayBucketID)
    proof.append(Data(repeating: 0x33, count: 16))
    proof.appendUInt64(expiryUnix)
    proof.append(Data(repeating: 0x44, count: 32))
    proof.append(Data(repeating: 0x55, count: 48))
    proof.appendOpaque16(makeTokenMetadata(tokenKeyID: tokenKeyID, issuerMetadataHash: issuerMetadataHash))
    proof.appendOpaque16(tokenAuthenticator)
    proof.appendOpaque16(Data())
    proof.appendVarint(0)
    return proof
}

func makeTokenMetadata(tokenKeyID: Data, issuerMetadataHash: Data) -> Data {
    var metadata = Data()
    metadata.appendUInt16(0x0002)
    metadata.append(Data(repeating: 0x66, count: 32))
    metadata.append(tokenKeyID)
    metadata.appendOpaque16(Data("issuer".utf8))
    metadata.appendOpaque16(Data("origin".utf8))
    metadata.append(issuerMetadataHash)
    return metadata
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64(_ value: UInt64) {
        append(UInt8((value >> 56) & 0xff))
        append(UInt8((value >> 48) & 0xff))
        append(UInt8((value >> 40) & 0xff))
        append(UInt8((value >> 32) & 0xff))
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendOpaque16(_ value: Data) {
        append(UInt8((value.count >> 8) & 0xff))
        append(UInt8(value.count & 0xff))
        append(value)
    }

    mutating func appendVarint(_ value: UInt64) {
        switch value {
        case 0...63:
            append(UInt8(value))
        case 64...16_383:
            let encoded = UInt16(value) | 0x4000
            append(UInt8((encoded >> 8) & 0xff))
            append(UInt8(encoded & 0xff))
        case 16_384...1_073_741_823:
            let encoded = UInt32(value) | 0x8000_0000
            append(UInt8((encoded >> 24) & 0xff))
            append(UInt8((encoded >> 16) & 0xff))
            append(UInt8((encoded >> 8) & 0xff))
            append(UInt8(encoded & 0xff))
        default:
            let encoded = value | 0xc000_0000_0000_0000
            appendUInt64(encoded)
        }
    }
}
