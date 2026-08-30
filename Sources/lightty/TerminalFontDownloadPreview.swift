import Foundation

/// 字体下载 UI 的纯内存预览驱动器。
///
/// 它只按时间发送生产下载器同形的 phase，不持有 URL、文件路径或字体管理器，
/// 因而预览和取消都不可能产生网络请求或磁盘残留。
final class TerminalFontDownloadPreview {
    private let queue: DispatchQueue
    private let stepDelay: TimeInterval
    private var workItems: [DispatchWorkItem] = []
    private var completion: ((Result<Void, Error>) -> Void)?

    private(set) var isRunning = false

    init(queue: DispatchQueue = .main, stepDelay: TimeInterval = 0.18) {
        self.queue = queue
        self.stepDelay = stepDelay
    }

    func start(
        progress: @escaping (TerminalFontDownloadPhase) -> Void,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !isRunning else {
            completion(.failure(TerminalFontDownloadError.alreadyDownloading))
            return
        }

        isRunning = true
        self.completion = completion
        progress(.downloading(0))

        let fractions = [0.16, 0.38, 0.63, 0.84, 1.0]
        for (index, fraction) in fractions.enumerated() {
            schedule(after: stepDelay * Double(index + 1)) {
                progress(.downloading(fraction))
            }
        }
        schedule(after: stepDelay * Double(fractions.count + 1)) {
            progress(.installing)
        }
        schedule(after: stepDelay * Double(fractions.count + 3)) { [weak self] in
            self?.finish(.success(()))
        }
    }

    func cancel() {
        guard isRunning else { return }
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        finish(.failure(TerminalFontDownloadError.cancelled))
    }

    private func schedule(after delay: TimeInterval, action: @escaping () -> Void) {
        let item = DispatchWorkItem { [weak self] in
            guard self?.isRunning == true else { return }
            action()
        }
        workItems.append(item)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard isRunning else { return }
        isRunning = false
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}
