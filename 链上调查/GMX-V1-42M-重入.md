# GMX V1 ~$42M 被盗 · 重入操纵全局空头会计 · 链上取证复盘

> DuoLaSafe 链上取证 · 事件 2025-07 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

2025-07-09,攻击者通过 GMX V1 `PositionManager.executeDecreaseOrder()` 的回调钩子 (`gmxPositionCallback`) 实现重入,在订单减仓回调中重入 Vault 直接开空,使 `ShortsTracker.globalShortAveragePrices`(全局空头均价)与 `globalShortSizes` 失同步,人为把 BTC 空头均价从约 $108,757 / $109,505 砸到约 $1,913.7(约 57 倍偏离),令 `getAum()` 把"虚假的空头未实现亏损"计入 AUM、抬高 GLP 单价,随后赎回 GLP 套出约 **$42M**。攻击者后续接受白帽方案、归还全部资金、保留 **$5M** 赏金。

---

## 1 背景:GMX V1 / GLP 与空头会计

- **GMX V1** 是 Arbitrum 上头部永续合约 DEX,采用 **GLP** 共享流动性池模型:LP 存入一篮子资产铸造 GLP,作为所有交易者的对手盘,按池子 **AUM(资产管理规模)** 决定 GLP 单价。
- **空头会计闭环**:交易者开空 → 影响 `globalShortSizes` / `globalShortAveragePrices` → 全局空头均价进入 `getAum()` 计算(空头方的未实现盈亏要计入池子净值)→ AUM 决定 GLP 价格 → GLP 价格决定铸造/赎回时拿到的资产数量。
- 这是一个**自引用的循环依赖**:空头状态 → AUM → GLP 价格 → 流动性操作 → 又回过头改空头状态。只要其中一个状态在交易中途被"卡在旧值",整个估值就会失真。
- 链上确认(Arbitrum,RPC `arb1.arbitrum.io/rpc`):
  - Vault `0x489ee077994B6658eAfA855C308275EAd8097C4A` — `cast codesize` = 23438(合约存在)。
  - GlpManager `0x321F653eED006AD1C29D174e17d96351BDe22649` — `cast codesize` = 8211(合约存在)。

---

## 2 漏洞根因:重入 + globalShortAveragePrice 操纵

安全方(PeckShield、慢雾 SlowMist、Verichains)一致定位为**两个设计缺陷的组合**:

**缺陷一 —— 减仓执行回调的重入面**
`PositionManager.executeDecreaseOrder()` 由 GMX keeper 调用,隐含假设 `_account` 是 EOA,实际可传入恶意合约地址。执行过程中通过 `gmxPositionCallback()` 回调钩子把控制权交给攻击者合约,攻击者在订单尚未结算完成时重入 GMX(reward router / Vault),在状态最终化前抢先改写状态。这是典型的**退款式 / 回调式重入(refund-based reentrancy-like)**。

**缺陷二 —— 全局空头均价的更新时序失同步**
正常路径下 `globalShortSizes` 立即更新,而 `globalShortAveragePrices` 仍停留在旧值;通过重入路径直接调用 Vault 的 `increasePosition` 开空,**绕过了 `ShortsTracker` 中 `globalShortAveragePrices` 的更新**。

结果:`globalShortSizes` 已被新开的大额空头放大,而 `globalShortAveragePrices` 仍是旧均价 → 系统误判该空头"深度亏损" → `getAum()` 把这笔虚假未实现亏损加进 AUM → **AUM 被人为抬高 → GLP 单价被抬高**。

**关键操纵数值(安全方披露)**:攻击前链上 BTC 空头存量极小(约 $15,385),攻击者用大额 BTC 空头(约 $90k–$100k 量级)反复减仓,把 BTC 全局空头均价从约 **$108,757 / $109,505** 砸到约 **$1,913.7**(约 57 倍偏离市价)。各安全方引用的起点价略有差异($108,757 vs $109,505.05 vs $109,515.05),终点价一致为 ~$1,913.7。

> 取证说明:上述 `increasePosition`/`gmxPositionCallback`/`globalShortAveragePrices` 调用路径与价格数值,均引自 PeckShield / 慢雾 / Verichains / Sherlock 的事后分析,本复盘未逐字节反编译攻击合约字节码,故标注为"安全方披露、可复核"。

---

## 3 攻击流程(带 tx)

被广泛引用的主攻击交易:
`0x03182d3f0956a91c4e4c8f225bbc7975f9434fab042228c7acdc5ec9a32626ef`(Arbitrum)

链上核实(`cast tx` / `cast receipt`,RPC `arb1.arbitrum.io/rpc`):
- **区块** 355880237,**时间戳** 1752064211 = **2025-07-09 12:30:11 UTC**。
- 交易 `from` = `0xd4266F8F82F7405429EE18559e548979D49160F3`(codesize=0,EOA),`to` = `0x75E42e6f01baf1D6022bEa862A28774a9f8a4A0C`(codesize=20521,合约)。
- receipt 日志中出现 GMX Vault 地址 `0x489ee077994b6658eafa855c308275ead8097c4a` 的多条事件,确认该 tx 与 Vault 交互。
- gasUsed ≈ 13.8M,符合一笔复杂多步重入交易的特征。

> 取证说明:该 tx 的直接发起方为 `0xd426...`、入口合约为 `0x75E42e...`,与安全方公开标注的"攻击者 EOA / 攻击合约"(见 §5)地址不同。这表明攻击由多个合约/EOA 协同完成,公开报告中的"主攻击 tx"是攻击编排中的一笔;本复盘据链上实测如实标注,不把单一地址等同于全部攻击主体。

攻击逻辑步骤(安全方还原):
1. 用约 **$7.5M 闪电贷**作为本金。
2. 经 RewardRouterV2 铸造并质押约 **$6M GLP**。
3. 通过 keeper 调用 `executeDecreaseOrder()`,把 `_account` 指向攻击者合约,在 `gmxPositionCallback()` 回调中重入 Vault 的 `increasePosition` 开出大额 BTC 空头,**跳过 `globalShortAveragePrices` 更新**。
4. 反复减仓 → 把 BTC 全局空头均价压到 ~$1,913.7 → AUM 虚高 → GLP 单价虚高(安全方称 GLP 被以约 $1.45 的失真价处理)。
5. 在 GLP 价格被抬高的时点调用 `unstakeAndRedeemGlp`,赎回**显著多于应得**的底层资产,差额即为利润。

---

## 4 规模统计

| 项目 | 数值 | 来源/核实 |
|---|---|---|
| 总损失 | ~$42M(部分报道写 ~$40M) | 慢雾 / PeckShield / rekt / Halborn |
| 受影响产品 | GMX V1 GLP 池(Arbitrum 为主,Avalanche 亦受影响) | 慢雾 |
| 被盗资产构成 | BTC、ETH、稳定币等一篮子 GLP 底层资产(未见逐币种权威拆分) | 慢雾;**逐币种数额未核实,不写为已核** |
| 闪电贷本金 | ~$7.5M | Verichains |
| 被操纵变量 | `globalShortAveragePrices`(及 `globalShortSizes` 失同步) | PeckShield / 慢雾 / Verichains |
| BTC 空头均价操纵 | ~$108,757/$109,505 → ~$1,913.7(~57x) | Verichains / Sherlock / QuillAudits |
| 攻击前 BTC 空头存量 | ~$15,385(极小,易操纵) | Verichains |
| 主攻击 tx 区块/时间 | 355880237 / 2025-07-09 12:30:11 UTC | **cast 链上实测** |

---

## 5 资金追踪(含是否归还/谈判)

**公开标注的攻击主体地址(安全方)**:
- 攻击者 EOA:`0xdf3340a436c27655ba62f8281565c9925c3a5221` —— `cast code` 返回 `0x`(链上确认为 EOA)。
- 攻击合约:`0x7d3bd50336f64b7a473c51f54e7f0bd6771cc355` —— `cast codesize` = 19037(链上确认为合约,有代码)。

**资金流向(安全方披露)**:
- 攻击当日约 **$9.6M–$9.65M** 从 Arbitrum 跨桥到 Ethereum(PeckShield)。
- 在 Ethereum 上经 **CoW Protocol** 兑换,把约 **$5M USDC 换成 ~$5M DAI**;部分资金兑成 ETH。
- 有报道提及部分资金触及 **Tornado Cash**(慢雾/部分媒体);CoW Protocol 兑换路径多家一致,Tornado 细节各源不完全一致,标注为"部分来源提及"。

**谈判与归还**:
- GMX 公开喊话:返还即给 **10% 白帽赏金**、48 小时期限、不追究法律责任。
- 攻击者**接受**:归还全部资金,GMX 支付 **$5M** 赏金至 `0xDF3340...`,剩余约 **$40M+** 进入 GMX Security Multisig。
- GMX 随后向 GLP 持有者进行约 **$44M** 量级的补偿/赔付(媒体报道)。
- 链上现状:`cast balance` 显示 EOA `0xdf33...` 余额约 0.00077 ETH(归还后残留尘额,符合"已清空归还"叙事)。

---

## 6 修复与防御建议

- **GMX 官方应急**:暂停 GMX V1 上的交易与 GLP 铸造/赎回(halt trading & minting),阻断进一步套利。
- **重入防护**:对所有带外部回调的执行函数(`executeDecreaseOrder` / 回调钩子)加 `nonReentrant`,并对 `_account` 做 EOA / 白名单校验,杜绝把执行权交给任意合约。
- **会计原子性**:确保 `globalShortSizes` 与 `globalShortAveragePrices` 在同一原子操作内同步更新,禁止任何路径只改其一;`ShortsTracker` 更新不可被外部重入跳过。
- **估值健壮性**:`getAum()` 对空头未实现盈亏引入**价格合理性边界 / 偏离上限 / 时间加权均价**,拒绝单笔交易内瞬时把空头均价压低数十倍。
- **铸赎隔离**:对在同一交易内"先抬高 AUM 再赎回 GLP"的组合施加同区块限制或预言机交叉校验。
- **监控**:对 `globalShortAveragePrices` 的剧烈跳变、AUM 与外部预言机价差设链上告警(慢雾 MistEye 即靠监控首先发现)。

---

## 7 时间线

| 时间(UTC) | 事件 | 核实 |
|---|---|---|
| 2025-07-09 12:30:11 | 主攻击 tx `0x0318...26ef` 上链(区块 355880237),GLP 池被抽走 ~$42M | **cast 链上实测** |
| 2025-07-09 | 慢雾 MistEye 监测告警;约 $9.6M 当日跨桥至 Ethereum | 慢雾 / PeckShield |
| 2025-07-09 | GMX 暂停 V1 交易与 GLP 铸赎 | Unchained / 媒体 |
| 2025-07-09~10 | 资金经 CoW Protocol 兑换(USDC→DAI、ETH),部分触及 Tornado(部分来源) | PeckShield / rekt |
| 2025-07-10~11 | GMX 公开白帽方案(10% 赏金、48h、不追责);攻击者接受 | rekt / QuillAudits |
| 攻击后约 48h 内 | 归还全部资金,$5M 赏金至 `0xDF3340...`,余额入 GMX Security Multisig | QuillAudits / Halborn |
| 后续 | GMX 向 GLP 持有者补偿(~$44M 量级报道) | ainvest 等 |

---

## PoC(可运行复现)

> 这是一个 **Foundry 最小化模型**,目的不是逐字节复刻 GMX 代码库,而是忠实复现漏洞**本质**:`executeDecreaseOrder` 的 `gmxPositionCallback` 回调发生在**状态最终化之前**,攻击者在「`globalShortSize` 已临时缩小、`globalShortAveragePrice` 尚未重算」的不一致窗口里**重入**开空,用低入场价把全局空头均价砸低,从而虚高 `getAum()` / GLP 价并多赎回。数值为演示用的合理量级,方向与安全方披露一致(均价 ~$108,757 被砸至 ~$1,913 / ~57x;GLP 被以失真价处理)。

**工程结构**:`/tmp/duolasafe-audits/PoC/gmx/`(`foundry.toml` solc=0.8.24 + `test/GMX.t.sol`,不依赖 forge-std,用 `external` 测试函数 + `require` 断言)。

**核心机制(节选 `test/GMX.t.sol`)**:

```solidity
// MockVault:维护全局空头会计 + AUM。空头是池子对手盘:
//   shortPnlForPool = shortSize * (markPrice - avgPrice) / avgPrice
//   avgPrice 被砸低 → 系统误判空头巨亏 → 池子「虚赚」→ AUM 虚高。

// executeDecreaseOrder:复刻真实时序 —— size 先临时下降,回调插在
// 「size 已改、avgPrice 尚未重算」的不一致窗口里:
function executeDecreaseOrder(address account, uint256 decreaseSize) external {
    if (vulnerableOrder) {
        globalShortSize -= decreaseSize;          // (1) size 临时缩到极小
        pendingSizeRestore = decreaseSize;
        IPositionCallback(account).gmxPositionCallback(); // (2) 回调:不一致窗口
        globalShortSize += pendingSizeRestore;    // (4) 结算尾段才补回 size
    }
}

// 重入路径:用「当前(被缩小的)size」作分母 blend 均价,使低入场价被
// 过度加权 → 把 globalShortAveragePrice 砸到远低于市价(失同步根源):
function increaseShortReenter(uint256 addSize, uint256 entryPrice) external {
    uint256 oldSize = globalShortSize;                    // ← 被缩小的 size
    uint256 newSize = oldSize + addSize;
    globalShortAveragePrice =
        (oldSize * globalShortAveragePrice + addSize * entryPrice) / newSize;
    globalShortSize += addSize;
}

// 攻击者在回调里重入:
function gmxPositionCallback() external {
    vault.increaseShortReenter(reentryShortSize, reentryEntryPrice); // 低入场价砸均价
}
```

三个测试:`testNormalOrderKeepsAumStable`(正常顺序按市价开空 → 均价稳定、AUM 不变,作对照)、`testReentrancyInflatesAum`(重入 → 均价被砸 >10x、AUM 与 GLP 价被抬高、且 AUM > 正常顺序)、`testAttackerRedeemsMore`(同一笔 GLP 在重入抬价后赎回 > 公允价值,差额即利润)。

**运行命令与输出**:

```
$ export PATH="$HOME/.foundry/bin:$PATH"
$ cd /tmp/duolasafe-audits/PoC/gmx && forge test -vv

Compiling 1 files with Solc 0.8.24
Solc 0.8.24 finished in 102.50ms
Compiler run successful!

Ran 3 tests for test/GMX.t.sol:GMXReentrancyTest
[PASS] testAttackerRedeemsMore() (gas: 1791506)
[PASS] testNormalOrderKeepsAumStable() (gas: 727892)
[PASS] testReentrancyInflatesAum() (gas: 1803702)
Suite result: ok. 3 passed; 0 failed; 0 skipped; finished in 1.12ms

Ran 1 test suite in 313.84ms: 3 tests passed, 0 failed, 0 skipped (3 total tests)
```

**复现到的数值(模型量级)**:全局空头均价从约 **$108,757** 被砸至约 **$2,368**(≈46x 偏离,与安全方披露的 ~$1,913 / ~57x 同方向同量级)→ AUM 从约 **$6.00M** 虚高到约 **$10.73M** → GLP 单价从 **$1.00** 抬到约 **$1.79** → 攻击者用 100 万份 GLP 赎回约 **$1.79M**(公允仅 $1.00M),凭空套出约 **$0.79M** 差额。把规模放大到真实闪电贷本金量级,即对应 ~$42M 级别的抽水。

**解释**:本 PoC 展示的核心是「**回调先于状态更新 → 重入读到不一致状态**」这一漏洞本质 —— `globalShortSize` 与 `globalShortAveragePrice` 没有在同一原子操作内同步更新,且执行函数把控制权交给了任意 `_account` 合约。对照测试证明:同样规模的空头,走合法(原子同步)路径 AUM 纹丝不动,走重入(失同步)路径 AUM 被人为抬高 —— 二者差额正是攻击者的套利空间。这与 §6 修复建议(会计原子性 + `nonReentrant` + EOA 校验 + 均价偏离边界)一一对应。

---

## 来源

- 慢雾 SlowMist — Inside the GMX Hack: $42 Million Vanishes in an Instant: https://slowmist.medium.com/inside-the-gmx-hack-42-million-vanishes-in-an-instant-6e42adbdead0
- Verichains — GMX $42M Exploit: Root Cause Analysis: https://blog.verichains.io/p/gmx-42m-exploit-root-cause-analysis
- QuillAudits — How GMX Lost $42M to a Reentrancy Attack: https://www.quillaudits.com/blog/hack-analysis/how-gmx-lost-42m
- rekt.news — GMX REKT: https://rekt.news/gmx-rekt
- Sherlock — GMX Exchange Hack Explained: https://sherlock.xyz/post/gmx-exchange-hack-explained
- Halborn — Explained: The GMX Hack (July 2025): https://www.halborn.com/blog/post/explained-the-gmx-hack-july-2025
- CertiK — GMX Incident Analysis: https://www.certik.com/resources/blog/gmx-incident-analysis
- SolidityScan — GMX v1 Hack Analysis: https://blog.solidityscan.com/gmx-v1-hack-analysis-ed0ab0c0dd0f/
- Unchained — GMX Loses $40M in V1 Exploit: https://unchainedcrypto.com/gmx-loses-40-million-in-v1-exploit-halts-trading-and-minting/
- ainvest — GMX Reimburses $44M to GLP Holders: https://www.ainvest.com/news/gmx-reimburses-44m-glp-holders-42m-arbitrum-exploit-2508/
- 链上数据:Arbitrum RPC `https://arb1.arbitrum.io/rpc`,经 `cast tx/receipt/code/codesize/balance/block` 实测(tx `0x0318...26ef`、区块 355880237、Vault `0x489ee0...`、攻击者 EOA `0xdf3340...`、攻击合约 `0x7d3bd5...`)

---

## 免责声明

本报告基于公开链上数据与第三方安全机构公开披露整理,仅供技术研究与风险复盘之用。报告**不指认任何特定自然人或法律实体**为攻击者;链上地址归属以公开信息为准,不代表 DuoLaSafe 的事实认定。本报告**不构成法律意见、投资建议或追偿承诺**,DuoLaSafe **不保证任何资金的追回**。部分数据(如逐币种被盗数额、Tornado Cash 细节)各来源不完全一致,已在正文标注核实状态,读者应自行交叉复核。© 2026 DuoLaSafe
