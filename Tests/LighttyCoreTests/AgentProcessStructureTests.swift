import XCTest
@testable import LighttyCore

/// hook 靠终端作业结构回答两个问题：父进程链上哪个进程是 agent（记 pid + 启动时间给退出
/// 监视、删除核查、「在其他终端中打开」），以及这一发是不是别的会话从工具里拉起的子会话。
/// 判定是纯函数，这张表就是它的全部契约：每行是一条祖先链（hook 的父进程在最前），
/// 取自 `docs/specs/agent-integration-cleanup.md` D 的实测事实表
/// （2026-09-16，Claude Code 2.1.274、Codex 0.154.0，`script` 造 pty 记录的祖先链）。
final class AgentProcessStructureTests: XCTestCase {
    private typealias Facts = AgentProcessIdentity.TerminalFacts

    /// 终端上的前台作业组长：自己一组，且这组正占着终端。
    private func leader(_ pid: Int32, on terminal: Int32 = 1) -> Facts {
        Facts(pid: pid, processGroup: pid, foregroundGroup: pid, terminal: terminal)
    }

    /// 组长起的、仍在终端上的子进程（npm 版 codex 的原生进程、包装脚本里的子 shell）。
    private func onTerminal(_ pid: Int32, group: Int32, terminal: Int32 = 1) -> Facts {
        Facts(pid: pid, processGroup: group, foregroundGroup: group, terminal: terminal)
    }

    /// 同一终端上的后台组成员（组长上面的 shell、login）：在终端上，但前台组不是自己。
    private func behind(_ pid: Int32, foreground: Int32, terminal: Int32 = 1) -> Facts {
        Facts(pid: pid, processGroup: pid, foregroundGroup: foreground, terminal: terminal)
    }

    /// 脱离终端的进程：两家的工具子进程、以及它们里面起的子会话。前台组读出来是 0。
    private func offTerminal(_ pid: Int32, group: Int32) -> Facts {
        Facts(pid: pid, processGroup: group, foregroundGroup: 0, terminal: nil)
    }

    func testTheLeaderAndNestingComeOnlyFromTheTerminalStructure() {
        let claude = leader(100), codex = leader(200)
        let cases: [(name: String, chain: [Facts], leader: Int32?, nested: Bool)] = [
            // Claude 主会话：hook 被 Claude 脱离了终端，但判定从**父进程**起算，
            // 父进程就是组长，中间为空。
            ("claude main session", [claude], 100, false),
            // Codex 主会话：Codex 没有脱离 hook，形状同样是「父进程即组长」。
            ("codex main session", [codex], 200, false),
            // npm 版 codex：node 包装脚本是组长，原生 codex 沿用它的组、仍在终端上。
            // 记包装进程等价——它退出，里面那个也没了。
            ("npm codex wrapper", [onTerminal(210, group: 200), codex], 200, false),
            // 用户自己的启动脚本同理：中间一层带终端的 shell 不算嵌套。
            ("launcher script", [onTerminal(110, group: 100), claude], 100, false),
            // Claude 的 Bash 工具里跑 `claude -p`：内层 agent 与工具 shell 都脱离了终端。
            ("claude tool spawns claude -p",
             [offTerminal(300, group: 250), offTerminal(250, group: 250), claude], 100, true),
            // Codex 的 shell 工具里跑 `codex exec`，同一形状。
            ("codex tool spawns codex exec",
             [offTerminal(400, group: 350), offTerminal(350, group: 350), codex], 200, true),
            // 跨家嵌套也只看结构，不看是哪一家。
            ("claude tool spawns codex",
             [offTerminal(500, group: 450), offTerminal(450, group: 450), claude], 100, true),
            // 工具直接跑 hook（没有内层 agent）：同样是子会话，同样丢掉。
            ("tool shell runs the hook itself", [offTerminal(250, group: 250), claude], 100, true),
            // 整条链都没有控制终端（hook 跑在没有 pty 的环境里）：找不到组长就**不记身份、
            // 也不按嵌套处理**——宁可多报一发状态，不能把主会话的事件丢掉。
            ("no terminal anywhere", [offTerminal(600, group: 600), offTerminal(1, group: 1)], nil, false),
            ("empty chain", [], nil, false),
        ]
        for c in cases {
            let found = AgentProcessIdentity.foregroundJobLeader(in: c.chain)
            XCTAssertEqual(found.leader?.pid, c.leader, c.name)
            XCTAssertEqual(found.isNested, c.nested, c.name)
        }
    }

    /// 开 agent 所在终端的是谁：hook 据此判断这个 agent 是不是跑在 lightty 开的 pane 终端里。
    /// 链取自 2026-09-28 实测（Claude Code 2.1.284，lightty pid 5385）。
    func testTheTerminalOwnerIsTheFirstProcessOffTheAgentsTerminal() {
        let lightty = offTerminal(5385, group: 5385)
        let cases: [(name: String, chain: [Facts], owner: Int32?)] = [
            // pane 里的 Claude：claude → zsh → login 都在 pane 的终端上，再往上就是 lightty。
            ("agent in a pane",
             [leader(9020), behind(5445, foreground: 9020), behind(5427, foreground: 9020), lightty], 5385),
            // agent view 托管的后台会话：跑在 supervisor 的伪终端（另一个设备号）里，往上是
            // 没有终端的伪终端宿主、supervisor，最后才绕回 pane 里拉起 supervisor 的那个界面。
            // 开终端的是伪终端宿主，不是 lightty——继承来的 pane 身份不可信。
            ("agent view background session",
             [leader(7242, on: 5), offTerminal(7237, group: 7237), offTerminal(7229, group: 7229),
              leader(9020), behind(5445, foreground: 9020), lightty], 7237),
            // debug 版 lightty 从别的终端里启动时自己也有控制终端：比的是「是不是同一个终端」，
            // 不是「有没有终端」，归属照样是 lightty。
            ("lightty launched from another terminal",
             [leader(9020), behind(5445, foreground: 9020), behind(5427, foreground: 9020),
              behind(5385, foreground: 777, terminal: 9), behind(700, foreground: 777, terminal: 9)], 5385),
            // 链在走出终端之前就断了（超出上限、祖先已退出）：说不清，交给调用方按「在」处理。
            ("chain ends on the terminal", [leader(9020), behind(5445, foreground: 9020)], nil),
            ("no leader", [offTerminal(600, group: 600)], nil),
        ]
        for c in cases {
            XCTAssertEqual(AgentProcessIdentity.foregroundJobLeader(in: c.chain).terminalOwner, c.owner, c.name)
        }
        XCTAssertEqual(PaneRuntimeDirectory.ownerPID(ofSocket: "/Users/x/.lightty/run/5385.sock"), 5385)
        XCTAssertNil(PaneRuntimeDirectory.ownerPID(ofSocket: "/tmp/lt-test.sock"), "测试的临时 socket 不在约定里")
    }

    /// 采集层只有一件事会静默出错：`kinfo_proc` 的字段取错位置，读出一堆看似合理的垃圾，
    /// 判定跟着全错。拿测试进程自己和 POSIX 的接口对一遍。
    func testTheKernelFieldsAreReadFromTheRightPlace() throws {
        let chain = AgentProcessIdentity.terminalChain(startingAt: getpid(), limit: 1)
        let mine = try XCTUnwrap(chain.first)
        XCTAssertEqual(mine.pid, getpid())
        XCTAssertEqual(mine.processGroup, getpgrp())
        let terminal = open("/dev/tty", O_RDONLY | O_NOCTTY)
        defer { if terminal >= 0 { close(terminal) } }
        XCTAssertEqual(mine.hasControllingTerminal, terminal >= 0, "打得开 /dev/tty 才算有控制终端")
        if terminal >= 0 { XCTAssertEqual(mine.foregroundGroup, tcgetpgrp(terminal)) }
    }
}
