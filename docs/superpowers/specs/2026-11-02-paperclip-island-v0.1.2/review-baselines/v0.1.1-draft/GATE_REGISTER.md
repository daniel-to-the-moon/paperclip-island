# Paperclip Island 门禁登记（设计阶段）

绑定规格：`paperclip-island-m0-spec-v0.1.1-draft`。精确文件摘要见同目录 `REVIEW_MANIFEST.json`；本文件不授予权限。下列状态只反映本次设计工作，没有产品执行结果。owner 为负责跟进者，不等于获执行许可。

| Gate | 状态 | 已有／缺少证据及下一条件 | owner |
| --- | --- | --- | --- |
| G0 设计完整 | blocked | SPEC、ACCEPTANCE、schema 已编写和作者结构自检；等修订版独立自洽复核 | 设计作者 |
| G1 独立设计审查 | blocked | 初版 changes_required；v0.1.1 已回应，等精确 hash 增量结论 | 独立 reviewer |
| G2 用户设计批准 | not_run | 用户只批准独立私有路线，未看本设计；需最终版本批准原文引用 | 用户／协调者 |
| G3 实施授权与认领 | not_run | repo 未建、实现计划／锁／运行许可未定；不继承旧项目授权 | 协调者 |
| G4 M0 逻辑 | not_run | 没有产品代码或 fixture 执行；作者文档检查不计入 | 后续唯一实现 owner |
| G5 macOS 构建 | not_run | 无本项目实际 Mac 构建，Intel／ARM 均无证据 | 获授权验收者 |
| G6 Mac 交互 | not_run | 无 App 启动／截图／实机多屏焦点或资源结果；每架构另列 | 获授权验收者 |
| G7 签名与交付检查 | not_run | 没有产品包，无签名实际核验；分发范围待定 | 获授权验收者 |
| G8 独立代码审查 | not_run | 没有产品代码，设计审查不替代 | 后续独立 reviewer |
| G9 用户验收／合并 | not_run | 无产品验收或 merge 批准；不得 auto-merge | 用户／协调者 |
| REAL-NOTIFY | not_run | M0 不请求真实通知权限；另需具体批准和实机证据 | 用户／获授权验收者 |
| M1 真实只读 | not_run | 本次范围外；后端可达／只读身份／接口／凭据与网络范围未批准 | 用户／协调者 |
| RELEASE | not_run | 本次范围外；发布、签名公证、费用、回退须另批准 | 用户／协调者 |

每次状态变化追加日期、操作者、批准来源、对应 spec/源码/产物 hash、实际证据引用及剩余阻塞。任何门禁缺行或引用不可核都不构成通过。此登记允许如实保存部分完成，不允许缩小 required 集合。
