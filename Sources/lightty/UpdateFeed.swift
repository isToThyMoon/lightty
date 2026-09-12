import Foundation
import Sparkle

/// 更新源的运行期选择：把通用包迁到单架构包。
///
/// 分架构发包之前装好的 app，`SUFeedURL` 写死在 Info.plist 里指向 `appcast.xml`，
/// 那条源只能供通用包——它得两种机器都跑得起来。代价是 Claude 会话助手里那两份
/// Node 运行时（各约 110MB）会一直留在硬盘上，本机永远只用得上其中一份。
///
/// 这里在每次检查更新时按**正在运行的那一片**改指到单架构源，于是下一次更新就换成
/// 单架构包，多出来的那份运行时随之消失。通用二进制里 arm64 片和 x86_64 片各自编译，
/// `#if arch` 在运行的那一片上就是正确答案。
///
/// 单架构包自己的 `SUFeedURL` 已经指向单架构源，算出来是同一个地址，等于没动。
/// 地址不在这里拼，只替换文件名：主机与路径只有打包脚本一处来源。
final class UpdateFeed: NSObject, SPUUpdaterDelegate {
    /// 本机架构对应的口味，与打包脚本的 FLAVOR 同名。
    static var flavor: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    /// 通用源 → 本机架构的源。已经是单架构源（或不是我们认得的地址）时返回 nil，
    /// 由 Info.plist 里的地址生效。
    static func feed(replacing configured: String?, flavor: String = UpdateFeed.flavor) -> String? {
        guard let configured, configured.hasSuffix("/appcast.xml") else { return nil }
        return configured.replacingOccurrences(
            of: "/appcast.xml", with: "/appcast-\(flavor).xml")
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.feed(replacing: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
    }
}
