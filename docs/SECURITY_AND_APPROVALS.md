# Security And Approvals

## 1. 安全审阅的职责

安全审阅可以输出：

- 风险
- 触发条件
- 后果
- 证据
- 可选修复方案
- 建议补充的测试

安全审阅不能直接输出：

- 新的产品需求
- 未经确认的业务规则改写
- "必须这样设计"的产品结论

## 2. 明确禁止

以下行为一律禁止：

- 以 review 名义修改产品需求
- 把"审阅建议"直接写成仓库规则
- 在没有人工确认的情况下改变资金流约束
- 在没有人工确认的情况下改变权限边界
- 在没有人工确认的情况下扩大 owner（四 setter 与 pause/UUPS）、uAsset minter 台账、genesis launcher 门或其他 privileged role 的职责

## 3. 必须升级为决策点的改动

如果某个建议会改变以下任一项，必须先由 `main-orchestrator` 或人工确认：

- 业务语义
- 资金流约束
- claim / settlement / mint cap / liquidity 等产品规则
- 收益归属或收益领取规则
- 权限边界
- 升级模型
- 外部协议依赖边界

在确认前，reviewer 只能把它写成：

- 风险描述
- 原因
- 后果
- 可选方案
- 待确认决策点

## 4. 常见判定示例

### 4.1 允许直接修复

- 明确的算术错误
- 明确的访问控制漏洞
- 与既有 spec / 当前实现明显冲突的行为错误
- 存储布局冲突
- 事件缺失导致既有对外行为不可观测

### 4.2 不允许直接落地

- "为了更安全，把协议规则改成更保守的资金流约束"
- "为了未来扩展，先预留一套新的状态机"
- "为了用户体验，把延迟路径改成即时路径"
- "为了统一实现，顺手扩大 owner（四 setter 与 pause/UUPS）/ uAsset minter 台账 / genesis launcher 门职责"

这些都属于产品规则变化，不是纯安全修复。

## 5. 审阅输出格式建议

审阅结论应尽量包含：

- `Finding`
- `Severity`
- `Where`
- `Why`
- `Impact`
- `Evidence`
- `Options`
- `Needs decision`

如果 `Needs decision = yes`，实现型角色不得默认落地。

## 6. 与流程文档的关系

当 `SECURITY_AND_APPROVALS.md` 与某条 review 建议冲突时，以本文件和 `CLAUDE.md` 为准，而不是以 review 建议为准。
