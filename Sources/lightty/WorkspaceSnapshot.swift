import AppKit
import LighttyCore

// MARK: - 快照模型

/// 工作区快照：窗口 → 标签页 → 分屏树 → pane。落盘 ~/.lightty/workspace.json，
/// 重启后按它重建窗口/标签页/pane（含命名、cwd、任务绑定），并对还活着的
/// agent 会话自动 `--resume`。
///
/// 语义：这是「上次关掉时的样子」，不是任务持久层（那是 ~/.lightty/tasks）。
/// 结构变了就重写整份文件（几 KB），不做增量。
struct WorkspaceSnapshot: Codable, Equatable {
    static let currentVersion = PersistenceFormat.workspace.currentVersion

    var format = PersistenceFormat.workspace.rawValue
    var version: Int = WorkspaceSnapshot.currentVersion
    var windows: [WindowSnapshot]
}

struct WindowSnapshot: Codable, Equatable {
    var frame: CGRect?
    var activeTabIndex: Int
    var tabs: [TabSnapshot]
    var taskPanelOpen: Bool
    var tabSidebarOpen: Bool
    var primarySidebarMode: String? = nil
}

struct TabSnapshot: Codable, Equatable {
    var title: String
    var root: SplitNodeSnapshot
}

/// 分屏树：叶 = pane；节点 = 一个 NSSplitView（方向 + 各子项占比）。
indirect enum SplitNodeSnapshot: Codable, Equatable {
    case pane(PaneSnapshot)
    case split(vertical: Bool, fractions: [Double], children: [SplitNodeSnapshot])

    /// 树序第一个叶子（恢复时它就是窗口的 initialPane）
    var firstLeaf: PaneSnapshot {
        switch self {
        case .pane(let pane): return pane
        case .split(_, _, let children): return children[0].firstLeaf
        }
    }

    var leaves: [PaneSnapshot] {
        switch self {
        case .pane(let pane): return [pane]
        case .split(_, _, let children): return children.flatMap(\.leaves)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, pane, vertical, fractions, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "pane":
            self = .pane(try c.decode(PaneSnapshot.self, forKey: .pane))
        case "split":
            let children = try c.decode([SplitNodeSnapshot].self, forKey: .children)
            guard !children.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children, in: c, debugDescription: "split without children")
            }
            self = .split(
                vertical: try c.decode(Bool.self, forKey: .vertical),
                fractions: try c.decode([Double].self, forKey: .fractions),
                children: children)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown node kind \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try c.encode("pane", forKey: .kind)
            try c.encode(pane, forKey: .pane)
        case .split(let vertical, let fractions, let children):
            try c.encode("split", forKey: .kind)
            try c.encode(vertical, forKey: .vertical)
            try c.encode(fractions, forKey: .fractions)
            try c.encode(children, forKey: .children)
        }
    }
}

struct PaneSnapshot: Codable, Equatable {
    /// pane 名（用户可改的会话态标签；恢复后原样回填）
    var name: String
    /// shell 的当前目录（OSC 7），新 shell 生在这里
    var workingDirectory: String?
    /// 绑定任务的文件路径（恢复时文件还在才重新绑定）
    var taskFile: String?
    /// Published v1 wire fields, projected from PaneSessionAssociation.
    /// agentAlive records resume intent, not a guarantee that a CLI is currently running.
    var agent: String?
    var sessionID: String?
    /// agent 自报的 cwd。`--resume` 必须在同一项目目录里执行（会话按目录归档），
    /// 恢复 agent 的 pane 优先用它做 shell 的出生目录。
    var agentCWD: String?
    var agentAlive: Bool
    var catalogSession: AgentSessionKey? = nil
    var catalogConfiguration: SessionConfigurationLocation? = nil
}

// MARK: - 落盘

/// 快照的读写与节流。结构/命名/cwd/agent 状态任一变化都 `scheduleSave()`，
/// 合并到 0.8s 后写一次；关最后一个窗口、退出时同步写。
///
/// `frozen`：最后一个窗口关闭时把含该窗口的快照定格——随后 applicationWillTerminate
/// 再来存时窗口列表已经空了，不能把定格的内容覆盖成空。
final class WorkspaceStore {
    /// 测试进程（XCTest 注入 XCTestConfigurationFilePath）落到临时文件：单元测试会建
    /// 真窗口，节流保存若写进用户真实的 workspace.json，下次启动会恢复出测试残骸。
    static let shared = WorkspaceStore(
        fileURL: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            ? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("lightty-tests-workspace-\(getpid()).json")
            : nil)

    let fileURL: URL
    private(set) var frozen = false
    private(set) var storageReadOnly = false
    /// 每来一次就把上一次取消重排——「安静下来才存」。延迟每次可变，所以
    /// `schedule(delay:)` 传具体值。
    private lazy var saves = Coalescer(.debounce(0.8)) { [weak self] in self?.saveNow() }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(PersistenceFormat.workspace.relativePath)
    }

    func load() -> WorkspaceSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              (try? PersistenceFormat.workspace.validate(data)) != nil,
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
              snapshot.version == WorkspaceSnapshot.currentVersion else {
            storageReadOnly = true
            return nil
        }
        return snapshot
    }

    /// 当前全部窗口的快照（无标签页的空态窗口不记）
    static func capture() -> WorkspaceSnapshot {
        let windows = (AppState.shared?.windowControllers ?? []).compactMap { $0.snapshot() }
        return WorkspaceSnapshot(windows: windows)
    }

    func scheduleSave(delay: TimeInterval = 0.8) {
        guard !frozen else { return }
        saves.schedule(delay: delay)
    }

    func saveNow() {
        guard !frozen else { return }
        saves.cancel()
        write(Self.capture())
    }

    /// 最后一个窗口关闭：写下含它的快照并定格
    func freeze(with snapshot: WorkspaceSnapshot) {
        saves.cancel()
        write(snapshot)
        frozen = true
    }

    func write(_ snapshot: WorkspaceSnapshot) {
        guard !storageReadOnly else { return }
        // Recheck at write time too: another version may have replaced the file.
        if FileManager.default.fileExists(atPath: fileURL.path), load() == nil { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              (try? PersistenceFormat.workspace.validate(data)) != nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("workspace snapshot write failed: \(error)")
        }
    }
}

// MARK: - 恢复

enum WorkspaceRestorer {
    /// 按快照重建全部窗口并前置。没有可恢复的窗口（快照为空 / 每个窗口都没有
    /// 标签页）返回空数组，调用方开默认窗口。
    @MainActor
    static func restore(_ snapshot: WorkspaceSnapshot) -> [TerminalWindowController] {
        var controllers: [TerminalWindowController] = []
        for window in snapshot.windows where !window.tabs.isEmpty {
            let controller = TerminalWindowController(restoring: window)
            AppState.shared.windowControllers.append(controller)
            controller.syncSessionWindow()
            controller.window?.makeKeyAndOrderFront(nil)
            controllers.append(controller)
        }
        return controllers
    }
}
