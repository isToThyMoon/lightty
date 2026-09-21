import Foundation
import Testing
@testable import lightty

/// 常驻 app-server 的生命周期。替身是一段 sh：按收到的 id 回话，回话里带上方法名和自己的 pid，
/// 每次启动往 `launches` 记一行；`exit` 让它退出，`silent` 让它不回话，`huge` 回一条超过上限的消息，
/// `reject` 回 JSON-RPC 错误，`ask` 先反过来问 lightty 一句、再报告有没有收到回话。
struct CodexAppServerTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-app-server-\(UUID())")
        var executable: URL { directory.appendingPathComponent("codex") }

        init() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeScript()
        }

        /// 原子写入：换成新的 inode，和升级替换可执行文件一样。
        func writeScript() throws {
            try #"""
            #!/bin/sh
            echo launch >> "$(dirname "$0")/launches"
            while IFS= read -r line; do
              id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
              [ -n "$id" ] || continue
              method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p')
              case "$method" in
                exit) exit 0 ;;
                silent) continue ;;
                huge) printf '{"id":%s,"result":{"blob":"' "$id"; head -c 9000000 /dev/zero | tr '\0' 'a'; printf '"}}\n'; continue ;;
                reject) printf '{"id":%s,"error":{"code":-32602,"message":"nope"}}\n' "$id"; continue ;;
                ask)
                  printf '{"id":"srv-1","method":"approval/request","params":{}}\n'
                  IFS= read -r reply
                  case "$reply" in *srv-1*-32601*|*-32601*srv-1*) ok=yes ;; *) ok=no ;; esac
                  printf '{"id":%s,"result":{"answered":"%s"}}\n' "$id" "$ok"; continue ;;
              esac
              printf '{"id":%s,"result":{"method":"%s","pid":%s}}\n' "$id" "$method" "$$"
            done
            """#.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        var launches: Int {
            ((try? String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8)) ?? "")
                .split(separator: "\n").count
        }

        func server() -> CodexAppServer {
            CodexAppServer(spec: AgentHelperProcess(executable: executable, arguments: [], directory: directory,
                                                    environment: ["PATH": "/usr/bin:/bin"]))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private func pid(_ result: [String: Any]) -> Int? { result["pid"] as? Int }

    @Test func requestsShareOneProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let first = try server.request("thread/list", params: [:])
        let second = try server.request("plugin/list", params: [:])
        #expect(first["method"] as? String == "thread/list")
        #expect(second["method"] as? String == "plugin/list")
        #expect(pid(first) == pid(second))
        #expect(fixture.launches == 1)
    }

    @Test func concurrentRequestsEachGetTheirOwnAnswer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let lock = NSLock()
        var answers: [Int: String] = [:]
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let method = (try? server.request("m\(index)", params: [:]))?["method"] as? String
            lock.lock()
            answers[index] = method
            lock.unlock()
        }
        #expect(answers == Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, "m\($0)") }))
        #expect(fixture.launches == 1)
    }

    @Test func aProcessThatExitedIsReplacedOnTheNextRequest() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let before = try server.request("ping", params: [:])
        #expect(throws: (any Error).self) { try server.request("exit", params: [:]) }
        let after = try server.request("ping", params: [:])
        #expect(pid(before) != pid(after))
        #expect(fixture.launches == 2)
    }

    @Test func aProcessThatStopsAnsweringIsRetired() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let before = try server.request("ping", params: [:])
        #expect(throws: CodexAppServer.Failure.timedOut) { try server.request("silent", params: [:], timeout: 0.3) }
        let after = try server.request("ping", params: [:])
        #expect(pid(before) != pid(after))
        #expect(fixture.launches == 2)
    }

    /// 超过单条上限的回应报「太大」，不能笼统说成接口不支持；这个进程不再复用。
    @Test func anOversizedAnswerIsReportedAsTooLarge() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let before = try server.request("ping", params: [:])
        #expect(throws: CodexAppServer.Failure.tooLarge) { try server.request("huge", params: [:]) }
        let after = try server.request("ping", params: [:])
        #expect(pid(before) != pid(after))
    }

    /// Codex 拒绝的请求带着它自己的原话，进程照常复用。
    @Test func aRejectedRequestCarriesCodexsMessage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        #expect(throws: CodexAppServer.Failure.rejected("nope")) { try server.request("reject", params: [:]) }
        _ = try server.request("ping", params: [:])
        #expect(fixture.launches == 1)
    }

    /// 握手不理会调用方的取消：半路关掉刚起的进程会砍断它的启动任务。
    @Test func cancellingDuringStartupKeepsTheFreshProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        #expect(throws: CancellationError.self) { try server.request("ping", params: [:], cancelled: { true }) }
        _ = try server.request("ping", params: [:])
        #expect(fixture.launches == 1)
    }

    /// app-server 反过来问的请求要有回话，不然它会一直等。
    @Test func requestsFromTheServerAreAnswered() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        #expect(try server.request("ask", params: [:])["answered"] as? String == "yes")
    }

    @Test func anUpgradedExecutableGetsAFreshProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let before = try server.request("ping", params: [:])
        try fixture.writeScript()
        let after = try server.request("ping", params: [:])
        #expect(pid(before) != pid(after))
        #expect(fixture.launches == 2)
    }

    @Test func cancellationStopsWaitingWithoutRetiringTheProcess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let server = fixture.server()
        defer { server.shutdown() }
        let before = try server.request("ping", params: [:])
        #expect(throws: CancellationError.self) {
            try server.request("silent", params: [:], cancelled: { true })
        }
        let after = try server.request("ping", params: [:])
        #expect(pid(before) == pid(after))
        #expect(fixture.launches == 1)
    }
}
