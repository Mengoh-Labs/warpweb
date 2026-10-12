import Foundation
@preconcurrency import Network
import WarpWebCore

struct Response: Sendable {
    var status = 200
    var type = "application/json"
    var data: Data
    var imageEncoder: String? = nil
    static func json(_ object: [String: Any], status: Int = 200) -> Response {
        Response(status: status, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }
}

@MainActor final class Server {
    let listener: NWListener
    let handler: @MainActor (Request) async -> Response
    var connections: [ObjectIdentifier: Client] = [:]
    init(port: UInt16, handler: @escaping @MainActor (Request) async -> Response) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                guard self.connections.count < 32 else { connection.cancel(); return }
                let client = Client(connection: connection, handler: self.handler)
                let id = ObjectIdentifier(client)
                self.connections[id] = client
                client.onClose = { [weak self] in self?.connections.removeValue(forKey: id) }
                client.start()
            }
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state { fputs("warpweb listener: \(error)\n", stderr); exit(1) }
        }
        listener.start(queue: .main)
    }
}

@MainActor final class Client {
    let connection: NWConnection
    let handler: @MainActor (Request) async -> Response
    var buffer = Data()
    var onClose: (() -> Void)?
    var timeout: Task<Void, Never>?
    init(connection: NWConnection, handler: @escaping @MainActor (Request) async -> Response) {
        self.connection = connection; self.handler = handler
    }
    func start() {
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if !Task.isCancelled { self?.close() }
        }
        receive()
    }
    func close() { timeout?.cancel(); connection.cancel(); onClose?(); onClose = nil }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.buffer.append(data) }
                do {
                    if let request = try Request.parse(self.buffer) {
                        self.send(await self.handler(request))
                    } else if complete || error != nil { self.close() }
                    else { self.receive() }
                } catch { self.send(.json(["error": "Malformed or oversized request"], status: 400)) }
            }
        }
    }
    func send(_ response: Response) {
        let header = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; connect-src 'self'; base-uri 'none'; form-action 'self'\r\n\r\n"
        var data = Data(header.utf8); data.append(response.data)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close() }
        })
    }
}
