import Darwin
import Dispatch
import Foundation

/// 任务目录变更监听：DispatchSource + 防抖。
/// 只监听目录级事件（条目增删改名）；文件内容原地修改不触发——
/// 但按规范所有写入都走临时文件 + rename，天然产生目录事件。
public final class TaskFolderWatcher {
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
    public init(directory: URL, debounce: TimeInterval = 0.2, onChange: @escaping () -> Void) throws {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            throw WatcherError.cannotOpen(path: directory.path, errno: errno)
        }
        let queue = DispatchQueue(label: "lightty.task-folder-watcher")
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
