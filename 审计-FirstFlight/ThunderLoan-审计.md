# ThunderLoan 闪电贷协议 · 智能合约安全审计报告

> DuoLaSafe 智能合约审计 · CodeHawks ai-thunder-loan · 2026-06-27
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 1. 概述

ThunderLoan 是一个借鉴 Aave / Compound 的闪电贷协议:流动性提供者(LP)`deposit` 底层资产、获得带息的 `AssetToken`;用户在单笔交易内借出资金并支付小额手续费,手续费转化为 LP 收益(体现为 `AssetToken` 兑换率上升)。协议采用 UUPS 可升级代理,计划从 `ThunderLoan` 升级到 `ThunderLoanUpgraded`,升级本身也在审计范围内。

本次审计对范围内全部合约进行人工审计,并对每一个 High/Critical 级发现编写了**可运行的 Foundry PoC**,全部 `forge test` **PASS**。**本报告只列出能用 PoC 坐实的漏洞,不含任何臆测性发现。**

### 范围

- Commit:`e8ce05f5530ca965165d41547b289604f873fdf6`
- 链:ETH;Solc:0.8.20
- 范围内文件:
  - `src/interfaces/IFlashLoanReceiver.sol`、`IPoolFactory.sol`、`ITSwapPool.sol`、`IThunderLoan.sol`
  - `src/protocol/AssetToken.sol`
  - `src/protocol/OracleUpgradeable.sol`
  - `src/protocol/ThunderLoan.sol`
  - `src/upgradedProtocol/ThunderLoanUpgraded.sol`

### 发现汇总

| 编号 | 严重度 | 标题 |
|------|--------|------|
| H-01 | High | `deposit()` 错误地把"未发生的手续费"计入兑换率,破坏存款/赎回会计,可多赎本金 |
| H-02 | High(升级后 Critical) | 升级到 `ThunderLoanUpgraded` 存在存储槽冲突,`s_flashLoanFee` 被旧 `s_feePrecision` 覆盖,手续费参数被悄然篡改 |
| H-03 | High | 手续费基于可被闪电操纵的 TSwap 现货预言机定价,无 TWAP/校验,攻击者可把手续费压到 0 实现免费闪电贷 |

PoC 文件:`/tmp/ff-thunderloan/test/unit/DuoLaSafePoC.t.sol`(自包含 mock,3 条测试全部 PASS)。

---

## 2. 发现详情

### H-01 · `deposit()` 把未发生的手续费计入兑换率,破坏会计,可多赎本金

- **严重度:** High
- **位置:** `src/protocol/ThunderLoan.sol:153-154`(`deposit` 内)

```solidity
function deposit(IERC20 token, uint256 amount) external ... {
    AssetToken assetToken = s_tokenToAssetToken[token];
    uint256 exchangeRate = assetToken.getExchangeRate();
    uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
    emit Deposit(msg.sender, token, amount);
    assetToken.mint(msg.sender, mintAmount);
    uint256 calculatedFee = getCalculatedFee(token, amount); // ❌
    assetToken.updateExchangeRate(calculatedFee);            // ❌ 把"假手续费"计入兑换率
    token.safeTransferFrom(msg.sender, address(assetToken), amount);
}
```

- **根因:** 兑换率(`s_exchangeRate`)的语义是"每个 AssetToken 值多少底层资产",**只应在真实闪电贷手续费到账时上升**。但 `deposit` 在每次存款时都按存款额计算一个 `calculatedFee` 并调用 `updateExchangeRate`,而这笔"手续费"根本没有任何底层资产进入金库——它只是把存款额折算成的虚构数字。结果:每次存款都把兑换率往上抬,使 `AssetToken` 的兑换率与金库真实底层余额脱钩。

- **影响:** 兑换率被人为抬高后,持有 `AssetToken` 的人 `redeem` 时按虚高的兑换率取回底层资产,**赎回额 > 存入额**,多出来的部分来自其他 LP / 闪电贷流动性。在有其他 LP 资金垫底的金库里,攻击者只需"存入即赎回"即可净赚,逐步抽干金库;长期看会导致最后赎回的 LP 资不抵债。`ThunderLoanUpgraded` 已删除这两行,反向印证此为植入缺陷。

- **PoC(`forge test` PASS):** 攻击者存入 `100e18`,立刻全额赎回,取回 `100.0272…e18` —— 在**零次闪电贷**的情况下凭空多出本金。

```solidity
function testDepositInflatesExchangeRateAndBreaksRedeem() public {
    // LP 先注入 1000e18 垫底流动性
    token.mint(liquidityProvider, 1000e18);
    vm.startPrank(liquidityProvider);
    token.approve(address(thunderLoan), 1000e18);
    thunderLoan.deposit(IERC20(address(token)), 1000e18);
    vm.stopPrank();

    uint256 amount = 100e18;                       // 攻击者存款
    token.mint(attacker, amount);
    vm.startPrank(attacker);
    token.approve(address(thunderLoan), amount);
    thunderLoan.deposit(IERC20(address(token)), amount);
    uint256 assetBal = assetToken.balanceOf(attacker);
    thunderLoan.redeem(IERC20(address(token)), assetBal);  // 立刻赎回
    vm.stopPrank();

    uint256 redeemed = token.balanceOf(attacker);
    assertGt(redeemed, amount);                    // 赎回 > 存入
}
```

```text
[PASS] testDepositInflatesExchangeRateAndBreaksRedeem() (gas: 288952)
  Attacker deposited : 100000000000000000000
  Attacker redeemed  : 100027280145058930108
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

- **修复:** 从 `deposit` 中删除 `getCalculatedFee` + `updateExchangeRate` 两行(与 `ThunderLoanUpgraded` 一致)。兑换率应**只在 `flashloan()` 内、且手续费已实际转入金库后**更新。

---

### H-02 · 升级存储槽冲突:`s_flashLoanFee` 被旧 `s_feePrecision` 覆盖

- **严重度:** High(在生产升级场景下为 Critical)
- **位置:** `src/protocol/ThunderLoan.sol:96-97` vs `src/upgradedProtocol/ThunderLoanUpgraded.sol:96-97`

v1 存储布局(代理槽位):

```
slot N   : s_tokenToAssetToken (mapping)
slot N+1 : s_feePrecision   = 1e18      // ThunderLoan.sol:96
slot N+2 : s_flashLoanFee   = 3e15      // ThunderLoan.sol:97
```

v2 存储布局:

```
slot N   : s_tokenToAssetToken (mapping)
slot N+1 : s_flashLoanFee                // ThunderLoanUpgraded.sol:96  ← 落到了旧 s_feePrecision 的槽位
           FEE_PRECISION = 1e18 (constant，不占槽)  // ThunderLoanUpgraded.sol:97
```

- **根因:** `ThunderLoanUpgraded` 把 `s_feePrecision` 从**存储变量**改成了 `constant FEE_PRECISION`(不占存储槽),却没有在原槽位保留占位变量。UUPS 升级**不会迁移存储**,数据仍在代理原槽中。于是升级后 v2 的 `s_flashLoanFee` 直接读到旧 `s_feePrecision` 所在的槽,值变成 `1e18`。

- **影响:** 升级前手续费率为 `3e15`(0.3%),升级后被悄然篡改为 `1e18`(= `FEE_PRECISION`,即 100% 量级)。`getCalculatedFee` 中 `fee = valueOfBorrowedToken * s_flashLoanFee / FEE_PRECISION`,手续费瞬间放大到借款全额量级,闪电贷功能实际不可用 / 用户被超额收费,协议核心经济参数完全失真。这是教科书式的可升级存储冲突,后果取决于该槽承载的旧值——此处直接把费率打成不可用状态。

- **PoC(`forge test` PASS):** 同一代理实例,升级前 `getFee() == 3e15`,`upgradeTo` 到 v2 后 `getFee() == 1e18`。

```solidity
function testUpgradeStorageCollisionCorruptsFee() public {
    uint256 feeBefore = thunderLoan.getFee();                 // 3e15
    ThunderLoanUpgraded upgradedImpl = new ThunderLoanUpgraded();
    thunderLoan.upgradeTo(address(upgradedImpl));
    uint256 feeAfter = ThunderLoanUpgraded(address(thunderLoan)).getFee(); // 1e18
    assertEq(feeBefore, 3e15);
    assertEq(feeAfter, 1e18);                                 // 被存储冲突篡改
}
```

```text
[PASS] testUpgradeStorageCollisionCorruptsFee() (gas: 5649180)
  v1 s_flashLoanFee  : 3000000000000000
  v2 s_flashLoanFee  : 1000000000000000000
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

- **修复:** 升级合约必须保持存储布局向后兼容。把被移除的变量改成占位:
  ```solidity
  uint256 private s_blank;        // 旧 s_feePrecision 的占位,保留槽位
  uint256 private s_flashLoanFee;
  uint256 public constant FEE_PRECISION = 1e18;
  ```
  并在 CI 中引入 `@openzeppelin/upgrades` 的存储布局校验,任何升级前比对 layout。

---

### H-03 · 手续费基于可被闪电操纵的现货预言机,可压成零实现免费闪电贷

- **严重度:** High
- **位置:** `src/protocol/OracleUpgradeable.sol:19-22` + `src/protocol/ThunderLoan.sol:246-251`(`getCalculatedFee`)

```solidity
// OracleUpgradeable
function getPriceInWeth(address token) public view returns (uint256) {
    address swapPoolOfToken = IPoolFactory(s_poolFactory).getPool(token);
    return ITSwapPool(swapPoolOfToken).getPriceOfOnePoolTokenInWeth(); // 现货价,无 TWAP
}
// ThunderLoan.getCalculatedFee
uint256 valueOfBorrowedToken = (amount * getPriceInWeth(address(token))) / s_feePrecision;
fee = (valueOfBorrowedToken * s_flashLoanFee) / s_feePrecision;
```

- **根因:** 手续费完全由 TSwap 池子的**即时现货价** `getPriceOfOnePoolTokenInWeth()` 决定,没有 TWAP、没有偏离上下限、没有多源校验。AMM 现货价是同一笔交易内可被改变的状态——攻击者用闪电贷(或闪电兑换)先把目标代币在 TSwap 池中的价格砸下去,再调用 `flashloan`,手续费就按被操纵后的极低价计算。

- **影响:** 攻击者可把每笔闪电贷手续费压到约等于 0,**免费借走全部金库流动性**,使 LP 应得收益归零(套利/清算等下游攻击的资金成本被清零)。该操纵与闪电贷天然可组合,无需自有本金。

- **PoC(`forge test` PASS):** 诚实价(`1e18`)下借 `100e18` 手续费为 `0.3e18`;把池价压到 `1 wei` 后,同样借款手续费计算结果为 `0`。

```solidity
function testFeeFollowsManipulableSpotOracle() public {
    uint256 borrow = 100e18;
    uint256 fairFee = thunderLoan.getCalculatedFee(IERC20(address(token)), borrow);
    TSwapPoolMock pool = TSwapPoolMock(factory.getPool(address(token)));
    pool.setPrice(1);                              // 攻击者把现货价砸到 1 wei
    uint256 manipulatedFee = thunderLoan.getCalculatedFee(IERC20(address(token)), borrow);
    assertGt(fairFee, 0);
    assertEq(manipulatedFee, 0);                   // 手续费归零 → 免费闪电贷
}
```

```text
[PASS] testFeeFollowsManipulableSpotOracle() (gas: 52241)
  Fair fee        : 300000000000000000
  Manipulated fee : 0
Suite result: ok. 1 passed; 0 failed; 0 skipped
```

> 说明:PoC 用可设价 mock 池子确定性地证明"手续费随现货价线性变化、可被压到 0"这一根因。真实环境中价格下压通过对 TSwap 池的闪电兑换实现,与本协议闪电贷在同一交易内可组合。

- **修复:** 改用抗操纵的价格源——TSwap 池的 TWAP(时间加权累计价)或 Chainlink 等外部预言机;并对单笔价格相对上一观测的偏离设上限,异常则 `revert`。

---

## 3. 对抗性验证与排除(未列为发现的项)

为避免凑数,以下方向经审查后**未**计入发现:

- **`flashloan()` 重入:** 函数遵循"先记账(`updateExchangeRate`)、再外呼 `executeOperation`"且以 `endingBalance < startingBalance + fee` 兜底,常规重入无法绕过还款校验;未发现可证明的重入提款路径,故不报。`s_currentlyFlashLoaning` 仅用于授权 `repay`,不构成锁缺陷。
- **`redeem` 重入:** 走 OZ `SafeERC20` 且先 `burn` 后转账,标准 ERC20 下无重入;仅对带回调的非标准代币(范围外)才有理论风险,不在范围内,不报。
- **`setAllowedToken(false)` 后金库资金:** `delete s_tokenToAssetToken[token]` 会使该代币暂时无法 deposit/redeem,但 `AssetToken` 仍持有底层资产,重新 `setAllowedToken(true)` 会新建 AssetToken 导致旧份额"失联"——属于设计/运维风险(Owner 受信),非可由外部攻击者触发的高危,降级处理,不计入 High。
- **`updateFlashLoanFee` 上限:** 校验 `newFee > s_feePrecision` 仅防越界,Owner 为受信角色,不报。
- **闪电贷期间 `deposit` 偷取(deposit-instead-of-repay):** 与 H-01 同根(`deposit` 误更新兑换率 + 可在 flashloan 中存款),H-01 的 PoC 已足以坐实会计被破坏并可多赎,故合并于 H-01,不重复列项。

---

## 4. 方法论

1. 通读 README / scope,明确范围与升级意图。
2. 人工审计核心合约,重点覆盖闪电贷高危面:存款/赎回会计、兑换率被闪电贷操纵、预言机定价、UUPS 升级存储布局、重入与还款校验。
3. 对每个 High/Critical 编写**自包含 Foundry PoC**(独立 mock,不依赖原仓库已损坏的测试夹具),`forge build` 通过后逐条 `forge test -vv` 必须 PASS。
4. 对每个未列入的可疑点做对抗性反证,只保留能被 PoC 证明的发现。

复现:
```bash
cd /tmp/ff-thunderloan
forge test --match-contract DuoLaSafePoC -vv
# 3 passed; 0 failed
```

---

## 5. 免责声明

本报告基于上述指定 commit 的代码快照,在约定范围内尽职审计。安全审计不能证明代码绝对无漏洞,亦不构成对协议安全性、适销性或任何商业结果的保证。报告不构成投资、财务或法律建议。修复后建议重新审计并配合形式化验证 / 模糊测试 / 主网监控。

© 2026 DuoLaSafe · Telegram @dsa885 · X @hunterweb303
