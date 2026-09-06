import Foundation
import LighttyCore

/// 新终端里敲下去的第一行命令。
///
/// 全 app 只有这里决定「敲什么」：新建会话、handoff 启动任务、恢复会话、打开 CLI
/// 自己的选择器、重启后恢复 pane、让 agent 改会话名或重写交接文档——每个入口构造
/// 一个 case，而不是各自拼字符串。
/// 于是加入口只是多一个调用点，改行为（再加一个全局开关、换参数位置）只改这一个
/// 文件；`shellInput` 的 switch 必须穷尽，新增 case 会在编译期逼作者交代它敲什么。
///
/// 后两支（`rename`、`handoff`）与前几支性质不同：前几支是敲给 shell 的第一行
/// 命令，这两支是敲给一个**已经跑起来的 TUI**，所以都不带行尾换行，见各自注释。
enum AgentCommand {
    /// 只开终端，不启动 Agent。
    case none
    /// 起一段新会话：程序、bypass、附加参数全部取自当前设置。
    case start(LaunchAgent)
    /// 续接一段已存在的原生会话。
    case resume(SessionResumePlan)
    /// 打开 CLI 自带的会话选择器。
    case sessionPicker(SessionResumePlan)
    /// 让 agent 自己改当前会话的名字。
    ///
    /// lightty 不另存一份「用户改名」：标题的所有权在 agent 那边（claude 写
    /// `customTitle`，codex 写 thread title），我们再记一份必然会对不上。两家的
    /// `/rename` 都吃行内参数——claude 的命令表里写着 argumentHint `[name]`，
    /// codex 实测一行下去就回 "Session renamed to …"。
    ///
    /// 这条只用于「会话正开在某个 pane 里」。会话没开时走官方接口，见 `SessionRename`。
    case rename(String)
    /// 让 agent 按交接协议重写这个 pane 绑定的那份交接文档。
    ///
    /// 两条路，取决于我们的插件装没装：
    ///
    /// - 装了：敲技能调用。终端里只多一行，而且技能正文跟着插件版本走——
    ///   长会话把开场那次注入压缩掉了也不受影响。
    /// - 没装：把整段指令敲进去。它自带全部契约，不依赖注入、不依赖插件。
    ///
    /// 这一支必须知道是哪家 agent，因为**两家的技能调用写法不同**（claude 用
    /// `/`，codex 用 `$`）；`rename` 不需要，两家的 `/rename` 是一样的。翻译成
    /// 各家写法只发生在 `HandoffProtocol.skillInvocation`。
    ///
    /// `skillInstalled` 必须是**查过的事实**：调用名写错或插件没装，两家都是
    /// 静默失败——什么都不会发生，也没有任何报错可供我们发现。
    case handoff(agent: SessionAgent, path: String, skillInstalled: Bool)
    /// 任意一行 shell 文本。产品路径请用上面的 case——这一支不读设置，也不受
    /// bypass 开关影响；留给测试和与 Agent 无关的一次性命令。
    case shell(String)

    var shellInput: String? {
        switch self {
        case .none: return nil
        case .start(let agent): return AgentLaunchPreference.initialInput(for: agent)
        case .resume(let plan): return plan.shellInput
        case .sessionPicker(let plan): return plan.nativePickerInput
        case .rename(let name):
            // 一行一条命令：名字里的换行会把后面的部分变成发给模型的一句话。
            // 与官方接口那条路共用同一个清洗函数，否则同一个名字两条路会存成两个样子。
            guard let single = SessionRename.sanitize(name) else { return nil }
            // 唯一一支不带行尾的：上面几支是敲给 shell 的第一行命令，这一支是敲给
            // 一个已经跑起来的 TUI。注入文本走的是粘贴（见 `sendText`），粘进去的
            // 回车对开着括号粘贴模式的 TUI 只是插入一个换行，命令会原样停在输入框里。
            // 提交由 `PaneView.renameSession(to:)` 另外按一次回车键完成。
            return "/rename \(single)"
        case .handoff(let agent, let path, let skillInstalled):
            // 与 `rename` 同样不带行尾：粘进 TUI 的回车只是插入换行，不提交。
            // 提交由 `PaneView.updateHandoff()` 另外按一次回车键完成。
            // 没装插件那一支是多行的——多行粘贴在 TUI 里就是多行输入，同样停在
            // 输入框里等那一次回车。所以路径里万一有换行也拆不出第二条命令，
            // 不像 `rename` 那样需要先清洗成一行。
            return skillInstalled
                ? HandoffProtocol.skillInvocation(agent: agent, plugin: HookMarketplace.pluginName,
                                                  path: path)
                : HandoffProtocol.directInstruction(path: path)
        case .shell(let line): return line.hasSuffix("\n") ? line : line + "\n"
        }
    }
}

extension SessionResumePlan {
    /// 续接计划在应用侧的唯一入口：bypass 与附加参数取自当前设置，调用方不必也
    /// 无从自己拼。核心类型的初始化器没有给 `launchArguments` 默认值——漏传是编译
    /// 错误，而不是一条悄悄退回默认审批模式的命令。
    init(resuming session: AgentSession, executable: String,
         configuration: SessionConfigurationLocation, workingDirectory: String? = nil) throws {
        try self.init(session: session, executable: executable, configuration: configuration,
                      workingDirectory: workingDirectory,
                      launchArguments: AgentLaunchPreference.launchArguments(for: session.key.agent))
    }
}
