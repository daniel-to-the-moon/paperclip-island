# Paperclip Island 独立设计评审

**结论：`pass_with_limits`，仅限设计层。** 初版为 `changes_required`；首轮 8 项及增量 2 项已在最终字节中得到设计修正，本次未发现仍开放的 P0/P1/P2 阻断。可以将此版本交用户审批，不等于用户已批准，更不等于客户端实现、编译或验收通过。

- 评审人：`/root/review_island_acceptance`
- 评审时间：2026-11-02 14:39 UTC
- 被审版本：`paperclip-island-m0-spec-v0.1.2-draft`，证据 schema `1.0.1`
- 独立性：未编写或修改 SPEC、ACCEPTANCE、schema、作者响应、门禁登记或产品实现；只读审阅后给出问题，修订由作者完成。本评审文件由 reviewer 单独创建。
- 范围：状态机、乱序/缺口、断线恢复、失败提醒去重、多屏/焦点要求、授权/协作边界和证据门禁；非产品代码评审。

## 精确绑定

| 文件 | SHA-256 |
| --- | --- |
| SPEC.md | `3013a59f43f5efcb8349a3b0d37026a87ef9ca7bc3dc99290ddba820639214cc` |
| ACCEPTANCE.md | `c66ecb2963aacabd274d839421353ec2cb8074b54e8f2faa2de0cd35b8a241c2` |
| EVIDENCE.schema.json | `9528d4d5fbe2dc0662a4af755beb1f6a0e0e8dd672e1a5d42b1b6d390ee879cc` |
| REVIEW_MANIFEST.json（评审时冻结快照） | `78b49605520e1e1ddf2715b3007f187d0310943265086f739bbe59a1a5a382ec` |
| v0.1.1-to-v0.1.2.diff | `1e9ee51be800ad161bd776747bb841b101376de65a7d302c9114fca2a16472ee` |

无产品仓库、源码 commit 或构建产物可绑定；不填写虚构 Git SHA。此报告引用冻结 manifest，不修改它，也不声称被该旧 manifest 收录。后续登记评审结论须保留本快照及本报告，不能倒写作者当时尚未取得的评审状态。

## 问题闭环（设计修正，不是实现测试）

| 项 | 风险与修正 | 结论 |
| --- | --- | --- |
| R1 | heartbeat/迟到事件原可绕过 baseline 恢复 online；现需当前 generation 有效 baseline 和完整同步资格 | 设计已关闭；ST17/ST22 |
| R2 | 全局乱序会漏掉其他任务更新；现定义连续序号、baseline 水位、缺口隔离及同序号异载荷冲突 | 设计已关闭；ST06/ST21 |
| R3 | offline 与 stale 定时器、睡眠恢复优先级不明；现 offline 不被计时器复活，唤醒重新同步 | 设计已关闭；ST14/ST22/ST24 |
| R4 | sink pending 期间可能重复投递；现串行/原子 reserved 先于投递，旧 completion 需 generation/token 隔离 | 设计已关闭；NT09 |
| R5 | unknown 和更高 attempt 转换缺项；现完整 4×4 表、attempt 优先级及冲突锁清楚 | 设计已关闭；ST23 |
| R6 | 同 commit 的 dirty 源码可能审测不一，schema 绿可掩盖失败；现最终只接 clean source，必需项/身份/hash 需独立 fail-closed 语义核验 | 设计已关闭；ACCEPTANCE §5/9、schema |
| R7 | 仅设计批准难以编码，正文 gate 可能在 schema 中消失；现独立 design_approval scope、明确 refs 语义与完整 gate register 映射 | 设计已关闭；ACCEPTANCE §9 |
| R8 | hover/点击/Esc 焦点要求混淆；现 hover 不取 key，明确点击可聚焦，非 key 不偷 Esc，热插拔/负坐标另验 | 设计已关闭；UI01/UI02 |
| R9 | 新 generation 仍可能接到旧 baseline；现跨 generation 保留同 source/epoch 高水位，拒绝旧或同水位矛盾快照，允许同水位一致恢复 | 设计已关闭；ST25 |
| R10 | clean 要求原误禁正常生成产物；现严格限定输入源码，独立输出区 .app/日志/截图可按 hash 绑定 | 设计已关闭；ACCEPTANCE §5 |

原始权限边界保留：M0 仅虚构数据、只读、无真实 API/凭据/系统通知授权/后台安装；M1 另批；不影响 `van-sticker-studio`。claim、文件/语义锁、有限修正、uncertain 先对账及停止保全交接已有明确规则。用户保留设计、范围、运行、合并、发布、权限和费用决定。

## 实际完成的独立检查

本地已有 Python/jsonschema，未安装依赖。以下只检查文档，最终核验命令退出码为 0：

1. 直接读取初版正文/schema，审阅两次修订的实际 diff；不是只读作者摘要。
2. 对 v0.1.1 与最终 v0.1.2 的 manifest 全部 7 项分别重算文件大小和 SHA-256，均匹配。
3. 从保存的前版文件用 `difflib.unified_diff` 独立重建两轮 diff，均与所交 UTF-8 原始字节完全一致。
4. `jsonschema.Draft202012Validator.check_schema` 通过；最终 schema 与已审 v0.1.1 字节相同。
5. 独立合成 schema 片段检查：clean 输入允许、dirty 输入拒绝；mock gate 的混合 pass/fail 拒绝。合成数据不是证据实例或产品 fixture。
6. 最终验收表共 49 个唯一 ID：ST25、NT9、LK4、UI5、SEC4、RES2；数量只证明表项存在，不证明执行通过。

## 限制与不能放行的事项

- **未运行**完整证据实例校验、产品逻辑 fixture、macOS 编译/启动、多屏焦点/资源/退出检查、Intel/ARM 实机、签名验证、截图、系统通知或真实接口；它们仍是 `not_run`/未授权，不能因本报告转绿。
- schema 验证不能证明执行真实性或权限来源；正式产品包仍必须有具名独立语义核验，且与精确 clean source/产物一致。
- 本进程内去重/水位不等于跨进程持久保证；已在 M0 范围中明示，不据此宣传真实 Paperclip 可靠性。M1 必须另核实际后端契约与可达安全入口。
- 未重新检验 Douding 安装包、此前后端实验或原始用户会话；这些历史事实来自父协调者/作者提供的上下文，不是本次独立产品实验结论。
- 当前 manifest/gate register 的 pending/blocked 是评审前冻结快照。可追加引用此报告记录设计审查结果；G2 用户设计批准及产品/发布门禁不会被自动满足。任何规范性新字节需重新绑定并复核。

## 已核对的官方语义

- 相同通知 identifier 对已送达通知仍可能再次提醒，故不能替代应用级去重：[Apple UNNotificationRequest](https://developer.apple.com/documentation/usernotifications/unnotificationrequest/init(identifier:content:trigger:)?language=objc)。
- 主屏与键盘焦点屏并非同一概念，屏幕数组不应缓存：[Apple NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens?language=objc)。
- `visibleFrame` 随 UI 设置变化，不应长期缓存：[Apple NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)。

这些资料支持设计约束，不证明本客户端已实现对应行为。
