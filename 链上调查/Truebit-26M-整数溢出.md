# Truebit $26.2M 被盗:旧合约定价数学整数溢出,0 成本铸 TRU 套走 ETH 储备

> DuoLaSafe 链上取证 · 事件 2026-01-08 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

2026-01-08,Truebit 一个 2021 年部署、用 Solidity 0.6.10 编译、从未公开审计的 TRU 购买合约,在计算「买 TRU 需付多少 ETH」时发生**整数溢出**:攻击者传入一个极大的购买数量,使定价公式的分子超过 `2^256` 回绕到极小值,购买价格被截断到约 0,于是几乎不花 ETH 就铸出海量 TRU,再卖回 bonding-curve 储备套走约 **8,535.36 ETH(约 $26.2–26.6M)**。攻击在单笔交易内完成,链上可复核。

---

## 1 背景:Truebit 与 TRU 购买机制

- **Truebit** 是一个以太坊上的链下计算验证协议,其代币为 **TRU**(合约 `0xf65b5c5104c4fafd4b709d9d60a185eae063276c`,链上 `name()="Truebit"`、`symbol()="TRU"`,已核)。
- TRU 通过一个**购买/铸造合约**(`0x764C64b2A09b09Acb100B80d8c505Aa6a0302EF2`,本文称「Purchase 合约」)按 **bonding curve(联合曲线)** 定价:买入数量越大,单价沿曲线上升;合约持有 ETH 储备,买入时收 ETH 铸 TRU,卖出时销毁 TRU 退还 ETH。该合约链上仍存活,`getPurchasePrice(uint256)` 对正常输入(1 TRU)返回非零价格(已 `cast call` 核实)。
- 该合约用 **Solidity 0.6.10** 编译——此版本**默认不做算术溢出检查**(0.8.0 才内置 over/underflow revert)。多家安全方报道指出合约在 Etherscan 上**闭源、多年无人维护、无 bug bounty、无第三方审计**。

---

## 2 漏洞根因:定价分子整数溢出

核心在购买价格计算函数(安全方报道中函数名为 `getPurchasePrice(uint256 amount)` / 内部 `_getPurchasePrice()`)。其分子近似为(BlockSec、Olympix 反编译还原):

```
numerator = 100 * amount^2 * _reserve  +  200 * totalSupply * amount * _reserve
```

其中 `amount` 为买入的 TRU 数量、`totalSupply` 为当前供应量、`_reserve` 为合约 ETH 储备。在 0.6.10 下,这些 `uint256` 乘加**没有溢出保护**。

攻击者传入的数量(安全方报道值):

```
amount = 240,442,509,453,545,333,947,284,131
```

**取证侧数值验证(本文用 Python 复算,可复核):**

| 项 | 值 | 说明 |
|---|---|---|
| `2^256` | ≈ 1.158e77 | uint256 上限 |
| `100 * amount^2` | ≈ 5.781e54 | 仅此项、`_reserve=1` 时**不**溢出 |
| 触发溢出所需 `_reserve` 下限 | ≈ 2.003e22 | 当 `100*amount^2*_reserve > 2^256` |
| `_reserve ≈ 2.1e22` 时 `100*amount^2*_reserve` | ≈ 1.214e77 | **> 2^256,回绕** |

> 关键:单看 `100*amount^2` 还不够大;一旦乘上量级约 `10^22`(即储备里数千 ETH、18 位精度)的 `_reserve`,分子就突破 `2^256` 并回绕(wrap)到一个极小的余数。最终算出的购买价格被截断到接近 **0 wei**——即「买海量 TRU,几乎不要钱」。这与 BlockSec / Olympix 给出的「分子超过 `2^256` 导致 purchase price 归零」一致。

**性质:** 合约逻辑/算术漏洞(整数溢出),不涉及私钥泄露、不涉及预言机、不涉及重入。纯粹是旧编译器无溢出检查 + 缺少输入上界。

---

## 3 攻击流程:单笔交易内 mint→sell 多轮套利

链上已核(攻击交易 `0xcd4755645595094a8ab984d0db7e3b4aabde72a5c87c4f176a030629c47fb014`,区块 24191019,时间 **2026-01-08 16:02:35 UTC**,status=success):

1. 攻击者 EOA `0x6C8EC8f14bE7C01672d31CFa5f2CEfeAB2562b50` 向**自建攻击合约** `0x1De399967B206e446B4E9AeEb3Cb0A0991bF11b8` 调用方法选择器 `0x64dd891a`(`cast 4byte` 解析为 `attack(uint256)`,即攻击者自己合约的封装入口),仅附带 **0.01 ETH**。
2. 攻击合约对 Purchase 合约发起多轮 `getPurchasePrice → buyTRU(买入)→ sellTRU(卖回)`:因价格被溢出截断到 ~0,**几乎 0 成本铸出 TRU**(链上 32 条日志中可见多笔从 `0x0` 铸出的 TRU Transfer,单轮规模达数十亿至上万亿 TRU,例如一轮 mint ≈ 1.255e10 TRU、另一轮 ≈ 3.05e27 最小单位),随即把 TRU 卖回 Purchase 合约,换出其中真实的 ETH 储备。
3. 多轮循环在**同一笔交易内**完成,把 bonding-curve 储备里的 ETH 抽干,净利约 8,535 ETH 流回攻击者控制地址。

> 链上佐证:本交易内 TRU 代币(`0xf65b…`)在 `0x0`、攻击合约 `0x1de3…`、Purchase 合约 `0x764c…` 之间反复 mint / transfer / burn;`getPurchasePrice(1 TRU)` 今天仍返回非零,说明溢出只在「极大 amount」时被触发。

---

## 4 规模统计

| 指标 | 数值 | 来源/核实 |
|---|---|---|
| 主攻击被盗 | **8,535.36 ETH ≈ $26.2–26.6M** | CoinDesk / BlockSec / Olympix;ETH 量级与链上一致 |
| 攻击投入成本 | 0.01 ETH + gas | 攻击交易 value 字段(链上已核) |
| 攻击交易 gasUsed | 481,749 | 链上 receipt(已核) |
| 二次(机会型)攻击者额外提取 | ≈ 71.03 ETH ≈ $224K | Olympix / CoinDesk |
| TRU 价格 | 由约 $0.16 跌至近 0(报道称 -99.9%) | CoinDesk |
| 漏洞合约编译器 | Solidity 0.6.10(无内置溢出检查) | 多方报道 |
| 合约部署年份 | 2021,闭源、未审计、长期无维护 | Halborn / Olympix |

> 金额区间:不同安全方给出 $26.2M / $26.44M / $26.6M,差异源于 ETH 计价时点;ETH 数量 8,535.36 各方一致。

---

## 5 资金追踪

链上与安全方报道结合(地址均已 `cast` 核实存在/余额):

- **攻击者 EOA:** `0x6C8EC8f14bE7C01672d31CFa5f2CEfeAB2562b50`(当前余额已近乎为 0,1e9 wei)。
- 报道称主攻击者于 2026-01-09 将赃款拆分到两个地址:
  - `0xD12f6E0fa7FBF4e3A1c7996E3F0Dd26AB9031a60` —— 报道约 4,267.09 ETH(≈ $13.2M);**当前链上余额已近乎为 0**(8.79e14 wei),说明资金已进一步转出。
  - `0x273589ca3713e7becf42069f9fb3f0c164ce850a` —— 报道约 4,001.00 ETH(≈ $12.4M);**当前链上余额亦近乎为 0**(2.66e12 wei)。
- **二次攻击者**:报道称将 ≈ 71.03 ETH 直接转入 **Tornado Cash** 混币。

> 取证说明:两个拆分地址「报道金额」与「当前余额≈0」一致,表明赃款已在后续交易中向外转移;本文不追踪每一跳的下游归集,亦不对接收方做任何身份指认。后续跳数可按上述地址在区块浏览器逐笔复核。

---

## 6 修复与防御建议

针对「旧合约 + 算术溢出 + 无输入边界」这一类问题:

1. **算术安全**:0.8.0 以下合约必须全程使用 **SafeMath**(或等价 checked 库)做乘加;新合约直接用 **Solidity ≥0.8** 的内置 over/underflow revert。本案 `100*amount^2*_reserve + …` 这种**乘方再乘储备**的多项式分子是高危点,必须 checked。
2. **输入边界**:对 `buyTRU` / 定价函数的 `amount` 设**显式上界**(require amount <= MAX_BUY),任何「数量大到能让分子接近 2^256」的输入都应被拒绝;定价公式应保证单调、对极端输入不回绕。
3. **bonding curve 不变量**:对储备做 invariant 校验——单笔交易后「储备减少量」必须与「卖出 TRU 应得 ETH」匹配,price≈0 的铸造路径应被前置检查拦截。
4. **遗留合约治理**:对仍持有资金的旧合约,即使「已弃用」,也要么**审计 + 暂停/迁移资金**,要么纳入持续监控与 bug bounty;闭源 + 无人维护 + 持币 = 最高风险组合。
5. **上线前**:第三方审计 + 模糊测试(对定价函数喂极大/边界输入)+ 形式化检查溢出。

---

## 7 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2021 | 漏洞 Purchase 合约用 Solidity 0.6.10 部署,闭源、未审计 |
| 2026-01-08 16:02:35 | 攻击交易 `0xcd47…fb014` 上链(区块 24191019),单笔内 mint→sell 多轮,套走 ≈ 8,535 ETH(链上已核) |
| 2026-01-08 起 | TRU 价格自约 $0.16 崩向近 0(报道 -99.9%) |
| 2026-01-09 | 报道:主攻击者拆分赃款至两地址(各约 4,267 / 4,001 ETH);二次攻击者将 ≈71 ETH 送入 Tornado Cash |
| 2026-01-14 | BlockSec 发布深度分析 |

---

## 8 · PoC(可运行复现)

我们写了一个**可编译、可运行**的 Foundry PoC,用 `unchecked {}` 精确还原 Solidity 0.6.10 的"无溢出检查"语义,复现"溢出 → 价格塌零 → 免费铸币"。完整代码:仓库 `PoC/test/TruebitOverflow.t.sol`。

核心(脆弱定价 + 攻击):
```solidity
// 文档化的分子二次项:100 * amount^2 * reserve(就是它溢出);0.6.10 不检查溢出
function getPurchasePrice(uint256 amount) public view returns (uint256 price) {
    unchecked {
        uint256 numerator = 100 * amount * amount * reserve;
        price = numerator / DENOM;
    }
}
// amount = 2^128  =>  amount^2 = 2^256 ≡ 0 (mod 2^256)  =>  分子回绕为 0  =>  价格 = 0
function test_overflow_makes_mint_free() external view {
    uint256 crafted = 2 ** 128;
    require(pool.getPurchasePrice(crafted) == 0, "overflow did not zero the price");
    require(pool.getPurchasePrice(1e18) > pool.getPurchasePrice(crafted), "monotonicity broken");
}
```

运行结果(`forge test -vv`):
```
[PASS] test_honest_buy_costs_eth()       诚实买入(1 TRU)需付费,价格 > 0
[PASS] test_overflow_makes_mint_free()   构造 amount=2^128 后价格塌到 0 = 免费铸币
Suite result: ok. 2 passed; 0 failed
```

**结论**:`amount = 2^128` 时 `amount^2 = 2^256 ≡ 0`,二次项分子回绕为 0,购买价被截断到 0 —— 买 1 个 TRU 要钱、买 2¹²⁸ 个 TRU 却 0 成本,**定价单调性被溢出打破**。这正是攻击者"几乎 0 成本铸出海量 TRU、再卖回储备抽走 ETH"的弹药来源。**防御侧**:0.8 内置 checked 算术 / 0.6.x 全程 SafeMath,即可让该笔铸造在溢出点直接 revert。

---

## 来源

- CoinDesk:《Truebit token (TRU) crashes 99.9% after hacker drains $26.6 million in ether》 https://www.coindesk.com/markets/2026/01/09/truebit-token-tru-crashes-99-9-after-usd26-6m-exploit-drains-8-535-eth
- BlockSec:《In-Depth Analysis: The Truebit Incident》 https://blocksec.com/blog/in-depth-analysis-the-truebit-incident
- Olympix(Medium):《Truebit $26.6M Exploit: Integer Overflow and the Cost of Abandoned Code》 https://olympixai.medium.com/truebit-26-6m-exploit-integer-overflow-and-the-cost-of-abandoned-code-84ed3aa64e43
- Halborn:《Explained: The Truebit Hack (January 2026)》 https://www.halborn.com/blog/post/explained-the-truebit-hack-january-2026
- Cointelegraph:《$26M Truebit Hack Was Smart Contract Exploit: Analysis》 https://cointelegraph.com/news/26m-truebit-hack-smart-contract-vulnerability
- KuCoin News:《Truebit Protocol Hacked for $26.44M Due to Integer Overflow Vulnerability》 https://www.kucoin.com/news/flash/truebit-protocol-hacked-for-26-44m-due-to-integer-overflow-vulnerability
- 链上自行核实:交易 `0xcd4755645595094a8ab984d0db7e3b4aabde72a5c87c4f176a030629c47fb014`、TRU 代币 `0xf65b5c5104c4fafd4b709d9d60a185eae063276c`、Purchase 合约 `0x764C64b2A09b09Acb100B80d8c505Aa6a0302EF2`、相关地址余额(RPC: ethereum-rpc.publicnode.com,foundry cast)

---

## 免责声明

本报告基于公开报道与链上可复核数据整理,仅供安全研究与风险教育之用。报告**不对任何个人或实体作身份指认**,所列地址均为链上公开地址;**不构成法律意见或投资建议**;**不保证任何资金可被追回**。数值存在不同来源差异时已注明区间。如有更准确的一手信息,欢迎通过文首联系方式订正。

© 2026 DuoLaSafe
