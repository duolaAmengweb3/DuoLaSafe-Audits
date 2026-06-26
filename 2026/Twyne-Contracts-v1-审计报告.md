# Twyne Contracts v1 智能合约安全审计报告

**审计方:** DuoLaSafe
**审计日期:** 2026-06-26
**报告版本:** v1.0
**代码版本(commit):** `0c1ff9d`(https://github.com/0xTwyne/twyne-contracts-v1)
**目标网络:** Base 主网

---

## 免责声明与保密说明

本安全审计报告可能包含敏感信息,建议在问题修复完成后再决定是否公开。DuoLaSafe 已依据行业最佳实践对目标智能合约进行分析,**本审计不构成对合约绝对安全性的保证**,亦不构成投资建议。审计范围仅限下列代码与提交版本;范围外代码、链下组件、私钥管理、预言机/外部协议(Euler、Aave、Morpho)本身、以及自定义 Aave wrapper(未提供源码,见 §4.3)不在本次保证之列。所有用户与投资者仍应自行完成尽职调查。

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
| 依赖 | Euler EVC/EVK、Aave V3、Morpho(闪电贷)、OpenZeppelin —— 均视为已审外部依赖 |

**范围内核心合约:**
- `CollateralVaultBase.sol` — 抵押金库基类(记账、存取、自定义清算、再平衡、EVC 集成)
- `EulerCollateralVault.sol` / `AaveV3CollateralVault.sol` — Euler / Aave 具体集成
- `VaultManager.sol` — 全局参数 / 权限治理(owner=多签,admin=操作角色)
- `CollateralVaultFactory.sol` — 金库工厂 + beacon 代理
- `operators/*` — 1-click 杠杆 / 去杠杆 / teleport(经 Morpho 闪电贷)
- `AaveV3ATokenWrapperOracle.sol`、`BridgeHookTarget.sol`、`IRMTwyneCurve*.sol`、`Periphery/*`

### 1.2 审计简介
本次对 Twyne 核心合约做系统级联审,不仅检查单函数常见安全问题,更重点验证跨合约业务流程的自洽性:信用预留、动态清算 LTV、自定义三段式清算激励、外部(Euler/Aave)清算善后的三方分账、以及 1-click 杠杆批次。

### 1.3 项目背景
Twyne 建在 Euler 的 EVC(Ethereum Vault Connector)+ EVK(Euler Vault Kit)之上:出借人向"中间金库"提供流动性,借款人**预留信用**以获得超出外部协议(Euler/Aave)的额外借贷力。系统用**动态清算 LTV(λ̃_t)**维持信用预留不变量;当外部协议直接清算 vault 时,`handleExternalLiquidation` 按动态激励在 LP / 借款人 / 清算人间分账。

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
范围内自定义代码**整体质量高、设计严谨**:统一使用 `nonReentrant`/`nonReentrantView` 守护,清算数学经 fuzz 验证在代码层安全,关键参数变更采用线性 ramp 优雅降级。**本次未发现 Critical/High/Medium 级漏洞。** 发现的问题集中在代码健壮性(未检查返回值、缺访问控制)与需向用户披露的信任假设(治理中心化、预言机依赖)。

**审计过程中对多个潜在攻击面进行了对抗性验证并予以排除**(见 §5.3),这是本报告的重点之一。

> ⚠️ **重要范围限制**:自定义 Aave wrapper(`AaveV3ATokenWrapper`、`CustomERC4626StataTokenUpgradeable`)在本仓库**仅有编译产物、无 Solidity 源码**,其 `rebalanceATokens_CV` / `burnShares_CV` / `redeemATokens` 等函数的访问控制与舍入**未能审计**。Aave 集成相关结论以此为前提。

---

## 3. 技术与业务分析

### 3.1 技术快速评估(Slither + 人工)
| 主类别 | 子项 | 结果 |
|---|---|---|
| 合约编程 | Solidity 版本(0.8.28) | 通过 |
| | 整数溢出/下溢 | 通过(0.8 内置检查) |
| | 重入 / 竞争条件 | 通过(`nonReentrant`/`nonReentrantView` 全覆盖,详见 §5.3) |
| | 权限控制管理 | 见 I-01(治理中心化披露) |
| | 外部调用返回值检查 | 见 L-01(EulerWrapper 未检查 WETH.transfer) |
| | 价格预言机操纵 | 通过(复用 Aave 预言机栈 + normalizedIncome,非单池现货,不可闪电贷操纵) |
| 代码规范 | 函数可见性显式声明 | 通过 |
| Gas 优化 | 高消耗循环 / OOG | 通过(IRM 幂运算有界) |

### 3.2 业务风险分析
| 类别 | 结果 |
|---|---|
| 是否可增发抵押凭证 | 否(CollateralVault 非标准 ERC20,transfer/approve 等 revert) |
| 清算逻辑正确性 | 三段式动态激励,纯数学经 10万次 fuzz 验证 `borrowerClaim ≤ C`(见 §5.3 N2) |
| 份额/记账(ERC4626 通胀) | 安全:Aave 侧用 scaled 单位记账,免 rebasing 漂移 |
| 预言机依赖 | 信任 Aave 预言机栈;无独立 staleness/sequencer 校验(I-02) |
| 升级/治理 | UUPS + beacon 代理;owner=Gnosis 多签,admin 权限大(I-01) |
| 外部清算善后 | LP/借款人/清算人三方分账,逻辑与白皮书一致 |

---

## 4. 代码质量与安全性
### 4.1 代码质量
结构清晰,模块边界明确(base 抽象 + Euler/Aave 具体实现),注释充分,开发者意图可从注释读出(信用预留、动态 LTV、清算激励均有数学注解)。
### 4.2 文档情况
注释密度高;少数精度注释与代码不符(见 I-03)。
### 4.3 外部依赖
Euler EVC/EVK、Aave V3、Morpho、OpenZeppelin(Upgradeable/standard)—— 均为成熟、被广泛审计的依赖,视为可信。**例外**:自定义 Aave wrapper 源码缺失(见 §2.2 警告)。

---

## 5. 审计发现

### 5.1 严重程度定义
| 级别 | 描述 |
|---|---|
| Critical | 可能直接导致资产被盗、金库清空或系统级失控 |
| High | 对业务执行、用户资产结算或权限边界产生重大影响 |
| Medium | 需尽快修复,未必立即盗币,但破坏业务正确性 |
| Low | 健壮性、兼容性或较小风险问题 |
| Informational | 最佳实践 / 需披露的信任假设 |

### 5.2 详细发现

#### [L-01] EulerWrapper 忽略 `WETH.transfer` 返回值 — `Low`
- **位置**:`src/Periphery/EulerWrapper.sol#61`(`depositETHToIntermediateVault`)
- **描述**:`IERC20(WETH).transfer(address(eulerVault), ethAmount)` 未检查返回值。WETH 本身 transfer 失败会 revert,但作为最佳实践应统一用 `SafeERC20.safeTransfer`,避免未来更换代币时静默失败。(Slither `unchecked-transfer` 命中)
- **影响**:当前 WETH 下无实际损失;健壮性问题。
- **修复建议**:改用 `SafeERC20.safeTransfer`。

#### [L-02] `claimRewards` 缺访问控制并吞 revert 数据 — `Low`
- **位置**:`src/twyne/AaveV3CollateralVault.sol#376`
- **描述**:`claimRewards(address[])` 为 `external` 无权限修饰,任何人可触发;奖励接收人**硬编码为 `twyneVaultManager`**(故资金安全),但 `(bool ok,) = ...call(...)` 仅校验成功、吞掉 revert 数据。
- **影响**:无资金损失;需确认 VaultManager 有提取这些奖励的路径,否则奖励将卡死在 VaultManager。
- **修复建议**:加调用方限制(或明确文档化为无害的公开维护函数),并保留 revert 数据。

#### [I-01] 治理中心化:admin 的 `doCall` 任意外部调用 — `Informational`
- **位置**:`src/twyne/VaultManager.sol#275`(`doCall`),另 `setOracleRouter`/`setLTV` 等
- **描述**:`VaultManager` 是众多 Twyne 合约的 owner/admin;`doCall(to,value,data)` 允许 admin 发起任意外部调用。admin 实质可对系统做几乎任何操作(改预言机、改 LTV、动用权限)。owner(可 UUPS 升级、可换 admin)为 Gnosis 多签,部分缓解。(Slither `arbitrary-send-eth` 命中)
- **影响**:用户须信任 admin/owner 多签不作恶。属此类协议常见的信任假设,**需在文档与前端明确披露**。

#### [I-02] 预言机无 staleness / sequencer 校验 — `Informational`
- **位置**:`AaveV3ATokenWrapperOracle.sol`、`AaveV3CollateralVault.sol`(`latestAnswer()`)
- **描述**:取价使用 `latestAnswer()`,不返回 `updatedAt`,无法做喂价陈旧 / L2 sequencer 在线校验。系直接复用 Aave 预言机栈的设计权衡(Aave 自身健康因子亦同源)。
- **修复建议**:文档化对 Aave 预言机的信任假设;如需更强保证,考虑引入 staleness/sequencer 检查。

#### [I-03] IRMTwyneCurve 精度注释不符 — `Informational`
- **位置**:`src/twyne/IRMTwyneCurve.sol`
- **描述**:注释称 `minInterest` 为 `1e22` 精度,代码为 `*1e18`;Slither `divide-before-multiply` 命中多处,均为定点数有意实现(每步 `/1e18`),无实际精度损失。建议校对注释与治理参数边界。

#### [I-04] teleport 使用 `approve` 而非 `forceApprove` — `Informational`
- **位置**:`src/operators/AaveV3TeleportOperator.sol#117`
- **描述**:对非标准 ERC20(USDT 式)且存在残留 allowance 时,`approve` 可能 revert。建议统一 `forceApprove`(其他 operator 已用)。

#### [I-05] operator 闪电贷回调缺显式发起方标志(防御纵深)— `Informational`
- **位置**:`src/operators/*.onMorphoFlashLoan`
- **描述**:回调仅校验 `msg.sender == MORPHO`,隐式依赖"Morpho 只回调发起者"的语义(当前安全,见 §5.3 F-9)。建议在 `executeLeverage` 设 transient 发起标志、回调中校验,以防未来更换闪电贷源时出现回调混淆。

### 5.3 对抗性验证与排除(本报告重点)
> 以下为审计中提出并**逐一验证后排除**的潜在攻击面。记录于此以示审计深度。

| 攻击面 | 结论 | 依据 |
|---|---|---|
| **闪电贷强制 victim 加杠杆**(operator 回调被第三方滥用)| ❌ **不成立** | Morpho 回调只打给发起者;operator 仅在 `borrower()==msgSender` 校验过的 `executeLeverage` 内发起 → 第三方无法触发回调,`data.user` 恒为已验证 borrower。详见 `PoC/F9-验证报告.md` |
| **捐赠阻断外部清算善后** | ❌ **不成立** | 掩盖外部清算须捐赠"整个被没收缺口"(非 1 wei),经济不划算;且掩盖后 `withdraw/borrow` 仍被 `checkVaultStatus → require(!_canLiquidate())` 拦截,无法套利 |
| **清算分账下溢 DoS(N2)** | ✅ **数学层安全** | `test/poc/N2_LiquidationMath.t.sol` fuzz **10万次** 验证 `collateralForBorrower` 的 `borrowerClaim ≤ C` 恒成立;残留仅在预言机被配成不一致时理论可能(配置依赖) |
| **只读重入污染抵押定价** | ❌ **已缓解** | `balanceOf` 为 `nonReentrantView`,`convertToAssets` 为 `pure` 1:1 |
| **外部参数变动使 vault 突变危险** | ❌ **设计覆盖** | VaultManager 对 maxTwyneLTV/externalLiqBuffer 采用线性 ramp、且仅允许 ramp-down |
| **ERC4626 份额通胀 / aToken rebasing 漂移** | ❌ **不成立** | Aave 侧用 scaled 单位记账,免 rebasing;非标准 ERC4626 |

---

## 6. 审计方法论
DuoLaSafe 采用 工具 + 人工 + 动态验证 的协作式方法:
1. **自动化静态分析**:Slither 全量扫描(112 合约 / 96 结果),逐条人工确认真伪(过滤误报)。
2. **人工逐合约审阅**:对照借贷协议专项清单 + OWASP SC Top10,重点关注信用预留记账、动态清算 LTV、跨合约 EVC 授权假设。
3. **对抗性建模**:从闪电贷滥用、捐赠攻击、清算分账舍入、只读重入等角度建立攻击模型并验证(见 §5.3)。
4. **动态验证**:Foundry fuzz(`test/poc/N2_LiquidationMath.t.sol`,10万次)验证清算数学;F-9 负向 PoC 验证攻击不可达。
5. **报告输出**:只保留经验证的问题,每个发现绑定代码路径、影响与修复建议;并记录已排除的攻击面以示深度。

---

## 附录:工具与版本 / 范围限制
- 静态分析:Slither 0.11.5 · 测试/fuzz:Foundry(forge)· 编译器:Solc 0.8.28
- **未覆盖**(建议二阶段):自定义 Aave wrapper 源码、Swapper/SwapVerifier 源码、链上实际预言机适配器配置(关系 N2/I-02 残留)、`splitCollateralAfterExtLiq` 的 oracle 往返舍入(Slither 无法生成 IR,fuzz 仅覆盖纯数学)。
- 所有行号基于 commit `0c1ff9d` 实际源码。

*© 2026 DuoLaSafe. 本报告仅针对指定 commit,修改后需重新审计。*
