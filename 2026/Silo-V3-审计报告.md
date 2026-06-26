# Silo Finance V3（silo-core）智能合约安全审计报告

**审计方:** DuoLaSafe · Web3 安全审计 / 链上取证
**审计日期:** 2026-06-25
**报告版本:** v1.0
**代码版本(commit):** `silo-finance/silo-contracts-v3` @ `607535c`
**联系方式:** Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)

---

## 免责声明与保密说明

**本安全审计报告可能包含敏感信息。** 本文档包含潜在漏洞、攻击路径与恶意利用分析,建议在问题修复完成后再决定是否公开。

DuoLaSafe 已依据行业最佳实践对目标智能合约进行了分析。**本审计不构成对合约绝对安全性的保证**,也不构成投资建议。所有投资者与用户仍应自行完成尽职调查。审计范围仅限本报告"审计范围"所列代码与提交版本;范围外代码(`silo-vaults`、`x-silo`、`silo-oracles`、`incentives`、部署脚本)、链下组件、私钥管理、前端及后续升级不在本次保证之列。

**诚实披露:** Silo V3 在本次审计前已经过**多家顶级机构审计 + Certora 形式化验证 + 企业级持续审计**(报告见仓库 `audits/v3/`),并维护了一份 `KnownIssues.md`。对这样的标的,发现新的高危/严重漏洞的概率本就极低。本报告定位为 **silo-core 核心范围的一次独立、可复核、带对抗性验证的复审**,而非全量重审。

---

## 1. 项目概览

### 1.1 审计范围

| 项目 | 描述 |
|---|---|
| 项目名称 | Silo Finance V3（silo-core) |
| 开发语言 | Solidity 0.8.28(核心库),依赖区间 ^0.8.x |
| 部署链 | 多链 EVM(需 Cancun / transient storage 支持) |
| 代码版本 | `silo-finance/silo-contracts-v3` @ commit `607535c` |
| 代码行数 | 核心审计面 ≈ 3,300+ nSLOC(Silo 827 / SiloConfig 474 / Actions 638 / SiloLendingLib 494 / SiloMathLib 370 / SiloERC4626Lib 301 / SiloSolvencyLib 239 等) |
| 审计时间 | 2026-06 |

**范围内合约:**

| 模块 | 文件 | 职责 |
|---|---|---|
| 核心入口/配置/分发 | `Silo.sol` | ERC4626 借贷金库主合约,动作入口 |
| | `SiloConfig.sol` | 跨 silo 配置协调 + transient 跨重入锁 |
| | `lib/Actions.sol` | 存/取/借/还/清算等动作分发 |
| | `hooks/_common/TransientReentrancy.sol`、`utils/CrossReentrancyGuard.sol` | 跨合约重入保护 |
| | `utils/ShareToken*.sol` | 抵押/债务份额代币 |
| 借贷数学/份额/舍入 | `lib/SiloLendingLib.sol` | 借还与计息核心 |
| | `lib/SiloMathLib.sol` | share/asset/LTV 换算 |
| | `lib/SiloERC4626Lib.sol`、`lib/Rounding.sol`、`lib/SiloStdLib.sol` | ERC4626 适配、舍入方向、标准工具 |
| 偿付能力/清算 | `lib/SiloSolvencyLib.sol` | 偿付能力判定 / LTV 计算 |
| | `hooks/liquidation/PartialLiquidation.sol` | 标准部分清算 |
| | `hooks/defaulting/*`、`PartialLiquidationLib/ExecLib.sol` | 坏账(defaulting)清算与执行库 |
| 利率模型/杠杆/Hook | `interestRateModel/InterestRateModelV2.sol`、`interestRateModel/kink/DynamicKinkModel.sol` | 利率模型(经典 + 动态 kink) |
| | `leverage/LeverageUsingSiloFlashloan.sol`、`hooks/SiloHookV3.sol` | 闪电贷杠杆、Hook 封装 |

**范围外(本轮未审):** `silo-vaults`、`x-silo`、`silo-oracles`、`incentives`、部署脚本;以及自动化静态分析 / 形式化验证(已由项目方 Certora + 既有审计覆盖)。

### 1.2 审计简介

本次审计聚焦 **silo-core 的安全关键核心**:核心入口与配置、借贷数学与份额转换、偿付能力与清算、利率模型与杠杆。审计不仅检查单函数级常见安全问题,更重点验证**跨合约业务流程是否自洽**——包括存款入场、借款、还款、清算(标准与坏账两条路径)、计息时点、份额↔资产舍入方向、以及跨 silo 协调下的状态一致性与重入边界。

每个候选发现均经过**对抗性验证**:要么用攻击模型 / PoC 思路坐实,要么读真实代码证伪并公开记录排除理由。同时对照仓库内 `KnownIssues.md` 去重,确保本报告所列均为**已有审计与已知问题未单独覆盖**的新增观察。

### 1.3 项目背景

Silo V3 是**隔离市场(isolated-market)借贷协议**:每个 Silo 是一对相互隔离的借贷市场(两种资产),通过 `SiloConfig` 协调这一对 silo 之间的抵押/债务关系,核心逻辑集中在 `silo-core/contracts/lib/` 的若干库中。与共享池借贷(如 Aave 主池)不同,隔离市场把每个资产对的风险关在自己的市场内,单一资产坏账不会外溢到其他市场,因此跨 silo 的状态协调与重入边界是其特有的风险面。

**资金流与角色:**
- **存款人(Lender):** 向某个 silo 存入资产换取抵押份额(ERC4626 份额),赚取借款利息。
- **借款人(Borrower):** 在一个 silo 存抵押,在配对 silo 借出另一资产,需维持 LTV 在清算线之下。
- **清算人(Liquidator):** 当借款人 LTV 超限时执行部分清算,代还债务并折价取走抵押份额。
- **协议/DAO:** 通过 `daoAndDeployerRevenue` 收取协议费,并在坏账时作为第一垫付方。
- **Owner / 工厂:** 通过工厂部署并校验 IRM / Kink 配置、hook receiver 等(受信任)。

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

**未发现可直接导致资金损失的漏洞(0 Critical / 0 High / 0 Medium)。** 核心不变量(总抵押价值 ≥ 总负债价值)的保护严密:

- **重入锁覆盖完整** —— 写路径一律 `turnOnReentrancyProtection → 改状态 → 校验 → turnOff`;share token `transfer` 也获同一把锁,`mint/burn` 的 after-hook 在锁内仅允许只读重入。
- **计息时点正确**,份额↔资产舍入**全表对协议保守**(无方向反转、无先除后乘精度损失)。
- **LTV 计算无方向性偏差**,清算无"多拿抵押 / 少还债"的套利路径。
- **ERC4626 通胀/首存攻击**被 decimal offset(=3 虚拟份额)+ `+1` 虚拟资产正确防住,经济上不成立。

**最值得注意的剩余风险(均未达漏洞级别):**
1. **坏账(defaulting)会计退化(I-01,Low):** 极端坏账可把 `totalAssets[Collateral]` 清零却保留份额,残留"幽灵份额"会稀释下一个存款人;offset=3 仅部分缓解。
2. **清算 repay 在重入锁外执行(I-02,Low):** 标准清算先转抵押份额、后还债,且还债时全局跨重入锁已关闭;仅当上架可回调资产(ERC777 / 异常 fee-on-transfer)时才有理论重入面,属设计权衡 + 资产约束。
3. **DynamicKink 利息处理与 V2 不一致(I-03,Info):** 极端配置下 `X_MAX` 走 `require` revert 而非优雅封顶,导致整段利息被丢弃。
4. **坏账兜底缺乏可观测性(I-04,Info):** 坏账社会化时无事件区分承担方。

---

## 3. 技术与业务分析

### 3.1 技术快速评估

| 主类别 | 子项 | 结果 |
|---|---|---|
| 合约编程 | Solidity 版本 | 通过(核心固定 `0.8.28`,Cancun + transient storage,内建溢出检查) |
| | 整数溢出/下溢 | 通过(0.8 checked 算术;`applyFractions` 经手撕无下溢;利息溢出有熔断跳息) |
| | 函数输入参数校验 | 通过(动作入口经 `Actions` 分发并做配置/金额校验;初始化受 `lt+fee<=100%`、`liquidationTargetLtv<=lt` 约束) |
| | 权限控制管理 | 通过(IRM/Kink config 由工厂校验、可信 owner 设置;杠杆 `onlyRouter` + 每用户 `Clones` 克隆) |
| | 重入 / 竞争条件 | 通过(跨 silo transient 重入锁覆盖完整;见 I-02 为锁外 repay 的纵深防御观察,非漏洞) |
| | 外部调用返回值检查 | 通过(`trySub` 返回值在 I-04 处被丢弃,仅影响可观测性,不影响正确性) |
| | 价格预言机操纵 | 通过 / 部分 N.A.(本轮未含 `silo-oracles`;同 silo 路径不调 `callSolvencyOracleBeforeQuote`,作为二阶段建议核查项) |
| 代码规范 | 函数可见性显式声明 | 通过 |
| | 未使用代码 | 通过(未发现影响安全的死代码) |
| Gas 优化 | Out of Gas 风险 | 通过(IRM 溢出/异常跳息不锁 silo;DynamicKink 最坏 calldata gas 量化列为二阶段) |
| | 高消耗循环 | 通过(核心路径无未封顶的用户可控循环) |

> 说明:本轮为核心范围人工 + 对抗性验证;自动化静态分析(Slither)与形式化验证由项目方 Certora 与既有审计覆盖,未在本轮重复全量运行。

### 3.2 业务风险分析(代币/项目安全)

> **N.A.(非代币发行):** Silo V3 是借贷**协议**,非单一 ERC20 代币发行项目,下列"买卖税 / 增发 / 黑名单 / 貔貅"等针对发币型标的的指标在本场景不直接适用。为完整起见仍逐项以协议视角说明。

| 类别 | 结果 |
|---|---|
| 买卖税 | N.A.(协议无转账税;协议费经 `daoAndDeployerRevenue` 从利息中计提,非交易税) |
| 是否可增发 | N.A.(无项目代币 mint;ERC4626 抵押/债务份额按存借动作铸销,数学受 `SiloMathLib` 约束) |
| 是否存在黑名单 | 无(协议层未发现地址黑名单;具体 hook receiver 可能引入,受信任配置) |
| 是否存在 Honeypot(貔貅)风险 | 无(存款人可正常 `withdraw`,受偿付能力与流动性约束,非单向陷阱) |
| 是否存在防巨鲸/机器人机制 | N.A.(借贷协议无此类机制;风险由 LTV/清算线控制) |
| 是否存在隐藏所有者 | 受信任 owner / 工厂(IRM/Kink config、hook receiver 由部署者经工厂校验设置,属设计内的可信角色) |
| 是否可接管控制权 | 升级/配置权在受信任 owner / 工厂;hook receiver 由部署者配置且受信任(关键假设) |
| 持有人集中度 | N.A.(协议非代币发行) |
| 流动性是否锁定 | N.A.(借贷协议流动性即各 silo 的存款,由存借动态决定,非 LP 锁仓概念) |

---

## 4. 代码质量与安全性

### 4.1 代码质量

代码结构清晰、模块边界明确:顶层 `Silo.sol`(ERC4626 金库)+ `SiloConfig.sol`(跨 silo 协调与 transient 重入)作为入口,核心业务逻辑下沉到 `contracts/lib/` 的纯函数库(`Actions` 动作分发、`SiloLendingLib` 借还计息、`SiloMathLib` 数学换算、`SiloSolvencyLib` 偿付判定、`SiloERC4626Lib` 适配),清算与利率模型以 hook / 独立模型形式插拔。舍入方向集中在 `Rounding.sol` 统一管理,**全表对协议保守**,这是高质量借贷代码的标志。隔离市场模型把每个资产对的风险关在自己的 silo 内,降低了系统性传染。

### 4.2 文档情况

注释能较好反映开发者意图,部分**已知的会计退化性质在接口注释中被主动披露**(如 `IPartialLiquidationByDefaulting` 自承"can reset total assets completely while leaving shares behind … next deposit will lose the value of that left shares",对应 I-01)。仓库维护 `KnownIssues.md` 显式登记已知限制,审计友好。改进点:坏账社会化路径缺乏事件(I-04),链下监控与会计审计的可观测性可提升。

### 4.3 外部依赖

Silo V3 的核心借贷数学**使用自有库**(`SiloMathLib` / `SiloLendingLib` / `Rounding` / `SiloSolvencyLib` 等),**未依赖 Euler、OpenZeppelin 等第三方借贷/数学实现**,因此不受这些外部库已知问题的间接影响。OZ 类基础设施(如 `Clones`)仅在杠杆等边缘处用于最小代理克隆,用法标准。底层资产被假设为非恶意(代码注释声明不支持 fee-on-transfer / rebasing / 回调资产)。transient storage 依赖 Cancun,交易结束自动清零。

---

## 5. 审计发现

### 5.1 严重程度定义

| 级别 | 描述 |
|---|---|
| Critical | 可能直接导致资产被盗、金库清空或系统级失控 |
| High | 对业务执行、用户资产结算或权限边界产生重大影响 |
| Medium | 需尽快修复的重要问题,未必立即盗币,但破坏业务正确性 |
| Low | 风格、兼容性、边界或较小风险问题 |
| Informational | 最佳实践建议,不影响安全 |

> 本次审计**未发现 Critical / High / Medium 级别漏洞**。以下为 2 个 Low + 2 个 Informational 级观察。

### 5.2 详细发现

#### [I-01] Defaulting 清算可将 `totalAssets[Collateral]` 清零却保留份额,残留"幽灵份额"稀释后续存款人  —  `Low`

- **位置:** `hooks/defaulting/PartialLiquidationByDefaulting.sol`、`hooks/defaulting/DefaultingSiloLogic.sol`(`_deductDefaultedDebtFromCollateral`)
- **描述:** 在 defaulting(坏账)清算路径中,`_deductDefaultedDebtFromCollateral` 从 `totalAssets[Collateral]` 扣减被取消的债务。极端坏账情形下可把 `totalAssets[Collateral]` 打到 0,而对应 collateral share 的 `totalSupply()` 仍 > 0。接口 `IPartialLiquidationByDefaulting` 的注释已自承该性质:"can reset total assets completely while leaving shares behind … all shares worth 0 and next deposit will lose the value of that left shares"。
- **影响:** 该 silo 完全坏账清空后,残留份额价值归零。**下一个存款人**在 `convertToShares` 时会因残留 `totalSupply` 而被稀释——这是 ERC4626 首存通胀攻击的镜像(此处由会计退化而非攻击者主动制造)。decimal offset(collateral offset=3)提供部分缓解,但未完全消除。初始化时受 `lt+fee<=100%`、`liquidationTargetLtv<=lt` 约束,**非攻击者可主动套利的路径**。
- **复现 / PoC(思路,列为二阶段):**
```text
1. 构造单资产 defaulting 市场,使全部抵押被坏账吃光;
2. 触发 _deductDefaultedDebtFromCollateral,使 totalAssets[Collateral]=0、share totalSupply>0;
3. 新存款人 deposit 一笔资产,观察 convertToShares 受残留 totalSupply 稀释的幅度;
4. 量化 offset=3 的缓解程度(对比有/无 offset 的稀释比例)。
```
- **修复建议:** 在 `totalAssets[Collateral]` 被清零时一并处理(销毁/重置)残留份额,或对 silo 设置最小流动性下限,避免"0 资产 + 非 0 份额"的会计退化态。
- **关联:** SC-Top10 SC02(算术/会计精度类)；CWE-682(不正确的计算)/ CWE-840(业务逻辑错误)。
- **状态:** 接口注释已部分披露,但 `KnownIssues.md` 未单列;作为低危观察补充。**未修复**。

---

#### [I-02] 标准清算中抵押份额先转出、`repay` 在重入保护关闭后执行  —  `Low`

- **位置:** `hooks/liquidation/PartialLiquidation.sol:96-116`
- **描述:** `liquidationCall` 的执行顺序为:① `forwardTransferFromNoChecks` 转走借款人抵押份额 → ② `turnOffReentrancyProtection()`(L114)→ ③ `ISilo(debtConfig.silo).repay(...)`。即**抵押先扣、债务后还**,且还债时全局跨重入锁已关闭(`repay` 自身会重新加锁)。
- **影响:** 在正常 ERC20 资产下**无危害**(`repayDebtAssets` 已被锁定,清算人无法少还)。仅当 `debtConfig.token` 为**可回调资产(ERC777 / 异常 fee-on-transfer)**时,`repay` 内部转账回调理论上存在跨 silo 重入面。协议注释已声明不支持恶意资产,故为受控前提下的设计权衡。
- **复现 / PoC:** N.A.——依赖上架可回调资产(协议显式声明不支持),无法在合规资产集上构造真实利用。
- **修复建议:** 纵深防御——在 silo 上架层面显式禁止 ERC777 / 回调型资产,将"不支持恶意资产"的隐含假设固化为代码层约束。
- **关联:** SC-Top10 SC05(重入)；CWE-841(对行为顺序的不当强制)/ CWE-663(不可重入函数的可重入)。
- **状态:** 设计权衡 + 资产约束;低危。**未修复(建议作为纵深防御加固)**。

---

#### [I-03] DynamicKinkModel `X_MAX` 在极端配置下 `require` revert 而非封顶,导致整段利息被丢弃  —  `Informational`

- **位置:** `interestRateModel/kink/DynamicKinkModel.sol:370`(配 `:451-465` 的 try/catch)
- **描述:** `compoundInterestRate` 算出 `_l.x` 后**先** `require(_l.x <= X_MAX)`(`X_MAX = 11e18`),**之后**才用 `rcompCapPerSecond * T` 对 rcomp 封顶。若 `x` 落在 `[x_at_cap, 11]` 区间,函数直接 revert,上层 `_getCompoundInterestRate` 的 catch 将 `rcomp=0` 返回,Silo 端只更新时间戳、**整段时间的利息归零**。对照 `InterestRateModelV2` 是优雅封顶(返回 `RCOMP_MAX`),两者风险处理**不一致**。
- **影响:** 正常配置不可达(实算:即便 `kmax` 取合法上限、利用率拉满、5 年不计息,`x` 也仅约 0.16,远不及 11)。仅在 owner 把 `kmax` 设到 `UNIVERSAL_LIMIT` 这类近乎不合理的极值、且利息数十年不结算时触发,届时出借方损失被封顶的应计利息。属 `KnownIssues.md` IRM 跳息族在新模型上的具体兑现。
- **复现 / PoC:** N.A.(需 owner-misconfig 至极端值 + 数十年不计息,正常工厂校验下不可达)。
- **修复建议:** 改为"**先封顶后判 X_MAX**",或在 `x > X_MAX` 时返回封顶 rcomp 而非 revert,与 V2 行为保持一致。
- **关联:** SC-Top10 SC09(DoS / 逻辑不一致)；CWE-754(异常条件处理不当)/ CWE-691(控制流管理不当)。
- **状态:** **未修复**(信息级,建议对齐 V2)。

---

#### [I-04] Defaulting 坏账兜底静默吸收差额,无事件区分承担方  —  `Informational`

- **位置:** `hooks/defaulting/DefaultingSiloLogic.sol:50-56`
- **描述:** 真坏账时,超出抵押的债务先从 `daoAndDeployerRevenue` 用 `trySub` 扣减;若协议费也不够,`trySub` 返回 `(false, 0)`,剩余坏账被**静默社会化**(由全体 lender 通过 `totalAssets` 减少承担)。`success` 布尔被丢弃,**无事件区分**"协议费垫付完成"与"lender 兜底社会化"。
- **影响:** 坏账处理逻辑本身**正确**(协议费先垫、不够再社会化),但缺乏可观测性,影响链下监控、风控告警与会计审计。
- **复现 / PoC:** N.A.(逻辑正确,仅可观测性缺口,无安全可利用面)。
- **修复建议:** 在坏账社会化场景发出事件,记录垫付金额与社会化金额、区分承担方。
- **关联:** SC-Top10 SC10(可观测性/监控不足)；CWE-778(日志记录不足)。
- **状态:** **未修复**(信息级)。

---

## 对抗性验证与排除(本所核心方法)★

> 我们对每一个候选发现都做了反向验证——**要么 PoC 坐实,要么读真实代码证伪**。以下是本轮被排除/降级的候选,公开记录以示透明(这是我们与"盖章式审计"的区别)。

| 候选 | 初判 | 验证结论 |
|---|---|---|
| **`borrow` 在 `_token==0` 时跳过流动性检查可凭空造债** | High? | **❌ 伪报**。`SiloLendingLib.borrow` 唯一调用方 `Actions.borrow`(L174)恒传 `debtConfig.token`(真实 ERC20,非 0);`_token=0` 仅出现在 `transitionCollateral`(不转币的内部记账)。外部借款流动性检查恒生效。 |
| **ERC4626 首存/通胀攻击** | High? | **❌ 已防住**。`SiloMathLib._commonConvertTo` 用 offset=3 虚拟份额 + `+1` 虚拟资产;空池强制 `totalAssets=0`。攻击需捐赠约 1000× 受害者存款,经济不成立。 |
| **share↔asset 舍入可被薅** | Med? | **❌ 全表保守**。逐项核对 `Rounding.sol`:存款多收资产/少给份额、借款少给资产/多记债务、LTV 向上——方向一致对协议有利,无方向反转 / 先除后乘精度损失。 |
| **跨 silo 重入绕过** | High? | **❌ 覆盖完整**。写路径一律 `turnOnReentrancyProtection → 改状态 → 校验 → turnOff`;share token `transfer` 也获同一把锁,`mint/burn` 的 after-hook 在锁内仅允许只读重入。before-hook 在锁外执行属受信任 hook receiver 的设计边界。 |
| **杠杆 `onFlashLoan` 忽略 `_initiator`** | Med? | **❌ 安全**。每用户独立 `Clones` 克隆 + `onlyRouter`;恶意 flashloanTarget/swap 只能损害用户自己,残留资金恒归该用户,无可薅(与我们 Twyne 审计 F-9 同类结论)。 |
| **计息 fractions 下溢 / 利息溢出锁仓** | Med? | **❌ 安全**。`applyFractions` 的 integralInterest/Revenue 各 ≤1 且早返回保证 total≥1,不下溢;利息溢出跳过计息不 revert(不锁 silo),有熔断。 |
| 同资产清算 2-wei 高估 / share dust 清算 | — | **与 `KnownIssues.md` 重叠,不计为发现**(dust 清算在 4.x 已用 try/catch 修复)。 |

---

## 二阶段(深审)建议

1. **I-01 PoC:** 构造单资产 defaulting 市场,把 collateral `totalAssets` 清零、保留份额,量化后续存款人被稀释幅度及 offset=3 的缓解程度。
2. **DynamicKink gas 上限:** 对 `KnownIssues.md` 点名的"更贵 IRM 被 OOG 挤兑跳息",在新模型(exp + 多分支 + config 外部读取)上做最坏 calldata 的 gas 量化。
3. **预言机 beforeQuote 时点:** 同 silo 路径(`collateralConfig.silo == debtConfig.silo`)不调用 `callSolvencyOracleBeforeQuote`,确认是否存在依赖 beforeQuote 刷新价的预言机 → 同 silo 场景可能用陈旧价。
4. **范围扩展:** `silo-vaults`、`x-silo`、`silo-oracles`、`incentives` 及各具体 HookReceiver 实现单独审计。

---

## 审计方法论

DuoLaSafe 采用工具 + 人工 + 动态验证的协作式方法:

1. **人工逐行审计(4 个并行审计模块):** 核心入口/配置、借贷数学/份额、偿付/清算、IRM/杠杆/hook 四线并行通读 Solidity 源码,重点关注状态耦合、生命周期管理、结算基准与跨合约授权假设。
2. **业务逻辑建模:** 从储备操纵、清算套利、费用分流、坏账社会化、副作用传播等角度建立攻击模型。
3. **对抗性验证:** 对每个候选发现做反向验证——要么 PoC / 攻击模型坐实,要么读真实代码证伪,并公开记录排除理由(见"对抗性验证与排除"章)。
4. **已知问题去重:** 通读 `KnownIssues.md` 与 `audits/v3/` 既有审计,确保所报均为未单独覆盖的新增观察。
5. **报告输出:** 只保留已验证问题,压缩误报,每个发现与代码路径、影响、修复建议绑定。

---

## 附录:工具与版本

- **审计方式:** 人工逐行 + 4 子审计模块并行 + 对抗性验证。
- **测试/PoC:** Foundry(forge,PoC 思路见各发现"复现"段,I-01 列为二阶段实测)。
- **自动化/形式化:** 本轮未重复全量 Slither / 形式化(已由项目方 **Certora** 形式化验证 + 既有审计覆盖)。
- **已读已知问题:** `KnownIssues.md`(decimals offset 不反映在 `decimals()`、incentives <3.6.0 的 `getProgramName`、IRM gas 跳息、同资产清算 2-wei 高估与 dust、SiloDeployer salt 等)—— 均已去重。
- **既有审计:** `audits/v3/` 含 0xJCN、独立 Security Review(2026-02)、Certora(Dual Oracle 形式化验证)、Cantina、企业级持续审计等。
- **关键假设:** 底层资产非恶意(注释声明不支持 fee-on-transfer / rebasing / 回调资产);hook receiver 由部署者配置且受信任;IRM/Kink config 由可信 owner 经工厂校验设置;transient storage(Cancun)交易结束自动清零。
- **联系方式:** Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)

*© 2026 DuoLaSafe. 本报告仅针对指定 commit(`607535c`)的代码与上述假设;审计不构成对合约绝对安全性的保证,亦不构成投资建议。修改后需重新审计。*
