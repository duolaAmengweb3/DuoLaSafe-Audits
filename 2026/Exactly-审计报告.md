# Exactly Protocol 智能合约安全审计报告

**审计方:** DuoLaSafe
**审计日期:** 2026-06-29
**报告版本:** v1.0
**代码版本(commit):** `342d9061a9d17897f69b3b4be28e776db207ef05`(v0.2.23)

---

## 免责声明与保密说明
本审计依据行业最佳实践对目标合约进行分析,**不构成对合约绝对安全性的保证**,也不构成投资建议。审计范围仅限本报告所列代码与提交版本;范围外代码、链下组件、私钥管理、前端及后续升级不在保证之列。Exactly 为开源、历史经 25+ 轮第三方审计的成熟协议,本次为独立复审,重点放在**最后一次公开审计(ABDK 2025-10)之后的增量代码与新模块**。

---

## 1. 项目概览

### 1.1 审计范围
| 项目 | 描述 |
|---|---|
| 项目名称 | Exactly Protocol(固定 + 浮动利率借贷) |
| 开发语言 | Solidity 0.8.26(cancun) |
| 部署链 | Optimism |
| 代码版本 | commit `342d9061` / v0.2.23(2026-06-25) |
| 代码行数 | 核心 ~4,254 SLOC |
| 审计时间 | 2026-06-29 |

**范围内合约(核心 + 2025-10 后新增/改动):**
- `Market.sol` — ERC4626 借贷核心:浮动/固定到期池、份额会计、清算、坏账清理
- `MarketBase.sol` — 存储与会计基类、固定 vs 浮动利率记账
- `Auditor.sol` — 风险管理:健康度、清算许可、抵押系数、预言机取价
- `InterestRateModel.sol` — sigmoid 利率曲线
- `FixedLib.sol` — 固定池数学、到期位图
- `MarketExtension.sol` — delegatecall 扩展(transfer/initialize)
- `RewardsController.sol` / `StakedEXA.sol` / `EXA.sol`(含跨链 mint/burn)
- `verified/`(VerifiedMarket / VerifiedAuditor / Firewall)— KYC 合规层
- `periphery/`(FlashLoanAdapter / DebtRoller)— 杠杆/展期助手

### 1.2 审计简介
对核心借贷流程做系统级联审:不止单函数常见问题,重点验证跨合约业务流程自洽性——存/借/提/还、固定到期池与浮动池迁移、清算与坏账社会化、份额会计取整方向、可升级/权限边界。并以"最后审计之后的 diff"为主攻方向(审计盲区),逐条对照 OWASP SC Top-10 + 内部漏洞模式库。

### 1.3 项目背景
Exactly 是 Optimism 上的去中心化借贷协议,独特之处在于用不同到期日池子的利用率决定固定利率。每个资产一个 ERC4626 Market;Auditor 统一做风险与清算;固定池借入浮动池的"备用流动性"(floatingBackupBorrowed)。

---

## 2. 审计总结

### 2.1 漏洞统计
| 严重程度 | 数量 |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 2 |

### 2.2 审计结论
**整体安全性高,防御到位。** 4 年、25+ 轮审计与高强度模糊测试(production/overkill profile 数百万 runs)使表层与多数深层问题已被清空。本次未发现 Critical/High/Medium。最值得注意的运营级风险是 **Auditor 取价仅校验 `price>0`、未做喂价新鲜度(staleness)校验**(L-01)——在成熟 Optimism Chainlink feeds + 链下监控下风险可控,但建议补充 `updatedAt` 边界。其余为低风险与最佳实践建议。

---

## 3. 技术与业务分析

### 3.1 技术快速评估
| 主类别 | 子项 | 结果 |
|---|---|---|
| 合约编程 | Solidity 版本(0.8.26) | 通过 |
| | 整数溢出/下溢 | 通过(0.8 默认检查;`unchecked` 块已人工证明安全) |
| | 函数输入参数校验 | 通过 |
| | 权限控制管理 | 通过(AccessControl 角色分层;合规层 auditor 门禁) |
| | 重入 / 竞争条件 | 通过(Slither 37 处提示经人工判为不可利用,见 3.3) |
| | 外部调用返回值检查 | 通过(SafeTransferLib) |
| | 价格预言机操纵 | 见 L-01(无 staleness 校验) |
| | 可升级性 / 初始化 | 见 I-01(Market.initialize 无 proxy-admin 校验) |
| 代码规范 | 函数可见性 / 未使用代码 | 通过 |
| Gas | 高消耗循环 | 通过(到期位图限界遍历) |

### 3.2 关键防御(已验证成立,差异化"排除攻击")
- **抗份额通胀(首存攻击)**:`totalAssets()` 基于内部记账 `floatingAssets`,**不读 `asset.balanceOf`** → 直接捐赠不改变份额价,经典 ERC4626 通胀/捐赠攻击不适用。✅
- **清算自清算防护**:`liquidate` 显式 `if (msg.sender == borrower) revert SelfLiquidation()`。✅
- **合规层(verified/)**:`lock/unlock`、对 disallowed 账户的清算路径全部 `auditor`/`allower` 权限门禁;非特权用户无可利用路径。✅
- **FlashLoanAdapter**:静息零托管,`receiveFlashLoan` 校验 `msg.sender==vault`,借款必须原子归还+settle,否则全 revert。✅
- **DebtRoller**:`data.sender = msg.sender`(只能展期自己)、`spendAllowance` 需用户预授权、`callHash` 防伪造回调、资金流闭环净额 0。✅
- **supply cap 修复核对**:历史 commit `bf3066c3` 把 `shares+totalSupply>maxSupply`(afterDeposit 中 totalSupply 已含新铸 shares、重复计)修正为 `totalSupply>maxSupply` —— 修复正确,无残留。✅

### 3.3 Slither 结果
全量扫描 154 合约、557 条结果,人工三分类:`reentrancy-no-eth`/`benign` 37 处集中在 Market 的 deposit/borrow/repay/clearBadDebt —— 外部调用对象为**可信组件**(rewardsController/auditor)+ Optimism 上**非回调代币**(USDC/WETH)、基本遵循 CEI → 判为不可利用;`controlled-delegatecall`(目标 `extension` 为 immutable 可信)、`arbitrary-send-erc20`(StakedEXA.harvest 的 provider 为管理员配置且需主动 approve)均经核排除。余者为命名/风格信息级噪音。

---

## 5. 审计发现

### 5.1 严重程度定义
| 级别 | 描述 |
|---|---|
| Critical | 直接导致资产被盗/金库清空/系统级失控 |
| High | 对结算或权限边界重大影响 |
| Medium | 破坏业务正确性,需尽快修复 |
| Low | 较小风险 / 兼容性 / 旧版本 |
| Informational | 最佳实践建议 |

### 5.2 详细发现

#### [L-01] Auditor 取价无喂价新鲜度(staleness)校验 — `Low`
- **位置**:`Auditor.sol:353-359` `assetPrice()`
- **描述**:用 Chainlink `latestAnswer()`,仅判 `price <= 0`,**未校验 `updatedAt`/round 完整性,也无 min/max 边界**。喂价冻结或过期时仍被采纳。
- **影响**:极端行情/喂价中断时,抵押与债务估值可能用到陈旧价 → 错判健康度 → 延迟/错误清算 → 潜在坏账。Optimism 主流 feeds 稳定 + 链下监控使实际风险受限。
- **修复建议**:改用 `latestRoundData()` 并校验 `updatedAt` 与 `block.timestamp` 的最大偏差、`answeredInRound`,并对价格设合理 min/max。
- **关联**:SC03(预言机)。**状态**:未修复(疑为已知接受项)。

#### [L-02] StakedEXA.harvest() 无权限 + 0 金额 notify 可拉长发放周期 — `Low`
- **位置**:`StakedEXA.sol:347-358` `harvest()`,及 `_update` 中 `try this.harvest()`
- **描述**:`harvest` 无访问控制且每次 deposit 都会触发。当 `provider` 授权耗尽时,`shares=0`,仍调 `notifyRewardAmount(market, 0)`;若当前 < `finishAt`,则 `rate=remainingRewards/duration` 且 `finishAt=now+duration`。反复调用可不断把 `finishAt` 后推、稀释发放速率。
- **影响**:奖励发放被无限拉长(资金不丢失、已发放部分不受影响),属 griefing。
- **修复建议**:harvest 设最小注资阈值或限频;`notifyRewardAmount` 对 0 金额提前返回。
- **关联**:SC02(业务逻辑)。**状态**:未修复。

#### [I-01] Market.initialize 缺 proxy-admin 校验 — `Informational`
- **位置**:`Market.sol`(delegate 至 `MarketExtension.initialize`,仅 `initializer` 修饰)
- **描述**:对比 `EXA.sol` 已加 `msg.sender == proxyAdmin` 抢跑防护,`Market.initialize` 未加同等校验,依赖部署原子性。未原子初始化的代理理论上可被抢跑成 admin。
- **影响**:标准部署流程下不可利用(部署+初始化同笔/紧邻);仅作硬化建议。
- **修复建议**:与 EXA 一致,initialize 加 proxy-admin / 构造期校验。**状态**:未修复(设计取舍)。

#### [I-02] 逾期罚息线性无上界 — `Informational`
- **位置**:`previewDebt` / `noTransferRepayAtMaturity`,`penaltyRate * elapsed`
- **描述**:罚息随逾期时间线性增长无封顶。极端逾期下债务数额巨大(不溢出),建模未发现致清算卡死的实际路径,记为信息项。

---

## 7. 审计方法论
DuoLaSafe 采用工具 + 人工 + 动态验证协作式方法:
1. **审计盲区对账**:用 `git log` 锁定最后一次公开审计(2025-10)之后的改动文件,优先审增量与新模块。
2. **自动化静态分析**:Slither 全量扫描,557 条逐条人工判真伪。
3. **人工代码审阅**:逐行审核心 9 合约 + 新代码(EXA 跨链 / 合规层 / flashloan 助手),对照 SC Top-10 + 内部漏洞模式库。
4. **业务逻辑建模**:份额会计取整方向、固定/浮动迁移、清算与坏账社会化、可升级边界。
5. **对抗性验证**:对关键防御(抗通胀、CEI、零托管、supply cap 修复)逐一核实成立,公开"排除了哪些攻击"。
6. **报告输出**:只保留已验证问题,压缩误报,每条发现绑定代码路径与修复建议。

---

## 附录:工具与版本
- 静态分析:Slither 0.11.5
- 测试/PoC:Foundry(forge 1.5.1)
- 联系方式:见 DuoLaSafe 站点

*© 2026 DuoLaSafe. 本报告仅针对指定代码版本,修改后需重新审计。*
