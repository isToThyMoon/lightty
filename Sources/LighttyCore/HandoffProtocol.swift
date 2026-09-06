import Foundation

/// 交接协议：lightty 代替用户对 Agent 说的那套话——全 app 唯一一份。
///
/// 四处取自这里，且写作规矩逐字相同：
///
/// 1. hook 在 SessionStart / UserPromptSubmit 注入（`lightty-hook`）
/// 2. 插件里那份 `SKILL.md`（`HookMarketplace`）
/// 3. 插件没装时按钮敲进终端的整段指令（`directInstruction`）
/// 4. 设置页的 Handoff 栏（只读展示）
///
/// 这张清单漏一项，就是这个文件本身要防的那种漂移——新增取用点必须写进来。
///
/// 为什么必须是一份：设置页展示的要是一份副本，它迟早跟真正注入的对不上，
/// 而这种不一致最难被发现——用户照着设置页读，agent 收到的却是别的。
///
/// **固定英文**，不走本地化：这是跨会话的数据格式协议，与界面语言无关。
/// 混入界面语言会让不同语言环境的用户写出互不兼容的任务文件
/// （同 `Sources/lightty/Localization.swift` 的边界说明）。
///
/// 文本分两层，改动时请分清：
///
/// - **机械契约**（`updateRules`）没有弹性。违反了就是坏数据：写错路径、动了
///   frontmatter、非原子写被监听器读到半截。模型再强也不会写出更好的 `rename(2)`。
/// - **写作规矩**（`writingRules`）是目标不是规则，随模型变强而变好。这一层
///   刻意不给模板：约束越多，模型越会为了填栏目而填，空栏目里的废话会被
///   下一段会话当成信号读。
public enum HandoffProtocol {
    /// 插件里技能目录的名字，同时也是调用名的后半截。
    public static let skillName = "handoff"

    /// 机械契约。四处逐字相同，只有写回目标的说法不同——能当场给出绝对路径的
    /// 就给绝对路径，技能是静态文件、渲染时拿不到路径，只能说"目标"。
    ///
    /// 临时文件那条的"以点开头"不是讲究：任务扫描按
    /// `!name.hasPrefix(".") && name.hasSuffix(".md")` 收文件（见 `TaskStore.list`），
    /// 一个叫 `tmp.md` 的临时文件会被当成一个新任务收进侧栏；写到一半失败还会
    /// 永久留在那儿。
    static func updateRules(target: String) -> String {
        """
        - Rewrite only the body after the closing `---` of the frontmatter.
        - Refresh `updated`. Leave every other frontmatter key unchanged.
        - Write a temp file in the same directory, named with a leading dot,
          then mv it over \(target).
        """
    }

    /// 写作规矩。两个锚点是有理由的，其余一律不进这里：
    ///
    /// - `## Next steps` 留着是因为**有程序在读**（`LaunchComposer.summarize`）
    /// - `## Suggested commands & skills` 留着是因为**模型稳定会漏**——总结时
    ///   往"我做了什么"偏，"你接手会需要什么"最先被挤掉
    ///
    /// "which commands or skills do it"里技能名只是途径：任务文件的 `sessions`
    /// 允许 claude 和 codex 并存，而两家的技能库是分开的，光写名字对换了一家的
    /// 接手者是条死线索。
    ///
    /// 全部用正面陈述，不用禁令：禁令会把被禁的行为拽进上下文，反而更容易发生。
    ///
    /// **只有这两个节头，别的一个都不给。** 曾经给过一行"常见的分法"（Current
    /// state / Key decisions & constraints / Blockers & risks），2026-09-09 删掉。
    ///
    /// 理由不是那三个可有可无，是**给了会让输出更差**：给了栏目模型就会填，那正是
    /// 栏目的作用；没内容的栏目会被填成「Blockers & risks：目前没有」，而这行字进了
    /// 下一段会话的上下文是被当信号读的。更隐蔽的一层是，栏目在模型知道什么重要
    /// 之前就把思考切好了块，而交接文档的价值恰恰在「判断下一个人需要什么」——
    /// 那正是模板会抢走的判断。
    ///
    /// 判据由此而来：**只要求模型会做错的东西**。会漏掉该用什么工具、会把密钥抄
    /// 进去、会把已有产物复制一遍——这几件要说；怎么组织文章，它自己办得到。
    ///
    /// "Write down what the user told you..." 补的是同一判据下的一个缺口：用户在
    /// 对话里给的操作性常识（"用 odps 查 MaxCompute 的表"这类）不在任何产物里，
    /// 上一条"引用不复制"帮不上它，粗读还可能被理解成"没出处的别写"；它又不像
    /// "做过的事"，总结时不在模型偏向的那条线上；而且到写交接的时候，那个工具对
    /// 这段会话已经是常识了，常识不会被特意写下来。三样叠在一起，稳定会丢。
    ///
    /// 已知的代价：新任务正文是空的，第一次写没有形状可继承，于是不同任务写出来
    /// 长得不一样。拿这个换掉"每个任务里都有几行填出来的废话"是划算的。真发现
    /// 写散了，任务气泡里看得见，那时再加也是有依据地加。规范文档里仍然记着那三个，
    /// 那是给人看的，不进这里。
    public static let writingRules = """
        Write for an agent picking this up cold:
        - Reference commits, paths and URLs instead of their content.
        - Write down what the user told you that is recorded nowhere else:
          tools, access paths, conventions, constraints.
        - Redact secrets and personal data.
        - Keep only what serves the next session.
        - Lead with `## Next steps`.
        - Include `## Suggested commands & skills`: what the next session
          needs to do, and which commands or skills do it.
        """

    /// 注入给 agent 的全文。`body` 是任务文件**全文**（含 frontmatter）：
    /// "只重写 frontmatter 结束的 `---` 之后"这条指令得让 agent 对着实物看，
    /// 否则它引用的是一个看不见的东西。
    ///
    /// - Parameter lateBinding: 开场（`SessionStart`）还是中途绑定
    ///   （`UserPromptSubmit`）。两版差别只在开头两段，理由见 `opening`。
    public static func injection(path: String, body: String, lateBinding: Bool) -> String {
        """
        \(opening(path: path, lateBinding: lateBinding))

        When asked to update it:
        \(updateRules(target: "`\(path)`"))

        \(writingRules)

        If you complete a substantial piece of work, ask once whether to update.

        ----- BEGIN HANDOFF DOCUMENT -----
        \(body)
        ----- END HANDOFF DOCUMENT -----
        """
    }

    /// 两个时机的处境不同，说法也得不同。
    ///
    /// 开场时上下文是空的，可以直接把文档摆上来。中途绑定时 agent 可能已经干了
    /// 半天别的事，而且这段文字是**跟用户这一轮的话一起送进去的**——所以要交代
    /// 优先级（用户当前那句话在前），也要交代取代关系（改名会换路径，同一份文档
    /// 的两个版本会先后进同一段上下文）。
    private static func opening(path: String, lateBinding: Bool) -> String {
        guard lateBinding else {
            return """
                This terminal pane is bound to a lightty handoff task. The document \
                below is that task's running record, kept at `\(path)`.

                Start from `## Next steps`. The rest records work already done.
                """
        }
        return """
            This terminal pane has just been bound to a lightty handoff task, or \
            its binding changed. The document below is that task's running record, \
            kept at `\(path)`, and replaces any earlier copy in this conversation.

            Handle the user's current request first. Use this as background, and \
            read `## Next steps` before continuing the task.
            """
    }

    /// 插件里那份 `SKILL.md` 的全文，两家共用一份。
    ///
    /// 刻意**不写** `disable-model-invocation`：
    ///
    /// - 那是 Claude Code 专有字段，作用是切断"模型读懂用户意图后自己调用"。
    ///   用户说"帮我总结下 handoff"正是这条路，切断它等于逼用户记住显式调用写法。
    /// - Codex 完全忽略这个字段，它的对应物在 `agents/openai.yaml` 里；而且
    ///   Codex 的插件校验器要求插件自带技能的这个字段不能是 true。
    ///
    /// 两条合起来：不写这个键，两家都是允许模型调用，一份文件通吃。
    ///
    /// `description` 是个每轮都在上下文里的指针，比正文剪得更狠：同一件事的
    /// 多种说法不重复列（"summarize/update/write" × "handoff/task record/
    /// task document" 是一个分支写九遍）。`task` 不单列，它已经在宾语里。
    /// 它必须**单行**：折行的 YAML 标量虽然合法，但两家 CLI 的 frontmatter
    /// 解析器是不是都按 YAML 折行，没验过；单行一个字都不多花。
    public static let skillDocument = """
        ---
        name: \(skillName)
        description: Update or summarize the handoff document for the lightty task bound to this terminal.
        ---

        Rewrite the handoff document for the task bound to this terminal.

        Use the absolute path passed with this invocation. Without one, use the
        path on the first line of `~/.lightty/panes/$LIGHTTY_PANE_ID/task`. If
        that file is missing too, stop and say so.

        \(updateRules(target: "the target"))

        \(writingRules)

        If the invocation says what the next session will focus on, tailor the
        document to it.

        """

    /// 各家调起这个技能的写法。**两家不一样**，实测：
    ///
    /// - Claude Code：`/<插件名>:<技能名>`
    /// - Codex：`$<插件名>:<技能名>`。那个 `$` 是 CLI 层的输入解析，不是写给
    ///   模型看的约定——纯文本粘进去也会展开，不需要走补全弹窗，正合我们
    ///   往 PTY 里敲字这条路。
    ///
    /// 两家都按**插件名**加前缀（不是 marketplace 名），裸技能名不生效。
    ///
    /// **名字写错、插件没装都是静默失败**：两家都不报错，什么都不会发生。
    /// 所以调这一支之前必须先确认插件装了，不能"敲了就当成了"。
    ///
    /// **按钮必须把路径带上。** 技能正文的第一选择是"用调用里传来的绝对路径"，
    /// 而不带路径时它只能去读 `~/.lightty/panes/$LIGHTTY_PANE_ID/task`——那条兜底
    /// 是为"用户自己敲"和"模型自然语言调起"准备的，按钮手里明明有路径，不发是白丢。
    ///
    /// `path` 传 nil 得到的是**给人看的裸写法**（设置页展示的就是它）：用户手敲
    /// 不需要背一长串路径，兜底会把它找回来。所以这个参数**没有默认值**——
    /// 带不带路径是两种不同的用途，必须在调用点写明白，不能靠忘了填来决定。
    ///
    /// 两家的技能调用后面都能跟自由文本参数（Codex 实测如此）。
    public static func skillInvocation(agent: SessionAgent, plugin: String, path: String?) -> String {
        let sigil = agent == .codex ? "$" : "/"
        let bare = "\(sigil)\(plugin):\(skillName)"
        guard let path else { return bare }
        return "\(bare) \(path)"
    }

    /// 插件没装时按钮敲进终端的整段指令。内容与技能正文同源，只是把"路径靠绑定
    /// 时给过"换成当场给出绝对路径——这条路不经过技能，没有那次绑定可依赖。
    public static func directInstruction(path: String) -> String {
        """
        Rewrite the handoff document for the lightty task bound to this terminal, \
        kept at `\(path)`.

        \(updateRules(target: "`\(path)`"))

        \(writingRules)
        """
    }
}
