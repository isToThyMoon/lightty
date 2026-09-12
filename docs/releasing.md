# 发布流程

## 发布入口与版本

正式发布由 [release.yml](../.github/workflows/release.yml) 执行，打包实现见 [package-app.sh](../scripts/package-app.sh)。推送 `v*` tag 会创建 GitHub Release，并上传三种口味的 DMG、各自的增量包和对应的 Sparkle feed。

## 三种口味与三条更新源

应用解包 317MB，其中 264MB 是 Claude 会话助手（两份 Node 运行时 218MB + node_modules 46MB），
用户只用得上其中一份运行时。所以按机器分包：

| 口味 | DMG | 更新源 | 给谁 |
| --- | --- | --- | --- |
| `arm64` | `lightty-<版本>-arm64.dmg`（约 77MB） | `appcast-arm64.xml` | Apple Silicon 新安装 |
| `x64` | `lightty-<版本>-x64.dmg` | `appcast-x64.xml` | Intel 新安装 |
| `universal` | `lightty-<版本>-universal.dmg`（约 150MB） | `appcast.xml` | 分架构之前装好的那些 app |

universal 必须一直出：那些 app 的 `SUFeedURL` 写死在 Info.plist 里指向 `appcast.xml`，
这条源只能提供两种机器都能跑的包。换成单架构包，Intel 用户会因为
`sparkle:hardwareRequirements` 被过滤掉而静默停在旧版本。
Sparkle 的一条 feed 里一个版本只能有一条记录（generate_appcast 直接拒绝重复版本），
所以三种口味必须是三条 feed，不能合并。

## 增量更新

版本之间变的只有主程序，Node 运行时和 node_modules 一个字节都不动。
[build-appcast.sh](../scripts/build-appcast.sh) 把最近两个同口味的历史包拉下来交给
Sparkle 的 `generate_appcast`，生成 `.delta` 并写进 feed。实测 v0.13.11 → v0.13.12
的增量包 1.2MB，全量 150MB。用户装的版本对不上任何一条增量时，Sparkle 自动退回整包。

增量包文件名只带版本号，三种口味会撞名，而 GitHub 的资产名是平的一层，
所以脚本改名后同步改 feed 里的 URL——签名签的是内容不是文件名，改名不影响验签。

- 修复使用补丁版本，新功能使用次版本；发布前核对远端 tag 和 Releases，不能覆盖已发布 tag。
- `main` 推送也构建打包、填充内核缓存，但不创建 Release；其构建版本为 `0.0.0-ci`。
- 应用版本取 tag 去掉 `v`，build number 取 `git rev-list --count HEAD`。正式发布沿 main 前进，保持 build number 递增。
- 手动运行 workflow 不等于正式发布；只有 tag ref 执行 Release 和 appcast 步骤。

## 发布前检查

在仓库根目录执行：

```sh
git status --short --branch
git fetch origin --tags
git log --oneline origin/main..HEAD
gh release list --limit 5
git diff --check
swift test
```

确认变更范围，提交本次要发布的代码、测试和文档；不纳入临时文件、用户配置、构建目录或凭据。测试通过后才能打 tag。默认跳过的 socket 压测应在交付中说明；需要时通过 `LIGHTTY_LOAD_TEST=1 swift test --filter PaneStatusLoadTests` 单独运行。

涉及会话恢复时，另行手动验证 Claude Code / Codex CLI 的恢复、已打开会话跳转和退出重启；自动测试不替代真实 CLI 冒烟。不要为验证修改用户的 Agent 配置、删除锁或终止外部会话。

## 打 tag 并推送

将下方示例版本替换为本次的新版本，确认 main 工作区干净后执行：

```sh
git tag -a v0.6.1 -m "v0.6.1: 会话恢复可靠性修复"
git push --atomic origin main refs/tags/v0.6.1
```

原子推送保证分支和 tag 一起更新；遇到远端更新导致拒绝时，先检查差异，不强推。不要批量推送其他本地 tag。

## CI 构建与签名

流水线依次完成：

1. 拉取应用和 `isToThyMoon/ghostty` 的 `lightty-patches` 内核分支，按内核 commit 读取缓存；未命中时构建内核。
2. 同步 GhosttyKit，准备锁定版本的 Claude 元数据 SDK helper 和两种架构 Node runtime，构建 universal Release 应用。
3. 按三种口味各打一次 `.app`：单架构口味 `lipo -thin` 主程序并只带对应的 Node 运行时；签名嵌入组件及应用、生成 DMG。
4. 按凭据配置执行公证和 staple。
5. 拉取历史包，用 Sparkle 私钥生成三条带增量的 feed。
6. 创建 GitHub Release 并上传三份整包、增量包和三条 feed。

所需 GitHub Actions secrets（只写名称，禁止在文档或日志中记录值）：

| 用途 | Secrets | 缺失时 |
| --- | --- | --- |
| Developer ID 签名 | `MACOS_CERT_P12`、`MACOS_CERT_PASSWORD` | 跳过证书导入，打包可能退回 ad-hoc；不能宣称 Developer ID 签名 |
| Sparkle 更新签名 | `SPARKLE_ED_PRIVATE_KEY` | 正式发布的更新签名不能正常完成；这是发布必需项 |
| Apple 公证 | `NOTARY_APPLE_ID`、`NOTARY_TEAM_ID`、`NOTARY_PASSWORD` | 未设置 Apple ID 时跳过；部分配置缺失可能失败 |

目前发布说明模板写的是“已签名但未公证”；每次必须以实际步骤结果为准。
公证已排在 feed 生成之前：`stapler` 会把票据写进 DMG 改变内容，签名必须在那之后算，
否则 Sparkle 校验不过。启用公证时同步修改安装说明。

## 验收发布结果

```sh
gh run list --workflow release.yml --limit 5
gh run view RUN_ID
gh release view v0.6.1 --json url,isDraft,isPrerelease,assets
git status --short --branch
```

选择 **tag 对应的 run**，不要把 main 构建成功当成发布成功。确认：

- tag run 成功，Release 不是 draft / prerelease（除非本次明确要求预发布）。
- 三份整包（`-arm64` / `-x64` / `-universal`）和三条 feed（`appcast.xml`、`appcast-arm64.xml`、`appcast-x64.xml`）都在且非空。
- 每条 feed 的版本、下载地址、长度与对应的包一致，且 enclosure 带 `sparkle:edSignature`（脚本会在缺签名时直接失败）。
- 有历史包可比对时，feed 里应出现 `<sparkle:deltas>`，且增量包资产名带口味前缀。
- 签名步骤成功，公证状态如实说明；不能将 skipped 当作成功。
- 本地 main 与远端一致，工作区无意外残留。

需要安装验收时，从该 Release 下载 DMG，检查应用版本、两种架构及签名，再进行冒烟；不要擅自替换用户正在运行的应用。最终交付附 Release 链接、版本、测试结果和签名／公证状态。

## 失败处理与本地打包

先查看 `gh run view RUN_ID --log-failed`。临时网络问题可重跑失败 job；代码或打包问题应修复后提交并使用新 tag，不移动已经推送的发布 tag。若 Release 已部分创建，先核对现有附件，不直接删除或覆盖线上资产。

本地已具备内核产物、Swift 工具链和 Node/npm 时，可运行：

```sh
MAKE_DMG=1 scripts/package-app.sh 0.6.1
```

输出到 `dist/`，脚本会重建该目录内的 `lightty.app`。本地打包不会创建 GitHub Release，也不负责公证或生成 Sparkle appcast；默认优先使用本机 Developer ID，没有时使用 ad-hoc。
