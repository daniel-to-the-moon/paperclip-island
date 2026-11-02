# 初版独立评审响应

作者：`/root/inspect_release_access`；schema 作者：`/root/inspect_release_access/draft_evidence_schema`。独立 reviewer：`/root/review_island_acceptance`，未写本文或规范文件。

评审基线：`paperclip-island-m0-spec-v0.1.0-draft`，保存在 `review-baselines/v0.1.0-draft/`。修订：`paperclip-island-m0-spec-v0.1.2-draft`。初版独评为 changes_required，无 P0；以下“已修”是作者响应，仍等独立复核，不能自关评审问题。

| 项 | 作者修订及位置 | 待复核 |
| --- | --- | --- |
| R1 baseline/恢复资格 | SPEC §6–7：无有效当前baseline不online；断线撤资格，恢复需connected＋新generation＋baseline；ST22 | 是否所有迟到路径被约束 |
| R2 跨任务序号缺口 | SPEC §6–7：全局连续序号及baseline水位；本地连接事件不占seq；缺口desynced不应用不提醒；旧revision消费连续游标；同seq不同payload冲突；ST06/ST21 | 字段按kind与游标语义 |
| R3 offline/计时/睡醒 | SPEC §7：offline优先；单调年龄30秒；唤醒重同步不回放；ST22/ST24 | 不虚假online |
| R4 通知竞争 | SPEC §8：串行/原子reserved先于sink；generation+delivery token；NT09 | pending／旧completion边界 |
| R5 完整转换 | SPEC §7四乘四表、更高attempt优先、冲突仅同attempt锁定；ST23 | unknown不误失败，旧attempt不覆盖 |
| R6 版本和语义门禁 | ACCEPTANCE §5/9：最终clean commit，完整check覆盖与引用/hash/身份fail-closed；schema清洁源码、混合失败禁pass、required固定、P1/P2必须resolved | schema与人工语义核验均不能冒充事实 |
| R7 批准与门禁映射 | schema design_approval独立scope；ACCEPTANCE §9明确approval_refs语义约束及G映射；GATE_REGISTER保留G0–G9/REAL-NOTIFY/M1/RELEASE | 只批设计不授执行，门禁不因漏字段消失 |
| R8 焦点/屏幕 | SPEC §9与UI01/02：hover不key，点击可聚焦，非key不截Esc；负坐标/热插拔/缩放重算 | 仍需真实Mac，未实测 |

本轮没有产品实现、依赖安装、仓库创建、Mac 执行、通知授权、真实接口访问。作者自检与 schema 片段探针仅验证文档结构，不能算 ST/NT/UI 产品通过。

## v0.1.1 增量复核响应（待独立终审）

- R9：SPEC §6 保留跨 generation 的 source/epoch 最高已接受水位，拒绝旧 baseline／同水位矛盾快照；补 ST25。不声称重启后仍有记忆。
- R10：ACCEPTANCE §5 区分输入源码与输出产物；clean commit 限定输入，.app／日志／截图可在独立输出区 hash 绑定，不需提交二进制。
- 措辞收紧：SPEC §7 从未取得 baseline 才是初始 unknown；断线保留历史可信任务。
