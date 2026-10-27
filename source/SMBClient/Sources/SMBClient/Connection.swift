import Foundation
import Network

public class Connection {
  let host: String
  var onDisconnected: (Error) -> Void

  private let connection: NWConnection
  private var buffer = Data()

  private let semaphore = Semaphore(value: 1)

  public var state: NWConnection.State {
    connection.state
  }

  public init(host: String) {
    self.host = host
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(integerLiteral: 445)
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    onDisconnected = { _ in }
  }

  public init(host: String, port: Int) {
    self.host = host
    let endpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: UInt16(port))!
    )
    connection = NWConnection(to: endpoint, using: .tcp)
    onDisconnected = { _ in }
  }

  public func connect() async throws {
    return try await withCheckedThrowingContinuation { (continuation) in
      connection.stateUpdateHandler = { (state) in
        switch state {
        case .setup, .preparing:
          break
        case .waiting(let error):
          continuation.resume(throwing: error)
          self.connection.stateUpdateHandler = nil
        case .ready:
          continuation.resume()
          self.connection.stateUpdateHandler = stateUpdateHandler
        case .failed(let error):
          continuation.resume(throwing: error)
          self.connection.stateUpdateHandler = nil
        case .cancelled:
          continuation.resume(throwing: ConnectionError.cancelled)
          self.connection.stateUpdateHandler = nil
        @unknown default:
          break
        }
      }

      connection.start(queue: .global(qos: .userInitiated))
    }

    @Sendable
    func stateUpdateHandler(_ state: NWConnection.State) {
      switch state {
      case .waiting(let error), .failed(let error):
        onDisconnected(error)
      case .setup, .preparing, .ready, .cancelled:
        break
      @unknown default:
        break
      }
    }
  }

  public func disconnect() {
    connection.cancel()
  }

  public func send(_ data: Data) async throws -> Data {
    await semaphore.wait()
    defer { Task { await semaphore.signal() } }

    switch connection.state {
    case .setup:
      try await connect()
    case .waiting(let error), .failed(let error):
      onDisconnected(error)
      throw error
    case .preparing, .ready:
      break
    case .cancelled:
      throw ConnectionError.cancelled
    @unknown default:
      throw ConnectionError.unknown
    }

    let transportPacket = DirectTCPPacket(smb2Message: data)
    let content = transportPacket.encoded()

    return try await withCheckedThrowingContinuation { (continuation) in
      connection.send(content: content, completion: .contentProcessed() { (error) in
        if let error {
          continuation.resume(throwing: error)
          return
        }

        self.receive() { (result) in
          switch result {
          case .success(let data):
            continuation.resume(returning: data)
          case .failure(let error):
            continuation.resume(throwing: error)
          }
        }
      })
    }
  }

  // Cobe's copy (2026-10-20): the original read the 4-byte length from whatever one TCP read
  // returned and crashed (index out of range in ByteReader) when a read held fewer bytes or a packet was split.
  // Now the bytes are collected first and only whole packets are read; a short or malformed reply is an error.

  private func receive(completion: @escaping (Result<Data, Error>) -> Void) {
    fill(upTo: 4) { result in
      if case .failure(let error) = result { completion(.failure(error)); return }
      let start = self.buffer.startIndex
      let length = Int(self.buffer[start + 1]) << 16 | Int(self.buffer[start + 2]) << 8 | Int(self.buffer[start + 3])
      self.fill(upTo: 4 + length) { result in
        if case .failure(let error) = result { completion(.failure(error)); return }
        let start = self.buffer.startIndex
        let data = Data(self.buffer[(start + 4)..<(start + 4 + length)])
        self.buffer = Data(self.buffer[(start + 4 + length)...])
        self.handle(data, completion: completion)
      }
    }
  }

  private func handle(_ data: Data, completion: @escaping (Result<Data, Error>) -> Void) {
    let headerSize = MemoryLayout<Header>.size
    let reader = ByteReader(data)
    var offset = 0
    var response = Data()
    while true {
      guard offset >= 0, data.count - offset >= headerSize else {
        completion(.failure(ConnectionError.malformed))
        return
      }
      reader.seek(to: offset)
      let header: Header = reader.read()
      switch NTStatus(header.status) {
      case .success, .moreProcessingRequired, .noMoreFiles, .endOfFile:
        response += data
      case .pending:
        // An interim answer: the real one follows as its own packet.
        receive(completion: completion)
        return
      default:
        completion(.failure(ErrorResponse(data: Data(data[(data.startIndex + offset)...]))))
        return
      }
      guard header.nextCommand > 0 else { break }
      offset += Int(header.nextCommand)
    }
    completion(.success(response))
  }

  /// Reads from the connection until the buffer holds at least `byteCount` bytes.
  private func fill(upTo byteCount: Int, completion: @escaping (Result<(), Error>) -> Void) {
    if buffer.count >= byteCount { completion(.success(())); return }
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { (data, _, isComplete, error) in
      if let error { completion(.failure(error)); return }
      guard let data, !data.isEmpty else {
        completion(.failure(isComplete ? ConnectionError.disconnected : ConnectionError.noData))
        return
      }
      self.buffer.append(data)
      self.fill(upTo: byteCount, completion: completion)
    }
  }
}

public enum ConnectionError: Error {
  case malformed
  case noData
  case disconnected
  case cancelled
  case unknown
}
