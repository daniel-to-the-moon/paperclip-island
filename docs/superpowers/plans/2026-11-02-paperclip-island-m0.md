# Paperclip Island M0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现独立、只读、离线虚构数据的 macOS 灵动岛原型，并用精确证据区分模拟逻辑通过与真正 Mac 验收。

**Architecture:** 纯 Swift 核心负责事件校验、双轴状态、去重和导航策略；SwiftUI 卡片由 AppKit NSPanel 承载，NSStatusItem 提供菜单备用入口。原生协调器串行驱动核心和模拟通知 sink；M0 不包含网络适配器、真实通知实现或持久后台。

**Tech Stack:** 提议 Swift tools 5.9 兼容模式、Swift Package Manager、Foundation、XCTest；macOS 侧 SwiftUI/AppKit。只用已存在工具链和系统框架，零第三方依赖、零插件、零工具下载；实际工具链版本须记录，不能由本计划假定已安装。

**Spec:** 仓库拟落点 `docs/superpowers/specs/2026-11-02-paperclip-island-v0.1.2/SPEC.md` 与同目录 `ACCEPTANCE.md`。当前真实来源 `/workspace/scratch/8f091ff4cc4d/paperclip-island-design-20261102/`；两者逐字复制，不重新排版。

## Global Constraints

- 设计版本 `paperclip-island-m0-spec-v0.1.2-draft` 已获用户 2026-11-02 14:53:14 UTC 批准；**本实施计划尚待用户审阅批准执行**。
- SPEC SHA-256 `3013a59f43f5efcb8349a3b0d37026a87ef9ca7bc3dc99290ddba820639214cc`；ACCEPTANCE SHA-256 `c66ecb2963aacabd274d839421353ec2cb8074b54e8f2faa2de0cd35b8a241c2`。
- 拟议最低系统为 macOS 14，目标架构为 x86_64 与 arm64；支持目标不是实测结论，两架构分别验收。
- `stale_after = 30 秒`（年龄达到 30 秒即 stale）；单调时钟计算年龄，墙钟仅显示。
- M0 只用虚构数据，持续显示“模拟数据”；真实原任务入口禁用，通知只使用模拟 sink。
- 无真实 API、HTTP/SSE/WebSocket/DNS、凭据/Keychain、聊天读取、真实通知授权、LaunchAgent、登录项、后台监听、全局快捷键或遥测。
- 不申请 Accessibility、录屏、自动化或完整磁盘访问；不安装工具、不清理磁盘、不强杀其它进程、不修改安全设置。
- 退出正常停止本应用计时器/订阅；无自动合并、自动发布、分发、签名公证或费用。
- 不修改 `van-sticker-studio`、Douding 或原 Paperclip 服务/数据库，不跨项目继承依赖/修复/发布权限。
- 最终验收输入必须是 clean committed source；构建、日志、截图等输出放独立输出区，逐项 hash 绑定，不要求提交二进制。

## Review Focus

以下五项已补到各任务测试；审查仍需留意组合情形，不能仅看单个绿色用例：

1. F1：同序号不同载荷、跨任务缺口及重连旧快照不能让旧任务重新 online——T2 `test_ST06_payloadConflict`、`test_ST21_gap`、`test_ST25_oldBaseline`。
2. F2：通知 sink 挂起时重复失败与重置后迟到 completion 不得重发或污染新世代——T3 `test_NT09_pendingAndLateCompletion`。
3. F3：睡眠、墙钟回拨、断线计时交错不能产生假新鲜度——T2 `test_ST19_wallClockJump`、`test_ST22_offlinePriority`、`test_ST24_wake`。
4. F4：负坐标外接屏断开与当前 App 焦点不同步时，hover 不抢焦点、非 key 不偷 Esc——T5 纯策略测试加 T6 真机 UI01/UI02/UI03。
5. F5：长 Unicode 标题、空摘要以及看似 URL 的文本不能执行导航或遮住状态——T4 `test_LK03_rejectedTargets`、T5/T6 UI04/UI05。

---

## 0 当前状态、审批与执行入口

计划版本：`paperclip-island-m0-plan-v0.1.0-review`。这是计划文档，不是产品代码或已执行记录。所有下列产品步骤初始均未勾选；TDD 命令是将来批准后的操作，不表示现在运行过。

主协调者已报告创建独立私有仓库 `https://github.com/shengjun89/paperclip-island`（repo id `1443101135`），当时 size 0、未初始化。本计划作者没有独立读远端或写仓库；执行前协调者须复核真实状态，不能假定仍为空。

批准证据另存 `docs/superpowers/AUTHORIZATION-2026-11-02-design-v0.1.2.md`（SHA `45dc90efb03396d7ef785aed486eb8a704ed9a93b50dc058d8fe145a0ca859e5`）。冻结规格中的旧 pending 状态是历史快照，不修改原字节；新增记录承接批准事实。

### 0.1 空仓库文档 bootstrap（根协调者负责，当前不执行）

空仓库没有可用 base，不能虚构 base SHA 或直接开有差异的正常 PR。建议顺序：

1. 只读核 owner/name、private、默认分支/refs、是否确实没有 commit，以及当时写入/分支保护权限。若有人已写入，停止空仓库路径，先核现有基线，不 force-push。
2. **需用户单独明确允许一次仅文档的初始基线写入默认分支**；创建仓库或批准设计不自动等于允许此写入。本方案不含产品代码，也不是后续直推 main 的通行证。若禁止 main 写入或没有批准，保持空仓库，请用户创建/指定基线；不能绕过保护或换工具强写。
3. 获准后建立一个只含仓库介绍和冻结设计目录的初始文档 commit；README 明确“设计已批准、实施计划待批准、App未实现”。核远端精确 commit/tree 为 `DOC_BASE`，此值此前为 null。
4. 从 `DOC_BASE` 建文档分支 `docs/m0-implementation-plan`，只加入本计划与授权记录，开 **Draft PR** 对照 `DOC_BASE`；不 merge、不设 auto-merge。上传/分支/PR 权限由协调者确认；未获准时仅交 Library 文件。
5. 用户看计划并批准实施后，另做唯一 owner 认领；产品变更走独立分支及 PR。最终合并仍须用户批准精确版本，不沿用文档 bootstrap 的例外。

建议冻结文档映射：把原目录所有 `.md/.json/.diff` 及 `review-baselines/` 保持相对结构原样放入 `docs/superpowers/specs/2026-11-02-paperclip-island-v0.1.2/`。只改变外层路径，不改文件内容；原 REVIEW_MANIFEST 的相对引用仍成立。不得把上传 ZIP、解析器、Library helper 或临时脚本混进仓库。

### 0.2 实施准入与锁

执行前派单包含：计划/spec/hash、repo、真实 base/head、任务 Tn、唯一 owner、允许文件、语义锁、执行器实际 OS、测试/输出区、许可及停止条件。需真实 accepted/run 证据，不能把派单或评论当运行。

推荐 **subagent-driven，逐任务串行写入、每任务独立只读评审**：核心状态和通知共享契约，不能同时改它们；每个任务可有新的实现者，但必须停止交接后才转移语义锁。超时/模型容量失败不抢锁；保存已落盘成果、hash、dirty 状态、活动进程和未决动作，先对账再接管。

本计划建议未来明确批准：一次同锁范围的确定性代码/测试缺陷修正与对应重验；初次 TDD 预期红灯不是故障修复额度，也不能故意把环境错误当红灯。权限/认证/控制冲突/资源不足/安装失败/uncertain 不适用普通修正额度。拒绝后仅因实质新证据且已确认原动作未执行/限制合法解决才最多再试一次；不绕工具或执行器。第二次确定性失败停下交接，不删断言、不无限循环。

### 0.3 环境与输出

- 云任务只在明确获授权的独立工作区写本项目；执行器若实际是 Mac，仍须相应 Mac 许可。名称叫“云”不改变命令落点。
- 批准后先只读查 `command -v swift`、`swift --version` 和测试命令帮助。没有可用 Swift 时，允许范围内完成源码/静态审阅，但相关测试 **blocked/not_run**；不安装、不下载、不用其它语言模拟结果冒充 Swift 通过。
- 测试命令以下采用 `swift test --scratch-path "$OUTPUT_DIR/swift-build" --filter <Suite>`；先验证已有 SwiftPM 支持该选项。`OUTPUT_DIR` 必须是已批准、独立且不作为源码输入的输出区，不是任意用户目录。
- Mac 构建/启动/截图是 T6 的另行授权门；须确认当前可用磁盘、输出限额、最小保留余量、运行窗口及已有 SDK。资源阈值在该次批准单冻结，未明确则 T6 blocked；不把此前低磁盘记忆当当前测量，不大下载或自动清理。

## 1 文件与接口地图（都是未来拟创建，当前没有创建）

| 归属 | 精确路径 | 单一职责 |
| --- | --- | --- |
| T1 | `Package.swift`, `.gitignore` | 零依赖核心及 XCTest；仅在 macOS 条件下声明 App target；忽略独立生成输出，不忽略输入源码 |
| T1 | `Sources/IslandCore/Domain.swift` | 状态、身份、事件、时间和结果值类型 |
| T1 | `Sources/IslandCore/EventDecoder.swift` | 内存 JSON 数据到事件的严格校验，无文件/网络读取 |
| T1 | `Tests/IslandCoreTests/EventDecoderTests.swift`, `TestFixtures.swift` | 虚构输入工厂和 malformed/baseline 测试 |
| T2 | `Sources/IslandCore/StateReducer.swift` | 单一同步 reducer，任务/连接、游标/水位、generation |
| T2 | `Tests/IslandCoreTests/StateReducerTests.swift` | ST01–ST25 全矩阵与注入时钟 |
| T3 | `Sources/IslandCore/FailureNotifier.swift` | 内存账本、reservation、模拟 sink 协议 |
| T3 | `Tests/IslandCoreTests/FailureNotifierTests.swift` | NT01–NT09 与可挂起 sink |
| T4 | `Sources/IslandCore/PresentationModel.swift`, `DetailPolicy.swift` | 稳定排序、纯文本、本地详情/禁用原任务 |
| T4 | `Tests/IslandCoreTests/PresentationTests.swift`, `DetailPolicyTests.swift` | LK01–LK04、文本/排序策略 |
| T5 | `Sources/IslandCore/WindowPolicy.swift`, `MockScenarios.swift` | 可测屏幕/焦点决策、编译内虚构场景；不加载外部资源 |
| T5 | `Tests/IslandCoreTests/WindowPolicyTests.swift`, `LifecycleTests.swift` | 纯窗口决策与关闭事件源 |
| T5 | `Sources/PaperclipIsland/PaperclipIslandEntry.swift`, `AppCoordinator.swift` | 原生入口与主线程串行协调器 |
| T5 | `Sources/PaperclipIsland/IslandPanelController.swift`, `MenuController.swift`, `IslandView.swift` | NSPanel、NSStatusItem、SwiftUI卡片及详情 |
| T6 | `Packaging/Info.plist`, `scripts/package-local-mock.sh` | 仅本地输出区 .app 装配；不安装、签名、联网或启动 |
| T6 | `docs/verification/MAC_CHECKLIST.md` | 真实 Mac 手动步骤及每架构结果入口 |
| T7 | `scripts/check-source-boundary.py`, `scripts/validate-evidence.py`, `Tests/Tooling/test_evidence_validation.py` | 已有Python标准库的有限输入/证据校验，不宣称扫描可证明无网络 |
| T7 | `docs/verification/EVIDENCE_INDEX.md`, `CURRENT_GATE_REGISTER.md` | 新的运行证据索引与门禁，不覆盖冻结历史 |

这些文件只允许各任务在正式执行获批后创建。`Package.swift` 第一次创建归 T1；T5 添加条件 App target，T6若需改manifest须取得该文件/语义锁。任何其它文件先说明必要性并获范围调整，不能“顺手”建 CI、发布脚本或依赖清单。

### 1.1 共用类型（T1 定义，之后不得随意改名）

- `TaskState: String`：running/succeeded/failed/unknown；`ConnectionState`：online/offline/stale。
- `TaskKey: Hashable`：sourceID、taskID；`AttemptKey: Hashable`：taskKey、attemptID。
- `TaskSnapshot`：key、attemptID、attemptOrdinal:Int64、revision:Int64、state、title、summary、sourceUpdatedAt:Date?。
- `Instant`：monotonicMilliseconds:Int64、wall:Date。时钟由调用者传入，不在 reducer 里读 Date.now。
- `Event`：baseline(sourceID,epoch,generation,watermark,tasks)、taskUpdate(sourceID,epoch,generation,sequence,task)、heartbeat(sourceID,epoch,generation,sequence)、connected(sourceID,generation)、disconnected(sourceID,generation)。来源序号只属于前三种；没有任务字段的 heartbeat 不借用 task ID。
- `TaskRecord`：snapshot、lastTaskUpdate:Instant、sourceConflict:Bool。
- `ClientState`：sourceID、generation:UInt64、connection、tasks:[TaskKey:TaskRecord]、lastSuccess:Instant?、synchronized:Bool；内部水位/已见事件摘要不由 UI 写入。
- `Transition`：state:ClientState、baselineObservedFailures:Set<AttemptKey>、newFailureCandidates:[TaskRecord]、diagnostics:[DiagnosticCode]。baseline 与 live failure 区分，unknown 不派发候选。
- `DiagnosticCode` 为有限枚举（invalidInput/sequenceGap/payloadConflict/attemptConflict/oldBaseline/oldGeneration）；不放业务正文、私人路径或任意原始 payload。

## Task 1: 严格数据契约与无依赖测试入口

**Files:** 创建地图中 T1 文件；不创建 App target 或原生资源。

**Interfaces:** `EventDecoder.decode(_ data: Data, generation: UInt64, receivedAt: Instant) throws -> Event`；`Fixture.baseline(sequence: Int64, generation: UInt64, tasks: [TaskSnapshot]) -> Event`、`Fixture.task(state: TaskState, revision: Int64, attempt: String, ordinal: Int64) -> TaskSnapshot` 仅测试使用。decoder 的 receivedAt 不信任输入自报时间，源枚举未知必须失败。

- [ ] 写 `EventDecoderTests`：`testMissingID`、`testUnknownState`、`testNegativeSequence` 均 `XCTAssertThrowsError`；`testConflictingBaseline` 整体拒绝；`testHeartbeatHasNoTaskFields` 能解析合法heartbeat但不伪造task；`testReceiptTimeIsLocal` 不接受来源“现在”替代传入时间。
- [ ] 创建最小零依赖 Package 与测试目标后运行 `swift test --scratch-path "$OUTPUT_DIR/swift-build" --filter EventDecoderTests`，记录真实 red：目标类型/实现尚不存在或断言未满足。工具链缺失记 blocked，不算 red。
- [ ] 在 Domain/EventDecoder 实现上述接口与按kind必填校验；整数使用 Int64，拒绝溢出/负值；只解析内存虚构数据。Package macOS deployment 14.0，依赖为空，无 plugins。
- [ ] 重跑同命令，所有测试通过才记录该任务逻辑结果；核 Package 没有远程依赖、安装命令和真实数据。
- [ ] 独立 reviewer 核 exact diff/测试日志后提交本任务明确文件，建议 commit `feat(core): define validated mock event contract`；提交不是 merge。交接核心契约锁给 T2。

## Task 2: 双轴 reducer、完整转换与顺序新鲜度

**Files:** 创建 StateReducer.swift/StateReducerTests.swift；必要 TestFixtures 增补需同锁声明，不改冻结spec。

**Interfaces:** `StateReducer.init(sourceID: String, generation: UInt64 = 0, staleAfterMilliseconds: Int64 = 30_000)`；`mutating apply(_ event: Event, now: Instant) -> Transition`；`mutating tick(now: Instant) -> Transition`；`mutating wake(newGeneration: UInt64, now: Instant) -> Transition`。`state` 对外只读；新的generation不清 source/epoch 高水位。合法epoch切换需baseline；不实现请求重试或重排缓冲。

- [ ] 按第2节映射写 `test_ST01_...` 至 `test_ST25_...`，用人工Instant，无 sleep。关键断言：29,999ms online、30,000ms stale；断线再tick仍offline；seq10后12不应用且stale；重连baseline10不能覆盖已接受21；同水位一致可恢复、矛盾拒绝。
- [ ] 运行 `swift test --scratch-path "$OUTPUT_DIR/swift-build" --filter StateReducerTests`，保存红灯断言，不把编译器环境错误当业务回归。
- [ ] 实现 generation→连续性→attempt→同尝试4×4优先级。新generation旧回调丢弃；同seq不同源字段冲突；连续seq的旧revision消耗游标但不刷新任务时间。终态冲突锁到新baseline/更高合法attempt；空baseline不推导成功。
- [ ] 重跑全部 StateReducerTests 和 EventDecoderTests；增加两个源同taskID隔离、整数边界及被拒输入不污染水位的断言。状态冲突若暴露spec矛盾，停在设计澄清，不自改规则。
- [ ] 独评 precise diff/ST覆盖，提交 `feat(core): implement ordered dual-axis state reducer`；交接通知输入契约，保留失败/缺项。

## Task 3: 原子失败账本与模拟提醒

**Files:** 创建 FailureNotifier.swift/FailureNotifierTests.swift；不得导入 UserNotifications。

**Interfaces:** `NotificationPermission`=notDetermined/authorized/denied；`DeliveryOutcome`=delivered/failed/uncertain；`DeliveryToken` 含 generation 与唯一序号。`@MainActor protocol MockNotificationSink { func submit(_ candidate: TaskRecord, token: DeliveryToken, completion: @escaping @MainActor (DeliveryToken, DeliveryOutcome) -> Void) }`。`@MainActor FailureNotifier.init(sink: any MockNotificationSink)`；`ingest(_ transition: Transition, permission: NotificationPermission)`；`resetDemo(generation: UInt64)`；`ledgerSnapshot` 只读测试视图。测试文件定义可控 `PendingMockSink`；原生 AppCoordinator 内定义只记录卡片提示的 `CardOnlyMockSink`，二者都不接系统通知。

- [ ] 写 NT01–NT09：authorized新失败 `submitCount == 1`；denied/notDetermined为0且suppressed；以后authorized不回放；同attempt详情更新不增加；新attempt可增加；pending期间重复仍1；reset后旧completion不能删新reservation。
- [ ] 运行 `swift test --scratch-path "$OUTPUT_DIR/swift-build" --filter FailureNotifierTests`，主actor测试明确等待挂起sink手动completion，不用现实延时碰碰运气。
- [ ] 在同一MainActor串行域内先reserved再submit；baseline failed只observe；fail/uncertain不自动重投；completion匹配token/generation只结束自己记录。账本仅内存，面板关闭不重置；进程重启靠baseline抑制历史。
- [ ] 重跑NT及T2全部测试，确认任何路径没有系统通知调用、权限读取或授权弹窗。NT08验证的是应用账本，不依赖系统identifier替换。
- [ ] 独评并提交 `feat(core): add reserved mock failure notifications`；保留REAL-NOTIFY未运行。

## Task 4: 只读呈现与安全详情入口

**Files:** 创建 T4 四个文件。

**Interfaces:** `PresentationModel.make(from state: ClientState) -> [TaskCard]`（TaskCard含TaskKey/attemptID/state/connection/title/summary/updateText）；`DetailPolicy.select(_ key: TaskKey, in state: ClientState) -> TaskRecord?`；`DetailPolicy.classifyTarget(_ raw: String?) -> DetailDecision`（disabled(reason)/rejected(reason)）。M0不存在真实openURL接口；测试marker只能记录“拟打开”，不得接NSWorkspace。

- [ ] 写 `DetailPolicyTests.test_LK01_localOnly` 至 `test_LK04_selectionIdentity`：本地详情绑定key+attempt；nil/不可达禁用；file/javascript/custom scheme/跨host/含凭据文本一律无导航；切任务不残留旧详情。
- [ ] 写 `PresentationTests.testStableOrderAndText`：running/failed/unknown/succeeded稳定排序，同组taskID；标题含HTML/URL仍纯文本；空摘要仍显示状态和时间，旧任务仍带offline/stale标签。
- [ ] 运行两组测试取得red，随后实现纯函数；不添加WebKit/浏览器嵌入、URL白名单联网探测或真实深链。
- [ ] 重跑两组与T2/T3；确认卡片展示“模拟数据”，原任务入口禁用原因可见，unknown/offline不变成成功。
- [ ] 独评并提交 `feat(core): add read-only cards and disabled remote details`。

## Task 5: macOS原生界面源码与可测窗口策略

**Files:** 创建地图T5文件；Modify `Package.swift` 仅增加 `#if os(macOS)` App executable target，Linux不编译SwiftUI/AppKit。不建Xcode工程、CI或依赖。

**Interfaces:** `WindowPolicy.chooseScreen(explicitID: String?, pointer: Point, screens: [ScreenDescriptor]) -> String?`；`placePanel(size: Size, screen: ScreenDescriptor) -> Rect`（保留负坐标，使用当前visibleFrame/scale）；`focusAction(for: Interaction, appHasFocus: Bool) -> FocusAction`。纯几何使用值类型：Point(x:Double,y:Double)、Size(width:Double,height:Double)、Rect(origin:Point,size:Size)、ScreenDescriptor(id:String,frame:Rect,visibleFrame:Rect,scale:Double,isPrimary:Bool)；不把NSScreen塞进核心。Interaction为hover/clickDetail/escape，FocusAction为none/focusLocalDetail/closeLocalDetail/ignore。`@MainActor AppCoordinator.startMock()`、`stop()`、`selectTask(_:)`；`MockScenarios.events(named: String) -> [Event]` 全部编译内虚构事件，无外部文件读取。

- [ ] 写 `WindowPolicyTests`：pointer screen/explicit screen消失/negative origin/scale change；hover动作不activate，clickDetail可聚焦，非key Esc返回ignore。写 `LifecycleTests.testStopCancelsFutureEvents`：stop后推进模拟时钟不再发事件、pending旧completion不能变视图。
- [ ] 云端有Swift时运行两组纯策略测试取red；没有工具链保持blocked。纯策略pass不等NSPanel实际行为通过。
- [ ] 实现纯策略与mock场景；再写原生入口/AppCoordinator/Panel/Menu/View：主actor串行调reducer和notifier，hover仅展开；点击详情可聚焦；菜单可显示/隐藏/选择屏幕/退出。无刘海屏也必须可从菜单呼出；订阅合法的屏幕变化/睡眠唤醒通知并重算，stop移除订阅；不使用全局事件tap。NSWorkspace若用于唤醒通知不等于允许openURL，导航仍禁用。
- [ ] 在具备且**已获批准**的Mac环境前不编译/启动原生target；云端仅静态检查其无网络、权限请求、登录项与真实通知调用。真实NSPanel/Space/焦点结果留给T6。
- [ ] 重跑可运行纯测试并独评原生源码；提交 `feat(app): add mock island panel and menu fallback`。若缺Mac证据，只报告源码已准备，不称T5原生交互已验收。

## Task 6: 另获批准后才做Mac构建、装配和真实交互

**Files:** 创建 Packaging/Info.plist、scripts/package-local-mock.sh、docs/verification/MAC_CHECKLIST.md；运行结果放批准的OUTPUT_DIR，不写用户Applications/Library。

**Interfaces:** `package-local-mock.sh <built-executable> <output-app-path>` 只把指定可执行文件及静态Info.plist装配成.app，不启动、不安装、不codesign、不改quarantine、不下载。目录必须不存在或由用户明确批准本次覆盖；遇已有成果默认停止。内部显示名 `Paperclip Island (Mock)`，本地测试bundle ID `local.paperclipisland.mock`，不冒充Douding发布者。

- [ ] 先取得明确Mac执行批准：设备/架构、既有工具链、独立输出区、磁盘余量/输出预算、允许命令、观察窗口、仅本App截图范围、正常退出方式。任一缺少即blocked；不下载Xcode、不安装辅助程序、不清理空间或强杀。
- [ ] 在允许范围记录 `sw_vers`、`uname -m`、`xcrun swift --version`、`xcrun --show-sdk-path`、限定目标卷的`df -h`；只取必要信息，不枚举私人文件或进程参数。资源不足执行RES02停止。
- [ ] 对每个目标架构分别，在已有SwiftPM帮助确认支持后运行 `xcrun swift build --scratch-path "$OUTPUT_DIR/build-<arch>" --product PaperclipIsland --arch <arch>`；输出完整日志与退出码。不靠自动降deployment target或安装SDK修复。编译两slice不等两种硬件都运行过。
- [ ] 用已构建的本项目可执行文件验证装配脚本：错误输入/已有目录必须拒绝；成功.app结构可读。执行 `file`／系统工具核架构和产物hash；`codesign --verify --deep --strict --verbose=2 <app>` 与 `codesign -dv --verbose=4 <app>` 仅在授权只读核验范围报告实际状态。未签名/adhoc/未公证如实记录，命令失败不篡改成签名pass；签名方案或Gatekeeper问题需另决策，不能降低保护。
- [ ] 只有启动权限具备才启动本项目app，用虚构场景逐项UI01–UI05、SEC01–SEC04、RES01/02。建议本次资源观察窗口：启动前60秒、静置120秒、交互60秒（**待Mac批准单确认，不是已运行**）；数值预算在启动前冻结，否则性能gate不可pass。
- [ ] 实机步骤：hover前后当前key/前台App不变；点击详情才允许聚焦；非key Esc留给前台App；多屏负坐标、热插拔、缩放、全屏/Space回退；长Unicode/空摘要/浅深色；本App键盘导航/可访问性标签；菜单正常退出、无遗留计时器/辅助常驻。VoiceOver或截图若需要改变用户设置/权限则停下另批，不擅自开启。
- [ ] 记录原生与仅逻辑覆盖差别、设备/架构/实际步骤/产物hash。截图只截虚构本App窗口；没真实外接屏、某架构、授权或签名策略时相应项not_run/blocked，不截图模拟充当实机证据。结果与独评交用户决定保留限制/收窄支持或继续等待，作者不能自行豁免。

## Task 7: 证据包、独立审查与用户验收

**Files:** T7列出的脚本与新记录；不得覆盖已冻结spec、旧GATE_REGISTER或原独评。

**Interfaces:** `check-source-boundary.py --repo <path>` 只检查本项目输入文件/manifest；`validate-evidence.py --evidence <path> --spec-dir <path> --source <repo> --outputs <path>` 用标准库检查文件存在/hash/ID/必需覆盖/clean绑定。完整JSON Schema校验仅使用已安装validator；没有则相应验证blocked，不自行安装。脚本不是执行真实性或权限证明。

- [ ] 在 `Tests/Tooling/test_evidence_validation.py` 用unittest写负例 `test_missing_ST25`、`test_mock_cannot_satisfy_native`、`test_mixed_result`、`test_dirty_source`、`test_wrong_review_commit`、`test_missing_approval`、`test_wrong_hash`，均断言校验非零／拒绝。只用本测试临时虚构文件，不读取其它仓库；合成负例标明“校验器测试，不是产品证据”。
- [ ] 运行 `python3 -m unittest discover -s Tests/Tooling -p 'test_*.py'` 取得red，再实现最小验证并重跑到全部负例正确拒绝、正常结构样本通过；不能靠关键词扫描的“无命中”宣称无网络/凭据访问。权限来源、实际方法、源码可执行调用路径及OS行为由独立reviewer结合实证核。
- [ ] 按EVIDENCE.schema及ACCEPTANCE组证据：exact clean base/head/tree、`git diff --binary --full-index <base> <head>`原字节hash、产物hash、环境/命令/退出码、49项结果、限制和所有gate。未知字段null/原因，不编造commit或截图。
- [ ] 逐项语义核验：所有required检查覆盖、相同版本、无作者/独评者重合、所有引用可解析、P1/P2已resolved、原批准范围有效。任一无法核验则对应gate blocked；schema valid不能自行放行。
- [ ] 新鲜独立全分支review精确head/diff和实际测试结果；未实际Mac验证的项保持not_run。用户看完整证据后另行批准验收/merge；禁止auto-merge，批准后协调者核远端精确SHA。M1/REAL-NOTIFY/RELEASE继续不在此计划。

## 1.2 TDD断言写法示例（计划示例，不是已实现测试）

T1的缺ID样本应直接断言解析失败；T2明确边界，不只检查某个布尔“正常”；T3断言sink调用数而非系统通知identifier；T4/T5对纯策略结果断言。测试中的 `now`、`missingKey`、`state`、`sink` 由各任务虚构测试工厂／前置步骤创建，不读真实数据。

```swift
// T1：malformed 样本，不允许 fallback success。
XCTAssertThrowsError(try EventDecoder.decode(Data(#"{"kind":"task_update"}"#.utf8), generation: 0, receivedAt: now))
// T2：完成有效 baseline 后，在单调年龄恰为 30_000ms 的 Instant 执行。
XCTAssertEqual(reducer.tick(now: atThirtySeconds).state.connection, .stale)
// T3：同 attempt 的第二次失败在第一次 sink 尚 pending 时到达后。
XCTAssertEqual(sink.submitCount, 1)
// T4：选中不存在的任务不得回退显示前一任务详情。
XCTAssertNil(DetailPolicy.select(missingKey, in: state))
// T5：非 key 悬停面板不截获前台 App 的 Esc。
XCTAssertEqual(WindowPolicy.focusAction(for: .escape, appHasFocus: false), .ignore)
```

以上断言只是具体写法锚点；49行矩阵每行仍须有各自输入序列与断言，不用五个示例代替覆盖。T6的真实手工步骤须保留实际观察，不能改写成无真实设备的假单元测试。

## 2 全部49项验收归属（仅映射，当前均未执行）

以下测试名是实现时必须创建的稳定证据锚点；真实检查沿用ID并附manual步骤与设备，不允许把其纯策略子测试升级为原生结果。

| ID | 任务／测试或真实步骤锚点 | 断言重点／证据级别 |
| --- | --- | --- |
| ST01 | T2 `test_ST01_initial` | 初始offline/unknown；mock |
| ST02 | T2 `test_ST02_baseline` | 四态与历史失败不提醒；mock |
| ST03 | T2 `test_ST03_liveFailure`＋T3 | 新failed候选仅一次；mock |
| ST04 | T2 `test_ST04_success` | success不发失败提醒；mock |
| ST05 | T2 `test_ST05_unknownTransitions` | unknown转换；mock |
| ST06 | T2 `test_ST06_payloadConflict` | 重复/旧revision/异payload；mock |
| ST07 | T2 `test_ST07_oldAttempt` | 旧输入不覆盖；mock |
| ST08 | T2 `test_ST08_terminalConflict` | 同attempt终态冲突；mock |
| ST09 | T2 `test_ST09_newAttempt`＋T3 | 新尝试重新失败可提醒；mock |
| ST10 | T2 `test_ST10_attemptIdentity` | ID/ordinal冲突；mock |
| ST11 | T1 `testMissingID`等＋T2 `test_ST11_malformed` | 拒绝保留可信值；mock |
| ST12 | T1 `testConflictingBaseline`＋T2 `test_ST12_atomicBaseline` | baseline原子拒绝；mock |
| ST13 | T2 `test_ST13_emptyBaseline` | 空集合不是成功；mock |
| ST14 | T2 `test_ST14_disconnect` | 保留任务并offline；mock |
| ST15 | T2 `test_ST15_staleBoundary` | 29,999/30,000ms边界；mock |
| ST16 | T2 `test_ST16_heartbeat` | 不刷新任务时间；mock |
| ST17 | T2 `test_ST17_oldGeneration` | 新baseline资格；mock |
| ST18 | T2 `test_ST18_epoch` | 换epoch需baseline；mock |
| ST19 | T2 `test_ST19_wallClockJump` | 只用单调年龄；mock |
| ST20 | T2 `test_ST20_invalidHeartbeat` | 无效输入不刷新；mock |
| ST21 | T2 `test_ST21_gap` | 缺口desync不应用；mock |
| ST22 | T2 `test_ST22_offlinePriority` | 无baseline不online；mock |
| ST23 | T2 `test_ST23_matrix` | 4×4及新attempt全组合；mock |
| ST24 | T2 `test_ST24_wake`＋T6睡醒 | 模拟逻辑＋真实事件接线分别记 |
| ST25 | T2 `test_ST25_oldBaseline` | 旧/矛盾水位拒绝，一致可恢复；mock |
| NT01 | T3 `test_NT01_firstFailure` | 新失败1次；mock |
| NT02 | T3 `test_NT02_replay` | 详情/面板不重发；mock |
| NT03 | T3 `test_NT03_denied` | suppressed/无授权调用；mock |
| NT04 | T3 `test_NT04_noBacklog` | 授权变化不补发；mock |
| NT05 | T3 `test_NT05_uncertain` | fail/uncertain不重试；mock |
| NT06 | T3 `test_NT06_restartBaseline` | 重启历史不补发；mock |
| NT07 | T3 `test_NT07_sourceNamespace` | 源身份隔离；mock |
| NT08 | T3 `test_NT08_identifierIsNotDedup` | 应用账本去重；mock |
| NT09 | T3 `test_NT09_pendingAndLateCompletion` | reserved及旧completion；mock |
| LK01 | T4 `test_LK01_localOnly`＋T6 | 本地详情，OS接线另验 |
| LK02 | T4 `test_LK02_disabled`＋T6 | 禁用原因可见 |
| LK03 | T4 `test_LK03_rejectedTargets` | 任意真实target都拒绝；mock |
| LK04 | T4 `test_LK04_selectionIdentity`＋T6 | 不串任务；mock＋交互 |
| UI01 | T5窗口策略＋T6 UI01 | hover/click/Esc焦点；real-required |
| UI02 | T5几何策略＋T6 UI02 | 负坐标/热插拔/缩放；real-required |
| UI03 | T6 UI03 | 全屏/Space不抢占；real-required |
| UI04 | T4文字策略＋T6 UI04 | 长Unicode/浅深色；real-required |
| UI05 | T6 UI05 | 标签/本地键盘导航；real-required |
| SEC01 | T7源边界＋T6 SEC01 | 静态审阅＋真实调用观察；不能只grep |
| SEC02 | T5生命周期＋T6 SEC02 | 退出/无后台；real-required |
| SEC03 | T7调用审阅＋T6 SEC03 | 无系统授权请求；静态与真实分开 |
| SEC04 | T1/T5虚构输入＋T7日志审阅 | 无秘密/私人正文；static-required |
| RES01 | T6 RES01 | 同口径资源和实际窗口；real-required |
| RES02 | T6准入＋T7交接 | 资源/权限失败停边界，不绕过 |

## 3 阶段退出条件与未决

- T1–T4及T5纯策略可在已有可用Swift的获准云环境验证；没有工具链不安装，结果保持blocked。源码准备完不等G4通过。
- G4需要全部ST/NT/LK及静态安全证据；G5–G7必须独立Mac批准和实际平台/签名/截图证据；G8独评不能由实现者自签；G9用户另验收/合并。
- Mac执行器、当次资源预算/保留余量、真实架构设备/显示器、内部签名策略及启动/截图许可是T6具体输入，当前均未授予。它们不授权现在去查Mac或安装工具。
- 文档初始main基线写入、Draft PR文档上传以及产品实施是不同动作；协调者分别核明确许可。当前作者不写repo。
- 推荐执行方式是逐任务subagent-driven；用户也可选择单一实现者按同一计划顺序执行、最后独评。实施方法和计划范围须用户确认后才派产品任务。

## 4 作者自检与当前实际结果

本节为计划文档检查，不是产品验收：

- 覆盖：目标、M0/M1边界、契约/状态、提醒、窗口、隐私/资源、协作、门禁及风险均映射T1–T7和准入段；49个ID逐项保留。
- 步骤：每个任务含明确文件/接口、红灯、最小实现、重验、独评及提交边界；T6是需另批的实际平台检查，不能在云端模拟完成。
- 类型：共用TaskKey/AttemptKey/Instant/Event/Transition由T1定义；reducer→notifier→presentation沿同一契约；所有窗口/导航函数与生产文件在地图列明。
- Review Focus：F1–F5各有明确测试/真实检查归属，没有以“处理边界”替代断言。
- 比例：本计划给接口、断言和步骤，不预写产品函数体，不生成脚手架；未安装依赖或执行构建。
- 冻结设计字节未修改。批准证据作为独立文件保存。计划本身、产品实施和Mac执行仍待各自明确批准。

## 5 参考与交付

SwiftPM使用Package.swift声明目标、平台与依赖；tools版本决定manifest最低支持语义，实际本机能力以已存在工具链核验为准：[Swift PackageDescription官方文档](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)。原生菜单选用[Apple NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)；框架文档不构成本项目已实现或已测试的证据。

请用户审阅本计划并确认范围及执行方式。只有明确批准后才进入实施；文件/版本变化、Mac操作、真实后端接入、合并和发布仍按各自门禁处理。


## 附录：计划的授权来源（便于单文件阅读）

2026-11-02 14:44:48 UTC，Assistant `Sentinel_0e5a120043908191aa1f482878ebca4c`：

> 是否批准这份 v0.1.2 设计，并按 paperclip-island 私有仓库进入实施计划？

2026-11-02 14:53:14 UTC，User `Sentinel_e3752bee895481919c731e71625c5179`：

> 批准

这份回复只支持已冻结设计获批及进入计划阶段；它不批准本计划的执行，更不授权Mac运行、依赖下载、后台、真实账号、合并发布或费用。独立完整记录保持在上列AUTHORIZATION文件，未修改已评审规格字节。
