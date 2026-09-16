import Darwin
import Dispatch
import Foundation

/// 路径变更源：开始监听一个目录或文件，有变化时调用 `onChange`（可以在任意线程，防抖归
/// 变更源负责）。返回的对象是监听凭据，持有期间有效，释放即停止。路径打不开时抛错。
/// 生产 adapter 是 `PathWatcher.changeSource`；测试用手动触发的替身。
public typealias PathChangeSource = (_ path: URL, _ onChange: @escaping () -> Void) throws -> AnyObject

/// 目录或单个文件的变更监听：DispatchSource + 防抖。目前只有一个用处：
///
/// - **任务目录**（`TaskBindings`）：只有目录级事件（条目增删改名），文件内容原地修改不触发——
///   但按规范所有写入都走临时文件 + rename，天然产生目录事件。
///
/// 监听单个文件时，它被 rename 替换后监听还挂在旧 inode 上，调用方要自己重开。
public final class PathWatcher {
    public enum WatcherError: Error {
        case cannotOpen(path: String, errno: Int32)
    }

    private let source: DispatchSourceFileSystemObject
    private let queue: DispatchQueue
    private let debounce: TimeInterval
    private let lock = NSLock()
    private var pending: DispatchWorkItem?

    /// - Parameters:
    ///   - debounce: 防抖间隔，回调在最后一次事件后该间隔时触发（在内部队列上）
    public init(path: URL, debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) throws {
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else {
            throw WatcherError.cannotOpen(path: path.path, errno: errno)
        }
        let queue = DispatchQueue(label: "lightty.path-watcher")
        self.queue = queue
        self.debounce = debounce
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link, .attrib],
            queue: queue
        )
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            self?.schedule(onChange)
        }
        source.resume()
    }

    deinit {
        cancel()
    }

    public func cancel() {
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
        if !source.isCancelled {
            source.cancel()
        }
    }

    private func schedule(_ onChange: @escaping () -> Void) {
        let item = DispatchWorkItem(block: onChange)
        lock.lock()
        pending?.cancel()
        pending = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}

extension PathWatcher {
    /// 生产变更源：凭据就是监听器本身，释放即 `cancel`。
    public static let changeSource: PathChangeSource = { path, onChange in
        try PathWatcher(path: path, onChange: onChange)
    }
}
