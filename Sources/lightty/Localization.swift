import Foundation

/// UI 文案本地化：英文为键（查表失败回退键本身），zh-Hans 提供中文。
/// 语言跟随系统偏好。
///
/// 边界：handoff 文档协议文本（lightty-hook 注入指令、`## Next steps` 等节头及其
/// summarize 解析）**不走本地化**——那是跨会话的数据格式，协议语言固定为英文，
/// 与界面语言无关；混入界面语言会让不同语言环境写出互不兼容的任务文件。
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}
