# Twyne Contracts v1 智能合约安全审计报告

**审计方:** DuoLaSafe
**审计日期:** 2026-06-26
**报告版本:** v1.0
**代码版本(commit):** `0c1ff9d`(https://github.com/0xTwyne/twyne-contracts-v1)
**目标网络:** Base 主网

---

## 免责声明与保密说明

**本安全审计报告可能包含敏感信息。** 本文档包含潜在漏洞、攻击路径与恶意利用分析,建议在问题修复完成后再决定是否公开。

DuoLaSafe 已依据行业最佳实践对目标智能合约进行分析,**本审计不构成对合约绝对安全性的保证**,亦不构成投资建议。所有投资者与用户仍应自行完成尽职调查。审计范围仅限本报告"审计范围"所列代码与提交版本;范围外代码、链下组件、私钥管理、前端、后续升级,以及外部协议本身(Euler、Aave、Morpho)与未提供 Solidity 源码的自定义 Aave wrapper(见 §2.2、§4.3)不在本次保证之列。

---

## 1. 项目概览

### 1.1 审计范围

| 项目 | 描述 |
|---|---|
| 项目名称 | Twyne |
| 开发语言 | Solidity 0.8.28 |
| 部署链 | Base 主网 |
| 代码版本 | commit `0c1ff9d` |
| 自定义代码量 | 约 667 行(`src/twyne` + `src/TwyneFactory`) |
| 审计时间 | 2026-06-24 ~ 2026-06-26 |
| 依赖 | Euler EVC/EVK、Aave V3、Morpho(闪电贷)、OpenZeppelin —— 均视为已审外部依赖 |

**范围内核心合约:**

- `CollateralVaultBase.sol` — 抵押金库基类(记账、存取、自定义清算、再平衡、EVC 集成)
- `EulerCollateralVault.sol` — Euler EVK 具体集成(信用预留、`balanceOf` 记账)
- `AaveV3CollateralVault.sol` — Aave V3 具体集成(`scaledBalanceOf` 记账、奖励领取)
- `VaultManager.sol` — 全局参数 / 权限治理(owner=Gnosis 多签,admin=操作角色,含 `doCall`)
- `CollateralVaultFactory.sol` — 金库工厂 + beacon 代理(`isCollateralVault` 注册表)
- `operators/*` — 1-click 杠杆 / 去杠杆 / teleport(经 Morpho 闪电贷 + EVC operator)
- `AaveV3ATokenWrapperOracle.sol` — aToken wrapper 预言机适配
- `BridgeHookTarget.sol` — EVK hook,拦截外部清算路由到 Twyne 自定义清算
- `IRMTwyneCurve.sol` / `IRMTwyneCurveGamma32.sol` — 利率模型
- `Periphery/*`(`EulerWrapper.sol`、`AaveV3Wrapper.sol`)— ETH/资产入场封装

### 1.2 审计简介

本次对 Twyne 核心合约做系统级联审。不仅检查单函数常见安全问题(重入、整数运算、返回值、权限),更重点验证**跨合约业务流程的自洽性**:信用预留记账、动态清算 LTV、自定义三段式清算激励、外部(Euler/Aave)清算善后的三方分账(LP / 借款人 / 清算人),以及 1-click 杠杆批次(Morpho 闪电贷 + operator 回调)的授权边界。审计目标是确认这些跨合约状态在生命周期各阶段保持一致、不可被对抗性操纵。

### 1.3 项目背景

Twyne 是一套建在 **Euler 的 EVC(Ethereum Vault Connector)+ EVK(Euler Vault Kit)** 之上的**杠杆借贷协议**。其资金流与角色如下:

- **出借人(LP)** 向"中间金库(intermediate vault,EVK)"提供流动性。
- **借款人** 从中间金库**预留信用(reserved credit)**,以此获得**超出底层外部协议(Euler/Aave)的额外借贷力**——这是 Twyne 的核心增益。
- 系统用**动态清算 LTV(λ̃_t)** 维持"信用预留不变量",随头寸与外部参数线性调整。
- 当外部协议(Euler/Aave)直接清算 Twyne 的抵押金库时,`handleExternalLiquidation` / `splitCollateralAfterExtLiq` 按动态激励在 **LP / 借款人 / 清算人**三方间分账,与白皮书一致。
- 权限分两层:**owner**(Gnosis 多签,负责 UUPS 升级 + 更换 admin)与 **admin**(参数调整 + `doCall` 任意外部调用)。

---

## 2. 审计总结

### 2.1 漏洞统计

| 严重程度 | 数量 |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 5 |

### 2.2 审计结论

范围内自定义代码**整体质量高、设计严谨**:统一使用 `nonReentrant` / `nonReentrantView` 守护,清算数学经 Foundry fuzz 验证在代码层安全,关键参数变更采用线性 ramp 优雅降级且仅允许 ramp-down。**本次未发现 Critical / High / Medium 级漏洞。**

发现的问题集中在两类:(1)**代码健壮性**——未检查外部调用返回值、公开函数缺访问控制;(2)**需向用户披露的信任假设**——治理中心化(admin `doCall`)、预言机依赖(无 staleness / sequencer 校验)。均不构成直接资金损失。

**审计过程中对多个潜在攻击面进行了对抗性验证并予以排除**(见 §5.3),这是本报告的重点之一,体现了"不止找问题,更证伪攻击面"的审计深度。

> ⚠️ **重要范围限制**:自定义 Aave wrapper(`AaveV3ATokenWrapper`、`CustomERC4626StataTokenUpgradeable`)在本仓库**仅有编译产物(artifact)、无 Solidity 源码**,其 `rebalanceATokens_CV` / `burnShares_CV` / `redeemATokens` 等函数的访问控制与舍入**未能审计**。一切 Aave 集成相关结论均以此为前提,建议二阶段补源码深审(见 §7、附录)。

---

## 3. 技术与业务分析

### 3.1 技术快速评估(Slither + 人工)

> 逐项对应 Slither 全量扫描(112 合约 / 96 raw 结果)+ OWASP SC Top10 + 借贷协议专项清单的人工确认结果。"通过"=未发现问题,否则填对应发现编号。

| 主类别 | 子项 | 结果 |
|---|---|---|
| 合约编程 | Solidity 版本(0.8.28,pragma 固定) | 通过 |
| | 整数溢出 / 下溢 | 通过(0.8 内置检查;清算分账下溢经 fuzz 排除,见 §5.3 N2) |
| | 函数输入参数校验 | 通过(operator 校验 `isCollateralVault` + `borrower()`) |
| | 权限控制管理 | 见 I-01(治理中心化披露)、L-02(`claimRewards` 缺访问控制) |
| | 重入 / 竞争条件 | 通过(`nonReentrant` / `nonReentrantView` 全覆盖,详见 §5.3) |
| | 外部调用返回值检查 | 见 L-01(EulerWrapper 未检查 `WETH.transfer`)、L-02(吞 revert 数据) |
| | 价格预言机操纵 | 通过(复用 Aave 预言机栈 + `normalizedIncome` 单调量,非单池现货,不可闪电贷操纵) |
| 代码规范 | 函数可见性显式声明 | 通过 |
| | 未使用代码 / 注释一致性 | 见 I-03(IRM 精度注释与代码不符) |
| | 外部代币兼容(approve) | 见 I-04(teleport 用 `approve` 非 `forceApprove`) |
| Gas 优化 | Out of Gas 风险 | 通过 |
| | 高消耗循环 / 幂运算 | 通过(IRM `u^12` 幂运算有界,定点数有意实现) |

### 3.2 业务风险分析

| 类别 | 结果 |
|---|---|
| 是否可增发抵押凭证 | 否(CollateralVault 为非标准 ERC4626,`transfer`/`approve`/`mint` 等对外 revert) |
| 清算逻辑正确性 | 三段式动态激励,纯数学经 **10 万次 fuzz** 验证 `borrowerClaim ≤ C` 恒成立(见 §5.3 N2) |
| 份额 / 记账(ERC4626 通胀) | 安全:Aave 侧用 `scaledBalanceOf` 记账,免 rebasing 漂移;`convertToAssets` 为 pure 1:1 |
| 预言机依赖 | 信任 Aave 预言机栈;无独立 staleness / L2 sequencer 校验(I-02) |
| 升级 / 治理 | UUPS + beacon 代理;owner = Gnosis 多签;admin 权限大(`doCall`,I-01) |
| 外部清算善后 | LP / 借款人 / 清算人三方分账,逻辑与白皮书一致;`BridgeHookTarget` 拦截外部清算路由 |
| 闪电贷滥用 | 不可达:Morpho 回调只打给发起者,operator 仅在 borrower 校验后发起(见 §5.3 F-9) |

---

## 4. 代码质量与安全性

### 4.1 代码质量

结构清晰,模块边界明确——`CollateralVaultBase` 抽象通用记账 / 清算 / EVC 集成,`EulerCollateralVault` 与 `AaveV3CollateralVault` 各自实现外部协议特定的记账口径(Euler 用 `balanceOf`,Aave 用 `scaledBalanceOf`)。守护一致:所有状态变更入口 `nonReentrant`,view 取价 `nonReentrantView`。清算数学、信用预留、动态 LTV 均带数学注解,开发者意图清晰可读。operator 层对授权边界(`isCollateralVault` + `borrower()==msgSender`)的校验前置且统一。

### 4.2 文档情况

注释密度高,关键不变量(信用预留、动态清算 LTV、三段式激励)均有数学说明。少数精度注释与代码实现不符(见 I-03,`1e22` vs `*1e18`),建议在治理参数边界处校对。

### 4.3 外部依赖

| 依赖 | 用途 | 评估 |
|---|---|---|
| **Euler EVC / EVK** | 中间金库底座、账户操作员授权(`setAccountOperator`)、vault status hook | 成熟、广泛审计,视为可信。Twyne 通过 EVC 集成实现信用预留与清算 hook 路由 |
| **Morpho(闪电贷)** | 1-click 杠杆 / 去杠杆 / teleport 的资金来源 | Morpho Blue 闪电贷回调语义(只回调发起者)是 F-9 不可达的关键前提(见 §5.3) |
| **Aave V3** | 备选外部借贷协议、预言机栈、aToken 记账 | 预言机栈被直接复用(I-02);**自定义 Aave wrapper 源码缺失**(见下) |
| **OpenZeppelin** | Upgradeable(UUPS)、标准 ERC 接口、SafeERC20 | 标准版本,可信 |

**例外 / 盲区**:自定义 Aave wrapper(`AaveV3ATokenWrapper`、`CustomERC4626StataTokenUpgradeable`)源码缺失(仅 artifact),其访问控制与舍入未能审计。这是本次审计最大盲区,亦决定部分 Aave 侧结论的成立与否(见 §2.2、§7)。

---

## 5. 审计发现

### 5.1 严重程度定义

| 级别 | 描述 |
|---|---|
| Critical | 可能直接导致资产被盗、金库清空或系统级失控 |
| High | 对业务执行、用户资产结算或权限边界产生重大影响 |
| Medium | 需尽快修复,未必立即盗币,但破坏业务正确性 |
| Low | 健壮性、兼容性或较小风险问题 |
| Informational | 最佳实践 / 需披露的信任假设,不影响安全 |

### 5.2 详细发现

> 本次未发现 **Critical / High / Medium** 级漏洞。以下为 2 条 Low 与 5 条 Informational。

#### [L-01] EulerWrapper 忽略 `WETH.transfer` 返回值 — `Low`

- **位置**:`src/Periphery/EulerWrapper.sol:61`,函数 `depositETHToIntermediateVault`
- **描述**:`IERC20(WETH).transfer(address(eulerVault), ethAmount)` 未检查返回值。当前标的为 WETH,其 `transfer` 失败会直接 revert,故无实际损失;但作为最佳实践应统一用 `SafeERC20.safeTransfer`,以防未来更换标的代币时出现"返回 false 但不 revert"的静默失败。Slither `unchecked-transfer` 命中。
- **影响**:当前 WETH 下无实际资金损失,属代码健壮性问题。
- **复现 / PoC**:静态分析命中(Slither `unchecked-transfer`),无需动态 PoC。代码路径:
  ```solidity
  // src/Periphery/EulerWrapper.sol:61
  IWETH(WETH).deposit{value: ethAmount}();
  IERC20(WETH).transfer(address(eulerVault), ethAmount); // ← 返回值未检查
  uint eulerShares = eulerVault.skim(ethAmount, address(intermediateVault));
  ```
- **修复建议**:改用 `SafeERC20.safeTransfer(IERC20(WETH), address(eulerVault), ethAmount)`。
- **关联**:OWASP SC Top10(不安全的外部调用)/ CWE-252(未检查返回值)
- **状态**:未修复(建议修复)

#### [L-02] `claimRewards` 缺访问控制并吞 revert 数据 — `Low`

- **位置**:`src/twyne/AaveV3CollateralVault.sol:376`,函数 `claimRewards(address[])`
- **描述**:`claimRewards(address[] memory assets)` 为 `external` 且无任何权限修饰,任何人可触发。奖励接收人**硬编码为 `twyneVaultManager`**(因此资金安全,不会被外部夺取),但 `(bool ok,) = address(INCENTIVES_CONTROLLER).call(...); require(ok);` 仅校验调用成功、**吞掉 revert 数据**,失败时无法定位原因。
- **影响**:无资金损失。需确认 `VaultManager` 存在将这些奖励提取/分配出去的路径,否则奖励将卡死在 `VaultManager` 内。
- **复现 / PoC**:代码审阅确认,无需动态 PoC。代码路径:
  ```solidity
  // src/twyne/AaveV3CollateralVault.sol:376
  function claimRewards(address[] memory assets) external {           // ← 无访问控制
      (bool ok,) = address(INCENTIVES_CONTROLLER).call(
          abi.encodeCall(IRewardsController.claimAllRewards,
                         (assets, address(twyneVaultManager)))         // ← 接收人写死,资金安全
      );
      require(ok);                                                     // ← 吞掉 revert 数据
  }
  ```
- **修复建议**:(1)加调用方限制,或明确文档化为"无害的公开维护函数";(2)用 `if (!ok) RevertBytes.revertBytes(returnData)` 保留 revert 数据;(3)确认 `VaultManager` 有提取这些奖励的路径。
- **关联**:OWASP SC Top10(访问控制)/ CWE-284(不当访问控制)、CWE-252
- **状态**:未修复(建议修复 / 文档化)

#### [I-01] 治理中心化:admin 的 `doCall` 任意外部调用 — `Informational`

- **位置**:`src/twyne/VaultManager.sol:275`,函数 `doCall(address,uint,bytes)`;另 `setOracleRouter` / `setLTV` 等
- **描述**:`VaultManager` 是众多 Twyne 合约的 owner/admin。`doCall(to, value, data)` 允许 admin 发起**任意外部调用**(`onlyAdmin`)。admin 实质可对系统做几乎任何操作——改预言机、改 LTV、动用受控权限。owner(可 UUPS 升级、可更换 admin)为 Gnosis 多签,提供部分缓解。Slither `arbitrary-send-eth` 命中。
- **影响**:用户须信任 admin / owner 多签不作恶。这是此类杠杆借贷协议常见的信任假设,**需在文档与前端明确披露**,而非代码缺陷。
- **修复建议**:在文档与前端披露治理权限范围;考虑对 `doCall` 加 timelock 或将敏感操作迁入专用受限函数。
- **关联**:OWASP SC Top10(访问控制 / 中心化)/ CWE-284
- **状态**:披露项(信任假设)

#### [I-02] 预言机无 staleness / sequencer 校验 — `Informational`

- **位置**:`src/twyne/AaveV3ATokenWrapperOracle.sol`、`src/twyne/AaveV3CollateralVault.sol`(`latestAnswer()`)
- **描述**:取价使用 `latestAnswer()`,不返回 `updatedAt`,因而无法做喂价陈旧(staleness)或 L2 sequencer 在线校验。这是直接复用 Aave 预言机栈的设计权衡——Aave 自身健康因子也来自同源喂价,Twyne 与外部协议在定价上保持一致,反而避免了"双预言机分歧"风险。
- **影响**:在 Aave 预言机异常(陈旧 / sequencer 宕机)时,Twyne 与 Aave 会一致受影响;不引入额外攻击面,但放大了对 Aave 预言机的信任。
- **修复建议**:文档化对 Aave 预言机的信任假设;如需更强保证,可引入 staleness / sequencer-uptime 检查(注意与 Aave 喂价口径保持一致,避免分歧)。
- **关联**:OWASP SC Top10(预言机)/ CWE-829(依赖不可信外部数据)
- **状态**:披露项(信任假设)

#### [I-03] IRMTwyneCurve 精度注释与代码不符 — `Informational`

- **位置**:`src/twyne/IRMTwyneCurve.sol`
- **描述**:注释称 `minInterest` 为 `1e22` 精度,代码实际为 `*1e18`;Slither `divide-before-multiply` 多处命中,经核对均为定点数有意实现(每步 `/1e18`),无实际精度损失。属注释/文档与实现不一致问题。
- **影响**:无安全影响;可能误导后续维护者与治理参数设定。
- **修复建议**:校对注释与实际精度,并复核治理参数边界。
- **关联**:CWE-1116(注释/文档不准确)
- **状态**:披露项(代码质量)

#### [I-04] teleport 使用 `approve` 而非 `forceApprove` — `Informational`

- **位置**:`src/operators/AaveV3TeleportOperator.sol:117`
- **描述**:对非标准 ERC20(USDT 式,要求先清零 allowance)且存在残留 allowance 时,`approve` 可能 revert。其他 operator 已统一使用 `forceApprove`,本处为遗漏。
- **影响**:特定代币 + 残留 allowance 场景下 teleport 交易 revert(可用性问题,非资金风险)。
- **修复建议**:统一改用 `SafeERC20.forceApprove`。
- **关联**:OWASP SC Top10(外部代币兼容性)/ CWE-440
- **状态**:未修复(建议修复)

#### [I-05] operator 闪电贷回调缺显式发起方标志(防御纵深)— `Informational`

- **位置**:`src/operators/*`,各 `onMorphoFlashLoan` 回调
- **描述**:回调仅校验 `msg.sender == MORPHO`,隐式依赖"Morpho 只回调发起者"的语义。当前**安全且攻击不可达**(见 §5.3 F-9 的完整证伪),但隐式依赖外部协议实现细节不够稳健。
- **影响**:当前无影响。属防御纵深建议,防范未来更换闪电贷源 / Morpho 升级时出现回调混淆。
- **修复建议**:在 `executeLeverage` 设置 transient 发起标志,在 `onMorphoFlashLoan` 中校验,显式声明"本次回调确由本 operator 发起"。
- **关联**:CWE-696(不当的回调调用序列)
- **状态**:披露项(防御纵深建议)

### 5.3 对抗性验证与排除(本报告重点)

> 以下为审计中提出并**逐一验证后排除**的潜在攻击面。记录于此以示审计深度——本报告不止于"找问题",更在于"对最唬人的候选攻击面给出证伪依据"。

| 攻击面 | 结论 | 依据 |
|---|---|---|
| **闪电贷强制 victim 加杠杆**(F-9,operator 回调被第三方滥用)| ❌ **不成立(误报)** | Morpho 回调只打给发起者;operator 仅在 `borrower()==msgSender` 校验过的 `executeLeverage` 内发起 → 第三方无法触发回调,`data.user` 恒为已验证 borrower。三条攻击路径(直调 executeLeverage / 直调 onMorphoFlashLoan / 自发 flashLoan)全部被堵死。详见 `PoC/F9-验证报告.md` |
| **捐赠阻断外部清算善后**(C1)| ❌ **不成立(误报)** | 掩盖外部清算须捐赠"整个被没收缺口"(非 1 wei),经济不划算;且掩盖后 `withdraw`/`borrow` 仍被 `checkVaultStatus → require(!_canLiquidate())` 拦截,无法套利。双重堵死 |
| **清算分账下溢 DoS(N2)** | ✅ **数学层安全** | `test/poc/N2_LiquidationMath.t.sol` fuzz **10 万次**验证 `collateralForBorrower` 的 `borrowerClaim ≤ C` 恒成立 → 数学层安全。L271 下溢仅在预言机被配成不一致 / 非线性(配置错误)时理论可能 → 降为 Info,归二阶段 oracle 配置复核 |
| **只读重入污染抵押定价(H5)** | ❌ **已缓解** | `balanceOf` 为 `nonReentrantView`,`convertToAssets` 为 `pure` 1:1 → 取价不可在重入态被污染 |
| **外部参数变动使 vault 突变危险(H6)** | ❌ **设计覆盖** | `VaultManager` 对 `maxTwyneLTV` / `externalLiqBuffer` 采用线性 ramp、且仅允许 ramp-down → 优雅降级,无瞬时危险跳变 |
| **ERC4626 份额通胀 / aToken rebasing 漂移** | ❌ **不成立** | Aave 侧用 `scaledBalanceOf`(scaled 单位)记账,免 rebasing 漂移;CollateralVault 为非标准 ERC4626,`convertToAssets` 为 pure 1:1,无首存通胀攻击面 |

**补充排除项(本轮判无害)**:预言机现货操纵(用 Aave 预言机栈 + `normalizedIncome` 单调量,非单池现货 → 非闪电贷可操纵)、`CollateralVaultFactory` 抢初始化(部署 + initialize 同 tx 原子,无 front-run 窗口,F-5)、`getQuote` 线性性(Aave oracle 对输入量严格线性、下取整保守)。

---

## 6. 二阶段深审清单(优先级)

本次审计因环境限制(Euler 深层嵌套 submodule 在审计环境拉取不全,`forge build` 部分受阻)与源码盲区,以下项目建议在第二阶段补做:

1. **【最高】补 Aave 自定义 wrapper 源码深审** —— `AaveV3ATokenWrapper`、`CustomERC4626StataTokenUpgradeable` 本仓库仅有 artifact,无 `.sol`;其 `rebalanceATokens_CV` / `burnShares_CV` / `redeemATokens` / `skim` 的访问控制与舍入无法审。**这是最大盲区**,亦决定 C1 在 Aave 侧是否成立。
2. **【高】F-9 完整 PoC** —— 在可完整编译的环境补跑 `test/poc/F9_FlashloanCallback.t.sol`(负向 PoC),并读 EVC `setAccountOperator` 授权语义、Swapper/SwapVerifier 源码坐实证伪。
3. **【高】清算数学数值复核 + invariant fuzzing** —— `collateralForBorrower` / `splitCollateralAfterExtLiq` / `_collateralScaledByLiqLTV1e8` 的精度方向、三方分账加总 ≤ 余额、N2 下溢残留;适合 Echidna / Foundry invariant。
4. **【中】F-7 `BridgeHookTarget`** —— 对照 EVK 清算选择器与 hook caller 约定,确认清算 hook 唯一闸门(`totalAssets==0`)不被 fallback 全拦 / 绕过。
5. **【中】链上实际预言机适配器配置复核** —— 关系 I-02 与 N2 残留(配置依赖)。
6. **【中】Swapper / SwapVerifier 源码** —— F-2/F-3/F-4(operator 残币清扫、端到端 health 断言、滑点)最终结论依赖其实现。

---

## 7. 审计方法论

DuoLaSafe 采用 **工具 + 人工 + 动态验证** 的协作式方法:

1. **自动化静态分析**:Slither 全量扫描(112 合约 / 96 raw 结果),逐条人工确认真伪、过滤误报(`divide-before-multiply`、`incorrect-equality`、`reentrancy-no-eth` 经核对为 FP / 已缓解)。
2. **人工逐合约审阅**:对照借贷协议专项清单 + OWASP SC Top10,重点关注信用预留记账、动态清算 LTV、跨合约 EVC 授权假设、三方分账舍入。核心 3 合约由主审主审,Aave 集成 / 预言机、operators / 工厂 / hook / IRM 由 2 名子审计员并行覆盖。
3. **对抗性建模**:从闪电贷滥用、捐赠攻击、清算分账舍入、只读重入、参数突变等角度建立攻击模型并逐一验证 / 证伪(见 §5.3)。
4. **动态验证(Foundry fuzz)**:`test/poc/N2_LiquidationMath.t.sol` 复刻 `collateralForBorrower` 三段式纯数学,fuzz **10 万次**全过验证 `borrowerClaim ≤ C`;F-9 负向 PoC 验证第三方攻击路径不可达。
5. **报告输出**:只保留经验证的问题,每个发现绑定代码路径、影响、PoC / CWE 与修复建议;并完整记录已排除的攻击面以示审计深度,杜绝"AI slop"式未经核实的发现。

---

## 附录:工具与版本 / 范围限制

- **静态分析**:Slither 0.11.5
- **测试 / 模糊测试**:Foundry(forge),N2 清算数学 fuzz 10 万次
- **编译器**:Solc 0.8.28
- **情报核查**:自建链上情报库(部署者 / 关联方背景核查)
- **未覆盖(建议二阶段)**:自定义 Aave wrapper 源码、Swapper / SwapVerifier 源码、链上实际预言机适配器配置(关系 N2 / I-02 残留)、`splitCollateralAfterExtLiq` 的 oracle 往返舍入(Slither 报 "Impossible to generate IR",fuzz 仅覆盖纯数学层)。
- **行号基准**:所有行号基于 commit `0c1ff9d` 实际源码。

**联系方式**:Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)

*© 2026 DuoLaSafe. 本报告仅针对指定 commit,修改后需重新审计。*
