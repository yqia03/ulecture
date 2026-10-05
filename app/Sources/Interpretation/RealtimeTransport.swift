import Foundation

/// Injectable transport. One receive loop and one serialized writer per session.
@MainActor protocol RealtimeTransport: AnyObject {
    func connect(request: URLRequest) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@MainActor final class URLSessionRealtimeTransport: RealtimeTransport {
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    func connect(request: URLRequest) async throws {
        guard socket == nil else { throw InterpretationFailure.invalidConfiguration }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        self.socket = socket
        socket.resume()
    }
    func send(_ data: Data) async throws {
        guard let socket, let text = String(data: data, encoding: .utf8) else { throw InterpretationFailure.connectionLost }
        do { try await socket.send(.string(text)) }
        catch { throw transportFailure(socket, error) }
    }
    func receive() async throws -> Data {
        guard let socket else { throw InterpretationFailure.connectionLost }
        do {
            switch try await socket.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: throw InterpretationFailure.protocolViolation
            }
        } catch { throw transportFailure(socket, error) }
    }
    private func transportFailure(_ socket: URLSessionWebSocketTask, _ error: Error) -> InterpretationFailure {
        if let response = socket.response as? HTTPURLResponse, response.statusCode >= 400 {
            return InterpretationFailure.fromProvider(code: String(response.statusCode), type: nil)
        }
        return InterpretationFailure.fromTransport(error)
    }
    func close() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
