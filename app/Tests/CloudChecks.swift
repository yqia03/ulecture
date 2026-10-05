import Foundation
import Security

// Contract checks install a URLProtocol for every request. No external network
// transport, real credentials, microphone, speech synthesis or playback is used.
final class IsolatedCredentials: CloudCredentialStore {
    var values: [String: String] = [:]
    var reads = 0
    func save(_ value: String, reference: String) throws { values[reference] = value }
    func read(reference: String) throws -> String? { reads += 1; return values[reference] }
    func remove(reference: String) throws { values[reference] = nil }
}
final class CloudBoundaryFixture: URLProtocol {
    struct Reply { var status = 200; var headers: [String: String] = [:]; var data: Data; var delay: TimeInterval = 0 }
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var activeRequests = 0
    static var maximumActive = 0
    static var handler: ((URLRequest, Int) throws -> Reply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var captured = request
            if captured.httpBody == nil, let stream = captured.httpBodyStream {
                stream.open(); defer { stream.close() }; var body = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
                captured.httpBody = body
            }
            Self.lock.lock(); Self.requests.append(captured); Self.activeRequests += 1; Self.maximumActive = max(Self.maximumActive, Self.activeRequests); let n = Self.requests.count; let handler = Self.handler; Self.lock.unlock()
            let reply = try handler!(captured, n)
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [self] in
                Self.lock.lock(); Self.activeRequests -= 1; Self.lock.unlock()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch { Self.lock.lock(); Self.activeRequests -= 1; Self.lock.unlock(); client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
    static func reset(_ handler: @escaping (URLRequest, Int) throws -> Reply) { lock.lock(); requests = []; activeRequests = 0; maximumActive = 0; self.handler = handler; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

@main struct CloudChecks {
    @MainActor static func main() async throws {
        var checks: [String] = []
        func check(_ predicate: @autoclosure () -> Bool, _ name: String) throws {
            guard predicate() else { throw NSError(domain: "CloudChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            checks.append(name)
        }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [CloudBoundaryFixture.self]
        let network = URLSession(configuration: cfg)
        let adapter = CloudHTTPProvider(session: network)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("classroom-cloud-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let stateFile = temp.appendingPathComponent("cloud.json")
        let secret = "contract-test-secret-not-real-7e2e2d"
        func object(_ request: URLRequest) throws -> [String: Any] { try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any] }
        func input(_ request: URLRequest) throws -> [String: Any] {
            let body = try object(request)
            let text: String
            if request.url!.path == "/v1/responses" { text = body["input"] as! String }
            else if let messages = body["messages"] as? [[String: Any]] { text = messages.last!["content"] as! String }
            else { text = (((body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as! String) }
            return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        }
        func reply(_ request: URLRequest, _ content: [String: Any], usage: Bool = true, delay: Double = 0) throws -> CloudBoundaryFixture.Reply {
            let text = String(data: try JSONSerialization.data(withJSONObject: content), encoding: .utf8)!
            var envelope: [String: Any]
            if request.url!.path == "/v1/responses" {
                envelope = ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]]]
                if usage { envelope["usage"] = ["input_tokens": 20, "output_tokens": 10] }
            } else if request.url!.path.hasSuffix("/chat/completions") {
                envelope = ["choices": [["finish_reason": "stop", "message": ["content": text]]]]
                if usage { envelope["usage"] = ["prompt_tokens": 20, "completion_tokens": 10] }
            } else {
                envelope = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]]
                if usage { envelope["usageMetadata"] = ["promptTokenCount": 20, "candidatesTokenCount": 10] }
            }
            return CloudBoundaryFixture.Reply(data: try JSONSerialization.data(withJSONObject: envelope), delay: delay)
        }
        func segment(_ id: String, revision: Int = 1) -> CloudSegment {
            CloudSegment(id: id, classID: "class-test", revision: revision, text: "Working memory is not unlimited.", language: "en", startMS: 100, endMS: 2500, confirmedAt: Date())
        }
        func until(_ test: @escaping @MainActor () -> Bool, seconds: Double = 10) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !test() { if Date() > deadline { throw NSError(domain: "CloudChecks.timeout", code: 2, userInfo: [NSLocalizedDescriptionKey: "After: " + (checks.last ?? "setup")]) }; try await Task.sleep(nanoseconds: 20_000_000) }
        }
        for path in CloudProvider.allCases {
            let configuration = CloudConfiguration(provider: path, projectID: "project-test", location: "global", version: 4)
            let dispatch = CloudDispatch(version: 3, configuration: configuration, preset: .current(for: path), sentAt: Date())
            CloudBoundaryFixture.reset { request, _ in try reply(request, ["id": "s", "text": "工作记忆并非无限。"], usage: path != .googleCloudExpress) }
            let result = try await adapter.perform(dispatch: dispatch, credential: secret, instruction: "Return JSON", input: "text")
            let request = CloudBoundaryFixture.requests[0]
            try check(result.text.contains("工作记忆"), "\(path.rawValue) response decoded at HTTP boundary")
            try check(request.url?.query == nil && !(request.httpBody.map { String(decoding: $0, as: UTF8.self).contains(secret) } ?? true), "\(path.rawValue) secret only in auth header")
            if path == .googleCloudExpress { try check(result.usage.status == "unknown", "absent provider usage remains unknown") }
            if path == .googleCloudStandard { try check(request.url!.path.contains("projects/project-test/locations/global") && request.value(forHTTPHeaderField: "Authorization") != nil, "Standard requires project region bearer") }
            if path == .googleCloudExpress { try check(!request.url!.path.contains("projects") && request.value(forHTTPHeaderField: "x-goog-api-key") != nil, "Express global product distinct API key") }
        }
        // Native ephemeral RSA signing of an explicitly provided service account.
        // No key is persisted and the token endpoint is still URLProtocol-only.
        var keyError: Unmanaged<CFError>?
        let generator = Process(); generator.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); generator.arguments = ["genrsa", "2048"]
        let keyPipe = Pipe(); generator.standardOutput = keyPipe; generator.standardError = FileHandle.nullDevice
        try generator.run(); let generated = keyPipe.fileHandleForReading.readDataToEndOfFile(); generator.waitUntilExit()
        guard generator.terminationStatus == 0 else { throw CloudFailure.authentication }
        let generatedPEM = String(decoding: generated, as: UTF8.self)
        let rawKey = Data(base64Encoded: generatedPEM.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined())!
        guard let rsa = SecKeyCreateWithData(rawKey as CFData, [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPrivate] as CFDictionary, &keyError) else { throw keyError!.takeRetainedValue() as Error }
        func der(_ tag: UInt8, _ bytes: Data) -> Data {
            let length = bytes.count
            let prefix: [UInt8] = length < 128 ? [tag, UInt8(length)] : [tag, 0x82, UInt8(length >> 8), UInt8(length & 255)]
            return Data(prefix) + bytes
        }
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let pkcs8 = der(0x30, Data([0x02, 0x01, 0x00]) + algorithm + der(0x04, rawKey))
        let pem = "-----BEGIN PRIVATE KEY-----\n" + pkcs8.base64EncodedString() + "\n-----END PRIVATE KEY-----"
        let serviceAccount = String(data: try JSONSerialization.data(withJSONObject: ["type": "service_account", "client_email": "test@fixture.iam.gserviceaccount.com", "private_key": pem, "token_uri": "https://oauth2.googleapis.com/token"]), encoding: .utf8)!
        CloudBoundaryFixture.reset { request, _ in
            guard request.url!.host == "oauth2.googleapis.com" else { return try reply(request, ["id": "s", "text": "令牌验证"]) }
            let fields = URLComponents(string: "https://fixture.invalid/?" + String(decoding: request.httpBody!, as: UTF8.self))!.queryItems!
            let jwt = fields.first { $0.name == "assertion" }!.value!
            let pieces = jwt.components(separatedBy: ".")
            var signatureText = pieces[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            signatureText += String(repeating: "=", count: (4 - signatureText.count % 4) % 4)
            let signature = Data(base64Encoded: signatureText)!
            let message = Data((pieces[0] + "." + pieces[1]).utf8)
            guard SecKeyVerifySignature(SecKeyCopyPublicKey(rsa)!, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil) else { throw CloudFailure.authentication }
            return CloudBoundaryFixture.Reply(data: Data("{\"access_token\":\"fixture-token\",\"expires_in\":3600}".utf8))
        }
        let standard = CloudDispatch(version: 1, configuration: CloudConfiguration(provider: .googleCloudStandard, projectID: "project-test"), preset: .current(for: .googleCloudStandard), sentAt: Date())
        _ = try await adapter.perform(dispatch: standard, credential: serviceAccount, instruction: "Return JSON", input: "test")
        _ = try await adapter.perform(dispatch: standard, credential: serviceAccount, instruction: "Return JSON", input: "test")
        try check(CloudBoundaryFixture.requests.filter { $0.url!.host == "oauth2.googleapis.com" }.count == 1 && CloudBoundaryFixture.requests.last!.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token", "Standard PKCS8 RSA JWT signature verified; bounded token reuse; no ADC")
        var blockedJSON = try JSONSerialization.jsonObject(with: Data(serviceAccount.utf8)) as! [String: Any]
        blockedJSON["token_uri"] = "https://fixture.invalid/steal"
        let malicious = String(data: try JSONSerialization.data(withJSONObject: blockedJSON), encoding: .utf8)!
        let beforeBlocked = CloudBoundaryFixture.count
        do { _ = try await adapter.perform(dispatch: standard, credential: malicious, instruction: "JSON", input: "test"); throw CloudFailure.malformedResponse } catch CloudFailure.invalidConfiguration { }
        try check(CloudBoundaryFixture.count == beforeBlocked, "untrusted credential token_uri cannot redirect secrets")
        CloudBoundaryFixture.reset { request, _ in try reply(request, ["id": "s", "text": "并发边界"], delay: 0.04) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<9 { group.addTask { _ = try await adapter.perform(dispatch: standard, credential: "fixture-access", instruction: "JSON", input: "test") } }
            try await group.waitForAll()
        }
        try check(CloudBoundaryFixture.count == 9 && CloudBoundaryFixture.maximumActive <= 3, "all classrooms summaries and token exchanges share process-wide max three cloud operations")
        let reviewDue = CloudModelPreset(model: "active", version: "old", reviewedOn: "2020-01-01", reviewBefore: "2020-01-02", accountVerified: false)
        try check(reviewDue.reviewDue && !reviewDue.isExpired, "maintenance review date is not a provider shutdown date")
        let expired = CloudDispatch(version: 1, configuration: standard.configuration, preset: CloudModelPreset(model: "retired", version: "old", reviewedOn: "2020-01-01", reviewBefore: "2020-01-02", accountVerified: false, retiredOn: "2020-01-03"), sentAt: Date())
        let beforeExpired = CloudBoundaryFixture.count
        do { _ = try await adapter.perform(dispatch: expired, credential: serviceAccount, instruction: "JSON", input: "test"); throw CloudFailure.malformedResponse } catch CloudFailure.expiredPreset { }
        try check(CloudBoundaryFixture.count == beforeExpired, "expired preset fails before token or model request")
        let connectionCheck = CloudController(state: CloudState(classID: "settings"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: IsolatedCredentials(), monitorNetwork: false)
        var savedConnectionState: CloudState?
        connectionCheck.onPersist = { savedConnectionState = $0 }
        try await connectionCheck.saveCredential(secret)
        CloudBoundaryFixture.reset { _, _ in CloudBoundaryFixture.Reply(status: 401, data: Data()) }
        await connectionCheck.testConnection()
        try check(savedConnectionState?.usage.count == 1 && savedConnectionState?.usage[0].status == "unknown" && connectionCheck.lastError == .authentication, "failed explicit connection test persists unknown usage without a fabricated zero charge")
        CloudBoundaryFixture.reset { request, _ in try reply(request, ["ok": true]) }
        await connectionCheck.testConnection()
        try check(savedConnectionState?.usage.count == 2 && connectionCheck.lastError == nil && savedConnectionState?.usage.last?.status == "providerReported", "successful connection retest records provider usage and clears preceding error")
        await connectionCheck.shutdown()
        let keyStore = IsolatedCredentials()
        let delayed = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        var delayedSaved: CloudState?
        delayed.onPersist = { snapshot in
            try await Task.sleep(nanoseconds: 100_000_000)
            delayedSaved = snapshot
        }
        let pendingSave = Task { try await delayed.enqueueSavedSegment(segment("async-durability"), targetLanguage: "zh-Hans") }
        try await Task.sleep(nanoseconds: 20_000_000)
        try check(delayedSaved == nil, "delayed persistence leaves the UI executor responsive without acknowledging the queued source")
        try await pendingSave.value
        try check(delayedSaved?.jobs.first?.segment.id == "async-durability", "enqueue awaits an actual durable persistence receipt")
        await delayed.shutdown()
        let receiptController = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        var heldReceipt: CheckedContinuation<Void, Never>?
        var holdCompletion = true, durableCompletions: [Int] = [], savedNotices: [Int] = []
        receiptController.onPersist = { value in
            if value.jobs.contains(where: { $0.status == .completed }), holdCompletion {
                await withCheckedContinuation { heldReceipt = $0 }
            }
            durableCompletions = value.jobs.filter { $0.status == .completed }.map { $0.segment.revision }
        }
        receiptController.onSavedTranslation = { savedNotices.append($0.sourceRevision) }
        await receiptController.setClassActive(true)
        try await receiptController.saveCredential(secret)
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "异步保存译文"]) }
        try await receiptController.enqueueSavedSegment(segment("receipt-revision", revision: 1), targetLanguage: "zh-Hans")
        try await until { heldReceipt != nil }
        try check(receiptController.state.jobs.first?.status == .saving && receiptController.completedCount == 0 && receiptController.hasPendingPersistence && savedNotices.isEmpty && durableCompletions.isEmpty, "received translation remains saving and emits no saved callback before the delayed receipt")
        var drainReturned = false
        let drainReceipt = Task { let result = await receiptController.waitForPersistence(); drainReturned = true; return result }
        await Task.yield()
        try check(!drainReturned, "lifecycle persistence drain waits for a held receipt without cancelling the response")
        let revisionTask = Task { try await receiptController.enqueueSavedSegment(segment("receipt-revision", revision: 2), targetLanguage: "zh-Hans") }
        await Task.yield()
        holdCompletion = false; heldReceipt?.resume(); heldReceipt = nil
        try await revisionTask.value
        let drainSucceeded = await drainReceipt.value
        try check(drainSucceeded, "lifecycle drain returns the actual successful disk outcome")
        try await until { receiptController.completedCount == 1 && !receiptController.hasPendingPersistence }
        try check(savedNotices == [2] && durableCompletions == [2], "older completion receipt cannot notify or overwrite a newer source revision admitted while saving")
        await receiptController.shutdown()

        let dispatchGate = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        var heldDispatch: CheckedContinuation<Void, Never>?, holdDispatch = true
        dispatchGate.onPersist = { value in
            if holdDispatch, value.jobs.contains(where: { $0.status == .running }) { await withCheckedContinuation { heldDispatch = $0 } }
        }
        try await dispatchGate.saveCredential(secret)
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "暂停边界"]) }
        let dispatchTask = Task { try await dispatchGate.enqueueSavedSegment(segment("pause-during-save"), targetLanguage: "zh-Hans") }
        try await until { heldDispatch != nil }
        let pauseTask = Task { await dispatchGate.setUserPaused(true) }
        await Task.yield()
        holdDispatch = false; heldDispatch?.resume(); heldDispatch = nil
        try await dispatchTask.value; await pauseTask.value
        try check(CloudBoundaryFixture.count == 0 && dispatchGate.state.translationUserPaused && dispatchGate.state.jobs.first?.status == .queued, "pause during a suspended dispatch checkpoint prevents a later network request and restores the unsent job")
        await dispatchGate.shutdown()
        let exiting = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        var exitReceipt: CheckedContinuation<Void, Never>?, holdExit = true, exitWrites = 0
        exiting.credentialResolver = { _ in secret }
        exiting.onPersist = { value in
            if holdExit, value.jobs.contains(where: { $0.status == .running }) { await withCheckedContinuation { exitReceipt = $0 } }
            exitWrites += 1
        }
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "退出边界"]) }
        let exitEnqueue = Task { try await exiting.enqueueSavedSegment(segment("exit-during-save"), targetLanguage: "zh-Hans") }
        try await until { exitReceipt != nil }
        await exiting.pump() // Request a deferred pump while the durable checkpoint is suspended.
        let exitTask = Task { await exiting.shutdown() }
        await Task.yield()
        holdExit = false; exitReceipt?.resume(); exitReceipt = nil
        try await exitEnqueue.value; await exitTask.value
        let writesAtExit = exitWrites
        try await Task.sleep(nanoseconds: 50_000_000)
        try await exiting.enqueueSavedSegment(segment("saved-after-exit"), targetLanguage: "zh-Hans")
        try check(CloudBoundaryFixture.count == 0 && !exiting.hasPendingPersistence && exiting.state.jobs.first?.status == .needsAttention && exitWrites == writesAtExit + 1, "shutdown drains receipts and inhibits deferred or new automatic dispatch while retaining later saved facts")
        await exiting.setUserPaused(false)
        try await until { exiting.completedCount == 1 }
        try check(CloudBoundaryFixture.count == 1, "an explicit resume after a cancelled exit can reactivate the same controller")
        await exiting.shutdown()

        let failedQueue = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        var failedGate: CheckedContinuation<Void, Never>?, rejectQueue = true, acceptedRevisions: [Int] = []
        failedQueue.onPersist = { value in
            if rejectQueue { await withCheckedContinuation { failedGate = $0 }; throw CocoaError(.fileWriteNoPermission) }
            acceptedRevisions.append(value.jobs.last!.segment.revision)
        }
        CloudBoundaryFixture.reset { _, _ in throw URLError(.unsupportedURL) }
        let firstFailedSave = Task { try await failedQueue.enqueueSavedSegment(segment("ordered-failure", revision: 1), targetLanguage: "zh-Hans") }
        try await until { failedGate != nil }
        let secondFailedSave = Task { try await failedQueue.enqueueSavedSegment(segment("ordered-failure", revision: 2), targetLanguage: "zh-Hans") }
        await Task.yield(); failedGate?.resume(); failedGate = nil
        for operation in [firstFailedSave, secondFailedSave] {
            do { try await operation.value; throw CloudFailure.malformedResponse } catch CloudFailure.persistence { }
        }
        try check(failedQueue.hasPendingPersistence && acceptedRevisions.isEmpty && CloudBoundaryFixture.count == 0 && failedQueue.state.jobs.last?.segment.revision == 2, "a failed suspended snapshot blocks queued newer snapshots without losing their latest in-memory facts")
        rejectQueue = false; await failedQueue.resumeAfterPersistenceRepair()
        try check(!failedQueue.hasPendingPersistence && !acceptedRevisions.isEmpty && acceptedRevisions.allSatisfy { $0 == 2 }, "explicit repair commits the newest retained snapshot without replaying rejected older saves")
        await failedQueue.shutdown()

        var exhaustedState = CloudState(classID: "class-test")
        var exhaustedJob = CloudTranslationJob(segment: segment("exhausted-revision"), targetLanguage: "zh-Hans", status: .running)
        exhaustedJob.dispatchVersion = Int.max; exhaustedState.jobs = [exhaustedJob]
        let exhausted = CloudController(state: exhaustedState, configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        exhausted.onPersist = { _ in }; exhausted.credentialResolver = { _ in secret }
        CloudBoundaryFixture.reset { _, _ in throw URLError(.unsupportedURL) }
        await exhausted.retry(jobID: exhaustedJob.id)
        try check(exhausted.state.jobs[0].status == .needsAttention && exhausted.state.jobs[0].errorCode == "invalidConfiguration" && CloudBoundaryFixture.count == 0, "a restored exhausted dispatch counter remains readable and blocks unsafe reuse without overflow")
        await exhausted.shutdown()

        let cancelling = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        cancelling.credentialResolver = { _ in secret }
        var summaryReceipt: CheckedContinuation<Void, Never>?, holdSummary = true
        cancelling.onPersist = { value in
            if holdSummary, !value.summaries.isEmpty { await withCheckedContinuation { summaryReceipt = $0 } }
        }
        let cancelSnapshot = SummarySnapshot(classID: "class-test", sources: [SummarySource(kind: .pdf, entityID: "fictional", version: 1, text: "Fictional summary cancellation material", page: 1)], excluded: [])
        CloudBoundaryFixture.reset { _, _ in throw URLError(.unsupportedURL) }
        let summaryStart = Task { await cancelling.generateSummary(cancelSnapshot) }
        try await until { summaryReceipt != nil }
        let summaryCancel = Task { await cancelling.cancelSummary() }
        await Task.yield()
        holdSummary = false; summaryReceipt?.resume(); summaryReceipt = nil
        await summaryStart.value; await summaryCancel.value
        try check(CloudBoundaryFixture.count == 0 && !cancelling.summaryRunning && !cancelling.hasPendingPersistence && cancelling.state.summaries.first?.status == "cancelled", "summary cancellation during its initial durable checkpoint prevents a request and drains in order")
        await cancelling.shutdown()

        // Exercise the same queue banner binding used by the production view.
        func visibleQueueError(_ cloud: CloudController) -> String? { cloud.queueErrorCode }
        let errorRecovery = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: IsolatedCredentials(), monitorNetwork: false)
        errorRecovery.onPersist = { _ in }
        await errorRecovery.setClassActive(true)
        try await errorRecovery.saveCredential(secret)
        CloudBoundaryFixture.reset { request, count in
            let value = try input(request), id = value["id"] as! String
            if id == "temporary-service-error" && count == 1 { return CloudBoundaryFixture.Reply(status: 503, data: Data()) }
            if id == "other-failed-job" && count <= 2 { return CloudBoundaryFixture.Reply(status: 401, data: Data()) }
            return try reply(request, ["id": id, "text": "恢复后的译文"])
        }
        try await errorRecovery.enqueueSavedSegment(segment("temporary-service-error"), targetLanguage: "zh-Hans")
        try await until { errorRecovery.state.jobs.first?.status == .retryWaiting }
        try check(visibleQueueError(errorRecovery) == "unavailable", "queue shows the current retryable service failure")
        try await errorRecovery.enqueueSavedSegment(segment("other-failed-job"), targetLanguage: "zh-Hans")
        try await until { errorRecovery.state.jobs.last?.status == .needsAttention }
        try await until { errorRecovery.state.jobs.first?.status == .completed }
        try check(visibleQueueError(errorRecovery) == "authentication", "successful automatic retry removes its error without hiding another failed job")
        await errorRecovery.generateSummary(SummarySnapshot(classID: "class-test", sources: []))
        try check(visibleQueueError(errorRecovery) == "authentication", "summary preflight failure never replaces the translation queue error")
        try check(errorRecovery.summaryActionError == .noMaterials, "summary preflight failure remains available in the summary context")
        await errorRecovery.retry(jobID: errorRecovery.state.jobs.last!.id)
        try await until { errorRecovery.completedCount == 2 }
        try check(visibleQueueError(errorRecovery) == nil, "queue banner clears after all failed translations recover")
        try check(errorRecovery.summaryActionError == .noMaterials, "translation recovery does not clear an unrelated summary action error")
        await errorRecovery.shutdown()

        func visibleSummaryError(_ cloud: CloudController) -> CloudFailure? { cloud.summaryError }
        let finalSummarySave = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: IsolatedCredentials(), monitorNetwork: false)
        var allowFinalSummaryCommit = false
        finalSummarySave.onPersist = { state in
            if state.summaries.last?.status == "completed", !allowFinalSummaryCommit { throw CocoaError(.fileWriteNoPermission) }
        }
        try await finalSummarySave.saveCredential(secret)
        let summarySource = SummarySource(kind: .note, entityID: "fictional-note", version: 1, text: "The fictional course explains attention.")
        CloudBoundaryFixture.reset { request, _ in try reply(request, ["claims": [["text": "课程讨论注意力。", "referenceIDs": [summarySource.id]]]]) }
        await finalSummarySave.generateSummary(SummarySnapshot(classID: "class-test", sources: [summarySource]))
        try await until { !finalSummarySave.summaryRunning && finalSummarySave.hasPendingPersistence }
        _ = await finalSummarySave.waitForPersistence()
        try check(finalSummarySave.state.summaries.last?.status == "completed" && visibleSummaryError(finalSummarySave) == .persistence, "final summary commit failure remains visible despite a completed provider response")
        allowFinalSummaryCommit = true
        await finalSummarySave.resumeAfterPersistenceRepair()
        try check(visibleSummaryError(finalSummarySave) == nil && !finalSummarySave.hasPendingPersistence && CloudBoundaryFixture.count == 1, "summary storage repair clears the save warning without issuing a second request")
        await finalSummarySave.shutdown()

        let credentialRecovery = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: IsolatedCredentials(), monitorNetwork: false)
        credentialRecovery.onPersist = { _ in }
        credentialRecovery.credentialResolver = { _ in throw CloudFailure.authentication }
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "凭据恢复后的译文"]) }
        try await credentialRecovery.enqueueSavedSegment(segment("credential-repair"), targetLanguage: "zh-Hans")
        try check(credentialRecovery.queueErrorCode == "authentication", "queue credential resolution error remains visible before a job dispatch exists")
        credentialRecovery.credentialResolver = { _ in secret }
        await credentialRecovery.pump()
        try await until { credentialRecovery.completedCount == 1 }
        try check(credentialRecovery.queueErrorCode == nil, "successful credential repair clears its queue preflight error")
        await credentialRecovery.shutdown()

        let controller = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: keyStore, monitorNetwork: false)
        controller.onPersist = { try JSONEncoder().encode($0).write(to: stateFile, options: .atomic) }
        try check(keyStore.reads == 0 && !controller.credentialUnlocked && !controller.speech.enabled, "startup reads no Keychain and never enables speech")
        await controller.setClassActive(true)
        await controller.setUserPaused(true)
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "工作记忆并非无限。"], delay: 0.05) }
        try await controller.saveCredential(secret)
        try await controller.enqueueSavedSegment(segment("historical"), targetLanguage: "zh-Hans", historical: true)
        try await controller.enqueueSavedSegment(segment("new"), targetLanguage: "zh-Hans")
        await controller.setNetworkAvailable(false); await controller.setNetworkAvailable(true)
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(CloudBoundaryFixture.count == 0 && controller.state.translationUserPaused, "user pause survives network changes without any request")
        let reopenedState = try JSONDecoder().decode(CloudState.self, from: Data(contentsOf: stateFile))
        let reopened = CloudController(state: reopenedState, session: network, credentials: keyStore, monitorNetwork: false)
        try check(reopened.state.translationUserPaused && !reopened.speech.enabled && !reopened.credentialUnlocked, "pause and silent inert credential state survive reopening")
        // Re-prioritize with a genuinely fresh item after the historical outage.
        try await controller.enqueueSavedSegment(segment("new-after-network"), targetLanguage: "zh-Hans")
        await controller.setUserPaused(false)
        try await until { controller.completedCount == 3 }
        let firstIDs = try CloudBoundaryFixture.requests.prefix(2).compactMap { try input($0)["id"] as? String }
        try check(firstIDs.contains("new-after-network"), "new source receives first dispatch wave while history cannot occupy both slots")
        try check(controller.state.jobs.filter { $0.segment.id != "new-after-network" }.allSatisfy { $0.translation?.historical == true }, "historical output marked ineligible for speech")
        let countBefore = CloudBoundaryFixture.count
        try await controller.enqueueSavedSegment(segment("new-after-network"), targetLanguage: "zh-Hans")
        try check(CloudBoundaryFixture.count == countBefore && controller.state.jobs.count == 3, "repeated saved segment delivery is idempotent")
        let persistedText = try String(contentsOf: stateFile)
        try check(!persistedText.contains(secret), "persistent queue and result exclude test secret")
        // Old revision completes after a newer request. It is quarantined.
        CloudBoundaryFixture.reset { request, _ in
            let value = try input(request)
            return try reply(request, ["id": value["id"]!, "text": "修订译文"], delay: 0.12)
        }
        try await controller.enqueueSavedSegment(segment("revision", revision: 1), targetLanguage: "zh-Hans")
        try await until { CloudBoundaryFixture.count == 1 }
        try await controller.enqueueSavedSegment(segment("revision", revision: 2), targetLanguage: "zh-Hans")
        try await until { controller.state.isolatedLateResponses == 1 && controller.state.jobs.contains { $0.segment.id == "revision" && $0.segment.revision == 2 && $0.status == .completed } }
        try check(controller.state.jobs.filter { $0.segment.id == "revision" && $0.status == .completed }.count == 1, "late older revision cannot overwrite current result")
        let afterRevision = CloudBoundaryFixture.count
        try await controller.enqueueSavedSegment(segment("revision", revision: 1), targetLanguage: "zh-Hans")
        try check(CloudBoundaryFixture.count == afterRevision && controller.state.jobs.last!.segment.revision == 2, "out-of-order old revision does not obsolete newer source")
        // In-flight keeps its exact provider snapshot; only next dispatch changes.
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "保留快照"], delay: 0.1) }
        try await controller.enqueueSavedSegment(segment("old-provider"), targetLanguage: "zh-Hans")
        try await until { CloudBoundaryFixture.count == 1 }
        await controller.setUserPaused(true)
        await controller.configure(CloudConfiguration(provider: .geminiDeveloper, version: 2))
        try await controller.saveCredential(secret)
        try await controller.enqueueSavedSegment(segment("new-provider"), targetLanguage: "zh-Hans")
        try await until { controller.state.jobs.first { $0.segment.id == "old-provider" }?.status == .completed }
        try check(controller.state.jobs.first { $0.segment.id == "old-provider" }?.translation?.dispatch.configuration.provider == .openAI && CloudBoundaryFixture.count == 1, "service switch preserves in-flight snapshot and user pause")
        await controller.setUserPaused(false)
        try await until { controller.state.jobs.first { $0.segment.id == "new-provider" }?.status == .completed }
        try check(CloudBoundaryFixture.requests.last!.url!.host == "generativelanguage.googleapis.com", "next dispatch uses explicit new service")
        // Rate-limit retry is finite (2s + 4s, max 3 attempts) and no fallback.
        CloudBoundaryFixture.reset { _, _ in CloudBoundaryFixture.Reply(status: 429, headers: ["Retry-After": "0"], data: Data("{\"error\":{\"message\":\"secret echo must never escape\"}}".utf8)) }
        try await controller.enqueueSavedSegment(segment("limited"), targetLanguage: "zh-Hans")
        try await until { controller.state.jobs.first { $0.segment.id == "limited" }?.status == .needsAttention }
        try check(CloudBoundaryFixture.count == 3 && controller.state.jobs.first { $0.segment.id == "limited" }?.attempts == 3, "rate limits stop after three attempts")
        try check(controller.state.usage.filter { $0.status == "unknown" }.count >= 3, "failed dispatch usage remains unknown")
        CloudBoundaryFixture.reset { _, _ in CloudBoundaryFixture.Reply(status: 401, data: Data("credential echo".utf8)) }
        try await controller.enqueueSavedSegment(segment("bad-key"), targetLanguage: "zh-Hans")
        try await until { controller.state.jobs.first { $0.segment.id == "bad-key" }?.status == .needsAttention }
        try check(CloudBoundaryFixture.count == 1 && controller.lastError == .authentication, "authentication failure does not retry or expose response text")
        let beforeLock = CloudBoundaryFixture.count
        await controller.configure(controller.configuration)
        try check(!controller.credentialUnlocked && CloudBoundaryFixture.count == beforeLock, "reconfigure and credential removal invalidate memory authorization")
        try await controller.saveCredential(secret)
        await controller.setClassActive(false)
        let source = SummarySource(kind: .pdf, entityID: "asset-test", version: 1, text: String(repeating: "可靠材料。", count: 3500), page: 2)
        let snapshot = SummarySnapshot(classID: "class-test", sources: [source], excluded: ["图片、图表及扫描内容未分析"])
        CloudBoundaryFixture.reset { request, _ in
            let value = try input(request)
            let id = (value["sources"] as? [[String: String]])?.first?["id"] ?? source.id
            return try reply(request, ["claims": [["text": "概念来自已保存材料。", "referenceIDs": [id, "INVALID"]]]])
        }
        await controller.generateSummary(snapshot)
        try await until { !controller.summaryRunning }
        let summary = controller.state.summaries.last!
        try check(summary.status == "completed" && summary.chunks.count == 3 && summary.missingChunkIDs.isEmpty, "long summary processes three bounded chunks and synthesis")
        try check(summary.chunks.flatMap(\.spans).reduce(0, { $0 + $1.characterCount }) == source.text.count, "summary coverage includes every source character")
        try check(summary.invalidReferenceCount == 4 && summary.claims.allSatisfy { $0.referenceIDs == [source.id] } && summary.source(for: "INVALID") == nil, "invalid citations never become clickable sources")
        try check(summary.snapshot.hash == snapshot.hash && summary.snapshot.sources[0].page == 2, "summary preserves fixed extraction version and source page")
        // Mid-generation failures disclose exact unprocessed chunks, retain prior results.
        CloudBoundaryFixture.reset { request, n in
            if n == 2 { return CloudBoundaryFixture.Reply(status: 403, data: Data()) }
            return try reply(request, ["claims": [["text": "部分", "referenceIDs": [source.id]]]])
        }
        await controller.generateSummary(snapshot)
        try await until { !controller.summaryRunning }
        try check(controller.state.summaries.count == 2 && controller.state.summaries.last!.status == "partial" && controller.state.summaries.last!.missingChunkIDs.count == 2, "partial summary failure preserves old result and missing coverage")
        CloudBoundaryFixture.reset { request, _ in try reply(request, ["claims": [["text": "迟到", "referenceIDs": [source.id]]]], delay: 0.25) }
        await controller.generateSummary(snapshot)
        try await until { CloudBoundaryFixture.count > 0 }
        await controller.cancelSummary()
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(controller.state.summaries.last!.status == "cancelled" && controller.state.summaries.last!.claims.isEmpty, "summary cancellation isolates late response")
        CloudBoundaryFixture.reset { _, _ in throw URLError(.timedOut) }
        try await controller.enqueueSavedSegment(segment("timeout"), targetLanguage: "zh-Hans")
        try await until { controller.state.jobs.first { $0.segment.id == "timeout" }?.status == .needsAttention }
        try check(CloudBoundaryFixture.count == 3 && controller.state.jobs.first { $0.segment.id == "timeout" }?.translation == nil, "timeouts exhaust finite retries without fabricated translation")
        CloudBoundaryFixture.reset { _, _ in CloudBoundaryFixture.Reply(status: 429, headers: ["Retry-After": "1000"], data: Data()) }
        try await controller.enqueueSavedSegment(segment("long-rate-limit"), targetLanguage: "zh-Hans")
        try await until { controller.state.jobs.first { $0.segment.id == "long-rate-limit" }?.status == .needsAttention }
        try check(CloudBoundaryFixture.count == 1, "server retry delay beyond bounded window requires manual action")
        // Failed disk writes prohibit dispatch and speech; retained memory is recoverable.
        controller.onPersist = { _ in throw CocoaError(.fileWriteNoPermission) }
        CloudBoundaryFixture.reset { request, _ in try reply(request, ["id": "disk", "text": "不可假保存"]) }
        do { try await controller.enqueueSavedSegment(segment("disk"), targetLanguage: "zh-Hans"); throw CloudFailure.malformedResponse } catch CloudFailure.persistence { }
        try check(CloudBoundaryFixture.count == 0 && controller.queueStatus == "persistence" && controller.queueErrorCode == "persistence", "write failure stops dispatch and reports unsaved state")
        // A response already received must survive a failed commit without a
        // second provider dispatch, duplicate callback or playback eligibility.
        let repair = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: IsolatedCredentials(), monitorNetwork: false)
        var permitResultCommit = false
        var committed: CloudState?
        var recoveredCallbacks: [CloudTranslation] = []
        repair.onPersist = { state in
            if state.jobs.contains(where: { $0.status == .completed }), !permitResultCommit { throw CocoaError(.fileWriteNoPermission) }
            committed = state
        }
        repair.onSavedTranslation = { recoveredCallbacks.append($0) }
        await repair.setClassActive(true)
        try await repair.saveCredential(secret)
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "保留收到的译文"]) }
        try await repair.enqueueSavedSegment(segment("repair-result"), targetLanguage: "zh-Hans")
        try await until { repair.state.jobs.first?.errorCode == "persistence" }
        await repair.resumeAfterPersistenceRepair()
        try check(repair.state.jobs[0].translation?.text == "保留收到的译文" && repair.state.jobs[0].status == .needsAttention && repair.queueStatus == "persistence" && repair.queueErrorCode == "persistence" && recoveredCallbacks.isEmpty, "failed result commit and repeated repair retain result without publishing saved callback")
        await repair.generateSummary(SummarySnapshot(classID: "class-test", sources: []))
        try check(repair.summaryActionError == .persistence && repair.queueErrorCode == "persistence", "shared unsaved storage remains visible in both operation contexts")
        permitResultCommit = true
        await repair.resumeAfterPersistenceRepair()
        try check(repair.completedCount == 1 && committed?.jobs[0].status == .completed && repair.state.jobs[0].errorCode == nil && repair.lastError == nil && repair.queueErrorCode == nil && repair.summaryActionError == nil && recoveredCallbacks.count == 1 && recoveredCallbacks[0].historical, "persistence repair commits retained translation as completed and historical before saved callback")
        await repair.resumeAfterPersistenceRepair()
        try await Task.sleep(nanoseconds: 60_000_000)
        try check(CloudBoundaryFixture.count == 1 && recoveredCallbacks.count == 1 && !repair.speech.enabled, "repeated successful repair never redispatches or republishes retained translation and stays silent")
        await repair.shutdown()
        let checkpoint = CloudController(state: CloudState(classID: "class-test"), configuration: CloudConfiguration(provider: .openAI), session: network, credentials: IsolatedCredentials(), monitorNetwork: false)
        var permitCheckpoint = false
        checkpoint.onPersist = { state in if state.jobs.contains(where: { $0.status == .running }), !permitCheckpoint { throw CocoaError(.fileWriteNoPermission) } }
        await checkpoint.setClassActive(true)
        try await checkpoint.saveCredential(secret)
        CloudBoundaryFixture.reset { request, _ in let value = try input(request); return try reply(request, ["id": value["id"]!, "text": "保存后才发送"]) }
        try await checkpoint.enqueueSavedSegment(segment("dispatch-checkpoint"), targetLanguage: "zh-Hans")
        try check(CloudBoundaryFixture.count == 0 && checkpoint.queueStatus == "persistence" && checkpoint.state.jobs[0].status == .queued && checkpoint.state.jobs[0].attempts == 0 && checkpoint.state.jobs[0].dispatches.isEmpty, "failed dispatch checkpoint rolls back unsent running marker and attempt without network")
        permitCheckpoint = true
        await checkpoint.resumeAfterPersistenceRepair()
        try await until { checkpoint.completedCount == 1 }
        try check(CloudBoundaryFixture.count == 1 && checkpoint.state.jobs[0].attempts == 1 && checkpoint.state.jobs[0].dispatches.count == 1, "repaired dispatch checkpoint sends exactly one first attempt and completes")
        await checkpoint.setClassActive(false)
        var permitSummary = false
        checkpoint.onPersist = { state in if !state.summaries.isEmpty, !permitSummary { throw CocoaError(.fileWriteNoPermission) } }
        let unsentSnapshot = SummarySnapshot(classID: "class-test", sources: [SummarySource(kind: .note, entityID: "saved-note", version: 1, text: "已保存的笔记")])
        await checkpoint.generateSummary(unsentSnapshot)
        try check(!checkpoint.summaryRunning && checkpoint.state.summaries[0].status == "failed" && checkpoint.state.summaries[0].errorCode == "persistence" && CloudBoundaryFixture.count == 1, "failed summary snapshot commit never starts request or leaves phantom running state")
        permitSummary = true
        await checkpoint.resumeAfterPersistenceRepair()
        try check(checkpoint.queueStatus != "persistence" && checkpoint.state.summaries[0].status == "failed" && checkpoint.state.summaries[0].snapshot.id == unsentSnapshot.id && CloudBoundaryFixture.count == 1, "summary persistence repair preserves failed fixed snapshot without automatic request")
        await checkpoint.shutdown()
        var policy = MandarinSpeechPolicy(); let now = Date(); policy.classActive = true; policy.enabledAt = now
        try check(!policy.offer(SpeechCandidate(text: "历史", confirmedAt: now, savedAt: now, historical: true), now: now), "silent speech policy rejects historical translation")
        try check(!policy.offer(SpeechCandidate(text: "旧", confirmedAt: now.addingTimeInterval(-1), savedAt: now, historical: false), now: now), "speech enable point excludes earlier source")
        for _ in 0..<6 { _ = policy.offer(SpeechCandidate(text: String(repeating: "字", count: 70), confirmedAt: now, savedAt: now, historical: false), now: now) }
        try check(policy.queue.count == 3 && policy.queue.reduce(0, { $0 + $1.text.count }) <= 240, "silent speech queue bounded by time characters and count")
        try check(policy.skippedCount == 3, "silent speech policy counts actual discarded backlog for visible notice")
        policy.discardExpired(now: now.addingTimeInterval(21))
        try check(policy.skippedCount == 6 && policy.queue.isEmpty, "expired queued speech contributes to skipped notice without deleting translation text")
        _ = policy.offer(SpeechCandidate(text: "历史", confirmedAt: now, savedAt: now, historical: true), now: now)
        try check(policy.skippedCount == 6, "historical speech ineligibility is not misreported as skipped live speech")
        policy.stop(); try check(policy.queue.isEmpty && policy.enabledAt == nil, "speech stop clears queued playback eligibility")
        await controller.shutdown(); await reopened.shutdown(); network.invalidateAndCancel()
        let report: [String: Any] = ["kind": "HTTP boundary fixtures + real serialized persistence; no semantic/account acceptance", "checks": checks, "passed": checks.count, "realProviderCalls": 0, "keychainReads": 0, "audioPlayback": 0, "retryPolicy": "3 total attempts; 2s then 4s minimum; Retry-After honoured up to 300s else manual", "stateFile": stateFile.path]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    }
}
