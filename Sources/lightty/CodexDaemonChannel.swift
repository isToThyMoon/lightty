import Foundation
import Darwin

/// 连到 Codex 共享后台进程（本机 app-server daemon）的一条客户端连接，只为听它的广播。
///
/// 入口是官方的 `codex app-server proxy`：它把标准输入输出原样转到后台进程的控制 socket，
/// socket 的位置由 Codex 自己按配置根算，我们不猜路径。socket 上跑的是 WebSocket
/// （上游 `app-server-transport/src/transport/unix_socket.rs` 用 `accept_hdr_async` 接受连接），
/// 所以这边先做一次 HTTP 升级握手，之后每条 JSON-RPC 消息是一个文本帧。
/// 不需要鉴权，只靠 socket 文件权限。握手只用根路径：`/daemon/shutdown` 会关掉后台进程。
///
/// 和 `CodexAppServer`（lightty 自己起的独立 app-server，列会话和插件用）不是一回事：
/// 那个进程里没有别人的会话，这里连的是终端里的 `codex` 共用的那一个。
final class CodexDaemonChannel: @unchecked Sendable {
    /// 广播与请求结果都在主线程回调。
    var onNotification: ((String, [String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var pending: [Int: ([String: Any]?) -> Void] = [:]
    private var nextID = 0
    private var open = true
    private var inputClosed = false
    /// 由 `writeLock` 保护。升级完成前发出的帧先排队：服务端读握手时会把紧跟在
    /// 请求头后面的字节一起吞掉（实测：握手后立刻发的 initialize 永远等不到回应）。
    private var upgraded = false
    private var queued: [Data] = []

    init(_ spec: AgentHelperProcess) throws {
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.currentDirectoryURL = spec.directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try write(WebSocketFrames.handshake(key: Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            .base64EncodedString()))
        let reader = Thread { [self] in readLoop() }
        reader.name = "lightty.codex-daemon"
        reader.start()
    }

    /// 发请求，回应（`result`，失败为 nil）在主线程交给 `completion`。
    func request(_ method: String, params: [String: Any] = [:],
                 completion: @escaping ([String: Any]?) -> Void = { _ in }) {
        lock.lock()
        guard open else { lock.unlock(); DispatchQueue.main.async { completion(nil) }; return }
        nextID += 1
        let id = nextID
        pending[id] = completion
        lock.unlock()
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    func notify(_ method: String) {
        send(["jsonrpc": "2.0", "method": method])
    }

    func close() {
        lock.lock()
        let wasOpen = open
        open = false
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        writeLock.lock()
        if !inputClosed {
            inputClosed = true
            try? input.fileHandleForWriting.close()
        }
        writeLock.unlock()
        if process.isRunning { process.terminate() }
        DispatchQueue.main.async { [onClose] in
            waiting.values.forEach { $0(nil) }
            if wasOpen { onClose?() }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let frame = WebSocketFrames.encodeText(data)
        writeLock.lock()
        let ready = upgraded
        if !ready { queued.append(frame) }
        writeLock.unlock()
        if ready { try? write(frame) }
    }

    /// 收到 101 之后放行排队的帧。
    private func finishUpgrade() {
        writeLock.lock()
        upgraded = true
        let pending = queued
        queued.removeAll()
        writeLock.unlock()
        for frame in pending { try? write(frame) }
    }

    private func write(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !inputClosed else { throw CodexAppServer.Failure.exited }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readLoop() {
        let handle = output.fileHandleForReading
        var buffer = Data()
        var handshakeDone = false
        var decoder = WebSocketFrames.Decoder()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if !handshakeDone {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 16 * 1024 { break }
                    continue
                }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                guard head.split(separator: "\r\n").first?.contains(" 101 ") == true else { break }
                handshakeDone = true
                finishUpgrade()
                buffer = Data(buffer[end.upperBound...])
            }
            decoder.append(buffer)
            buffer.removeAll()
            do {
                while let event = try decoder.next() {
                    switch event {
                    case .text(let data): dispatch(data)
                    case .ping(let payload): try? write(WebSocketFrames.encode(opcode: 0xA, payload: payload))
                    case .close: throw WebSocketFrames.Failure.closed
                    }
                }
            } catch { break }
        }
        close()
        try? handle.close()
    }

    private func dispatch(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let method = message["method"] as? String {
            if let id = message["id"] {
                // 后台进程反过来问的请求（审批之类）不归旁听者管，拒绝，免得它等。
                send(["jsonrpc": "2.0", "id": id,
                      "error": ["code": -32601, "message": "\(method) is not supported"]])
                return
            }
            let params = message["params"] as? [String: Any] ?? [:]
            DispatchQueue.main.async { [weak self] in self?.onNotification?(method, params) }
            return
        }
        guard let id = message["id"] as? Int else { return }
        lock.lock()
        let completion = pending.removeValue(forKey: id)
        lock.unlock()
        let result = message["result"] as? [String: Any]
        DispatchQueue.main.async { completion?(result) }
    }
}

/// WebSocket 客户端这一侧用得到的最小一套（RFC 6455）：握手请求、带掩码的发送帧、
/// 解析服务端帧（不带掩码，可能分片）。纯函数与值类型，单测直接喂字节。
enum WebSocketFrames {
    enum Failure: Error { case closed, malformed, tooLarge }

    enum Event: Equatable {
        case text(Data)
        case ping(Data)
        case close
    }

    /// 单条消息的上限：会话对象里带预览和环境，给足余量，但不让一个坏帧撑爆内存。
    static let maximumMessage = 16 * 1024 * 1024

    static func handshake(key: String) -> Data {
        Data(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n").utf8)
    }

    static func encodeText(_ payload: Data) -> Data { encode(opcode: 0x1, payload: payload) }

    /// 客户端发出的帧必须带掩码。
    static func encode(opcode: UInt8, payload: Data,
                       mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }) -> Data {
        var frame = Data([0x80 | opcode])
        let length = payload.count
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= Int(UInt16.max) {
            frame.append(0x80 | 126)
            frame.append(contentsOf: withUnsafeBytes(of: UInt16(length).bigEndian, Array.init))
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: withUnsafeBytes(of: UInt64(length).bigEndian, Array.init))
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return frame
    }

    /// 逐帧解析，把分片拼回整条消息。数据不够一帧时返回 nil，等下一块。
    struct Decoder {
        private var buffer = Data()
        private var fragments = Data()
        private var fragmenting = false

        mutating func append(_ data: Data) { buffer.append(data) }

        mutating func next() throws -> Event? {
            while true {
                let bytes = [UInt8](buffer.prefix(14))
                guard bytes.count >= 2 else { return nil }
                let final = bytes[0] & 0x80 != 0
                let opcode = bytes[0] & 0x0F
                let masked = bytes[1] & 0x80 != 0
                var length = Int(bytes[1] & 0x7F)
                var offset = 2
                if length == 126 {
                    guard bytes.count >= 4 else { return nil }
                    length = Int(bytes[2]) << 8 | Int(bytes[3])
                    offset = 4
                } else if length == 127 {
                    guard bytes.count >= 10 else { return nil }
                    let wide = bytes[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    guard wide <= UInt64(maximumMessage) else { throw Failure.tooLarge }
                    length = Int(wide)
                    offset = 10
                }
                let maskKey: [UInt8]
                if masked {
                    guard bytes.count >= offset + 4 else { return nil }
                    maskKey = Array(bytes[offset..<offset + 4])
                    offset += 4
                } else {
                    maskKey = []
                }
                guard buffer.count >= offset + length else { return nil }
                let start = buffer.startIndex
                var payload = Data(buffer[(start + offset)..<(start + offset + length)])
                buffer = Data(buffer[(start + offset + length)...])
                if masked {
                    payload = Data(payload.enumerated().map { $0.element ^ maskKey[$0.offset % 4] })
                }
                switch opcode {
                case 0x1, 0x2:
                    guard !fragmenting else { throw Failure.malformed }
                    if final {
                        // 协议消息都是文本帧；二进制帧用不上，跳过它接着解析后面的帧。
                        if opcode == 0x1 { return .text(payload) }
                        continue
                    }
                    fragmenting = true
                    fragments = payload
                case 0x0:
                    guard fragmenting else { throw Failure.malformed }
                    fragments.append(payload)
                    guard fragments.count <= maximumMessage else { throw Failure.tooLarge }
                    if final {
                        fragmenting = false
                        defer { fragments = Data() }
                        return .text(fragments)
                    }
                case 0x8: return .close
                case 0x9: return .ping(payload)
                default: continue  // pong 与保留操作码：忽略
                }
            }
        }
    }
}
