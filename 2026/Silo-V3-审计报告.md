# Silo V3 (silo-core) 安全审计报告

**审计方**:DuoLaSafe · Web3 安全审计 / 链上取证
**标的**:Silo Finance V3 — `silo-core`
**仓库**:`silo-finance/silo-contracts-v3` @ commit `607535c`
**链**:多链(EVM)
**审计周期**:2026-06
**方法**:人工逐行审计(4 个并行审计模块)+ 对抗性验证(每个候选发现 PoC 坐实或手撕证伪)+ 对照 `KnownIssues.md` 去重。
**联系**:Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)

---

## 1. 执行摘要

Silo V3 是隔离市场(isolated-market)借贷协议:每个 Silo 是一对相互隔离的借贷市场,通过 `SiloConfig` 协调一对 silo 之间的抵押/债务关系,核心逻辑集中在 `silo-core/contracts/lib/` 的若干库中。

本次审计聚焦 **silo-core 的安全关键核心**:核心入口与配置、借贷数学与份额转换、偿付能力与清算、利率模型与杠杆。

> **重要背景(诚实披露)**:Silo V3 在本次审计前已经过**多家顶级机构审计 + Certora 形式化验证 + 企业级持续审计**(报告见仓库 `audits/v3/`),并维护了一份 `KnownIssues.md`。对这样的标的,发现新的高危/严重漏洞的概率本就极低。本报告的价值在于:**一次独立、可复核、带对抗性验证的核心范围复审**,以及对若干**已有审计与 KnownIssues 未单独覆盖**的低危/信息级观察的补充。

### 结论

| 严重度 | 数量 |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 2 |

核心不变量(总抵押价值 ≥ 总负债价值)的保护严密:重入锁覆盖完整、计息时点正确、份额↔资产舍入全表对协议保守、LTV 计算无方向性偏差、清算无"多拿抵押/少还债"套利路径、ERC4626 通胀攻击被 decimal offset + 虚拟资产正确防住。**未发现可直接导致资金损失的漏洞。**

---

## 2. 审计范围

| 模块 | 文件 |
|---|---|
| 核心入口/配置/分发 | `Silo.sol`、`SiloConfig.sol`、`lib/Actions.sol`、`hooks/_common/TransientReentrancy.sol`、`utils/CrossReentrancyGuard.sol`、`utils/ShareToken*.sol` |
| 借贷数学/份额/舍入 | `lib/SiloLendingLib.sol`、`lib/SiloMathLib.sol`、`lib/SiloERC4626Lib.sol`、`lib/Rounding.sol`、`lib/SiloStdLib.sol` |
| 偿付能力/清算 | `lib/SiloSolvencyLib.sol`、`hooks/liquidation/PartialLiquidation.sol`、`hooks/defaulting/*`、`PartialLiquidationLib/ExecLib.sol` |
| 利率模型/杠杆/Hook | `interestRateModel/InterestRateModelV2.sol`、`interestRateModel/kink/DynamicKinkModel.sol`、`leverage/LeverageUsingSiloFlashloan.sol`、`hooks/SiloHookV3.sol` |

**范围外**(本轮未审):`silo-vaults`、`x-silo`、`silo-oracles`、`incentives`、部署脚本;以及自动化静态分析/形式化验证(已由项目方 Certora + 既有审计覆盖)。

**去重基准**:已通读 `KnownIssues.md`,其登记的 decimals offset 不反映在 `decimals()`、incentives <3.6.0 的 `getProgramName`、IRM gas-exhaustion 跳息、同资产清算 2-wei 高估、share dust 清算等,**均不作为本报告发现**。

---

## 3. 发现详情

### I-01 [Low] Defaulting 清算可将 `totalAssets[Collateral]` 清零却保留份额,残留"幽灵份额"稀释后续存款人

- **位置**:`hooks/defaulting/PartialLiquidationByDefaulting.sol`、`hooks/defaulting/DefaultingSiloLogic.sol`(`_deductDefaultedDebtFromCollateral`)
- **描述**:在 defaulting(坏账)清算路径中,`_deductDefaultedDebtFromCollateral` 从 `totalAssets[Collateral]` 扣减被取消的债务,极端坏账情形下可把 `totalAssets[Collateral]` 打到 0,而对应的 collateral share `totalSupply()` 仍 > 0。接口注释 `IPartialLiquidationByDefaulting` 已自承认该性质:"can reset total assets completely while leaving shares behind … all shares worth 0 and next deposit will lose the value of that left shares"。
- **影响**:该 silo 完全坏账清空后,残留份额价值归零,**下一个存款人** `convertToShares` 时会因残留 `totalSupply` 而被稀释(首存通胀攻击的镜像)。decimal offset(collateral=3)提供部分缓解,但未完全消除。非攻击者可主动套利的路径(费率/LT 在初始化时受 `lt+fee<=100%`、`liquidationTargetLtv<=lt` 约束)。
- **建议**:在 `totalAssets[Collateral]` 被清零时一并处理(销毁/重置)残留份额,或对 silo 设置最小流动性下限,避免"0 资产 + 非 0 份额"会计退化态。
- **状态**:接口注释已部分披露,但 `KnownIssues.md` 未单列;作为低危观察补充。

### I-02 [Low] 标准清算中抵押份额先转出、`repay` 在重入保护关闭后执行

- **位置**:`hooks/liquidation/PartialLiquidation.sol:96-116`
- **描述**:`liquidationCall` 顺序为 ① `forwardTransferFromNoChecks` 转走借款人抵押份额 → ② `turnOffReentrancyProtection()`(L114)→ ③ `ISilo(debtConfig.silo).repay(...)`。即抵押先扣、债务后还,且还债时全局跨重入锁已关闭(`repay` 自身会重新加锁)。
- **影响**:正常 ERC20 下无危害(`repayDebtAssets` 已锁定,清算人无法少还)。仅当 `debtConfig.token` 为**可回调资产(ERC777 / 异常 fee-on-transfer)**时,`repay` 内部转账回调理论上存在跨 silo 重入面。
- **建议**:纵深防御 —— 在 silo 上架层面禁止 ERC777/回调型资产(协议注释已声明不支持恶意资产,此为显式化)。
- **状态**:设计权衡 + 资产约束;低危。

### I-03 [Informational] DynamicKinkModel `X_MAX` 在极端配置下 `require` revert 而非封顶,导致整段利息被丢弃

- **位置**:`interestRateModel/kink/DynamicKinkModel.sol:370`(配 `:451-465` try/catch)
- **描述**:`compoundInterestRate` 算出 `_l.x` 后先 `require(_l.x <= X_MAX)`(X_MAX=11e18),**之后**才用 `rcompCapPerSecond * T` 封顶 rcomp。若 `x` 落在 [x_at_cap, 11] 区间,函数直接 revert,上层 `_getCompoundInterestRate` 的 catch 把 `rcomp=0` 返回,Silo 端只更新时间戳、**整段时间利息归零**。对照 `InterestRateModelV2` 是优雅封顶(返回 RCOMP_MAX),两者风险处理不一致。
- **影响**:正常配置不可达(实算:即便 kmax 取合法上限、利用率拉满、5 年不计息,x 也仅约 0.16,远不及 11);仅在 owner 把 kmax 设到 `UNIVERSAL_LIMIT` 这类近乎不合理极值且利息数十年不结算时触发,届时出借方损失被封顶的应计利息。属 `KnownIssues.md` IRM 跳息族在新模型上的具体兑现。
- **建议**:改为"先封顶后判 X_MAX",或 `x>X_MAX` 时返回封顶 rcomp 而非 revert,与 V2 行为一致。

### I-04 [Informational] Defaulting 坏账兜底静默吸收差额,无事件区分承担方

- **位置**:`hooks/defaulting/DefaultingSiloLogic.sol:50-56`
- **描述**:真坏账时超出抵押的债务先从 `daoAndDeployerRevenue` 用 `trySub` 扣减;若协议费也不够,`trySub` 返回 `(false, 0)`,剩余坏账被静默社会化(由全体 lender 通过 `totalAssets` 减少承担)。`success` 布尔被丢弃,无事件区分"协议费垫付完"与"lender 兜底"。
- **影响**:坏账处理逻辑本身正确(协议费先垫、不够再社会化),但缺乏可观测性,影响链下监控与会计审计。
- **建议**:对坏账社会化场景发出事件,记录垫付/社会化金额。

---

## 4. 对抗性验证与排除(本所核心方法)

> 我们对每一个候选发现都做了反向验证 —— **要么 PoC 坐实,要么读真实代码证伪**。以下是本轮被排除/降级的候选,公开记录以示透明(这是我们与"盖章式审计"的区别)。

| 候选 | 初判 | 验证结论 |
|---|---|---|
| **`borrow` 在 `_token==0` 时跳过流动性检查可凭空造债** | High? | **❌ 伪报**。`SiloLendingLib.borrow` 唯一调用方 `Actions.borrow`(L174)恒传 `debtConfig.token`(真实 ERC20,非 0);`_token=0` 仅出现在 `transitionCollateral`(不转币的内部记账)。外部借款流动性检查恒生效。 |
| **ERC4626 首存/通胀攻击** | High? | **❌ 已防住**。`SiloMathLib._commonConvertTo` 用 offset=3 虚拟份额 + `+1` 虚拟资产;空池强制 `totalAssets=0`。攻击需捐赠约 1000×受害者存款,经济不成立。 |
| **share↔asset 舍入可被薅** | Med? | **❌ 全表保守**。逐项核对 `Rounding.sol`:存款多收资产/少给份额、借款少给资产/多记债务、LTV 向上 —— 方向一致对协议有利,无方向反转/先除后乘精度损失。 |
| **跨 silo 重入绕过** | High? | **❌ 覆盖完整**。写路径一律 `turnOnReentrancyProtection`→改状态→校验→`turnOff`;share token `transfer` 也获同一把锁,`mint/burn` 的 after-hook 在锁内仅允许只读重入。before-hook 在锁外执行属受信任 hook receiver 的设计边界。 |
| **杠杆 `onFlashLoan` 忽略 `_initiator`** | Med? | **❌ 安全**。每用户独立 `Clones` 克隆 + `onlyRouter`;恶意 flashloanTarget/swap 只能损害用户自己,残留资金恒归该用户,无可薅(与我们 Twyne 审计 F-9 同类结论)。 |
| **计息 fractions 下溢 / 利息溢出锁仓** | Med? | **❌ 安全**。`applyFractions` 的 integralInterest/Revenue 各 ≤1 且早返回保证 total≥1,不下溢;利息溢出跳过计息不 revert(不锁 silo),有熔断。 |
| 同资产清算 2-wei 高估 / share dust 清算 | — | **与 `KnownIssues.md` 重叠,不计为发现**(dust 清算在 4.x 已用 try/catch 修复)。 |

---

## 5. 二阶段(深审)建议

1. **I-01 PoC**:构造单资产 defaulting 市场,把 collateral `totalAssets` 清零、保留份额,量化后续存款人被稀释幅度及 offset=3 的缓解程度。
2. **DynamicKink gas 上限**:对 `KnownIssues.md` 点名的"更贵 IRM 被 OOG 挤兑跳息",在新模型(exp + 多分支 + config 外部读取)做最坏 calldata 的 gas 量化。
3. **预言机 beforeQuote 时点**:同 silo 路径(`collateralConfig.silo==debtConfig.silo`)不调用 `callSolvencyOracleBeforeQuote`,确认是否存在依赖 beforeQuote 刷新价的预言机 → 同 silo 场景可能用陈旧价。
4. **范围扩展**:`silo-vaults`、`x-silo`、`silo-oracles`、`incentives` 及各具体 HookReceiver 实现单独审计。

---

## 6. 附录

- **已读已知问题**:`KnownIssues.md`(decimals offset、getProgramName、IRM gas 跳息、清算 2-wei 高估与 dust、SiloDeployer salt 等)—— 均已去重。
- **既有审计**:`audits/v3/` 含 0xJCN、独立 Security Review(2026-02)、Certora(Dual Oracle 形式化验证)、Cantina、企业级持续审计等。
- **关键假设**:底层资产非恶意(代码注释声明不支持 fee-on-transfer/rebasing/回调资产);hook receiver 由部署者配置且受信任;IRM/Kink config 由可信 owner 经工厂校验设置;transient storage(Cancun)交易结束自动清零。
- **覆盖与局限**:本轮为核心范围人工 + 对抗性验证,未对 90M monorepo 全量编译运行 Slither(自动化/形式化由 Certora + 既有审计覆盖)。

---

*本报告基于指定 commit 的代码与上述假设;审计不构成对未来代码变更的安全保证,亦不构成投资建议。*
*© 2026 DuoLaSafe · 公开可验证 · Telegram [@dsa885](https://t.me/dsa885)*
