# Venus Protocol 用户被盲签 `updateDelegate` 钓鱼劫持 —— 链上取证复盘

> DuoLaSafe 链上取证 · 事件 2026 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

这不是 Venus 协议合约被攻破,而是**单个大户(power user)被社工钓鱼后"盲签"了一笔 `updateDelegate` 交易**,把自己 Venus 仓位的代理权(delegate)授予攻击者,攻击者随即以受害者名义借出并赎回抵押品,**约 $13.5M(初报 $27M)** 被转走;Venus 通过紧急治理(强制清算攻击者头寸)在约 12 小时内**全额追回**。本案与 Polymarket 类盲签事件同一根因:**合约逻辑没坏,坏在签名授权——用户在硬件钱包上对看不懂的 calldata 点了"确认"。**

> 取证更正(重要):种子线索中的"$3.7M"金额与本案不符。经核实,**$3.7M 是另一起独立事件**——2026 年 3 月 Venus 因 THE/Thena 喂价/供应上限(supply cap)被操纵的**协议级闪电贷攻击**,属合约/市场机制问题,**非钓鱼盲签**。本复盘聚焦与"恶意 approval/delegate、合约没坏坏在签名"线索匹配的事件,即 **2025-09-02 的 ~$13.5M 用户钓鱼盲签案**。两起事件请勿混为一谈,详见第 4 节。

---

## 1 背景

- **协议:** Venus Protocol —— BNB Chain 上最大的借贷协议之一,Compound 分叉架构,核心治理/风控合约为 Comptroller(Unitroller 代理)。
- **受害者:** 单一大户地址 `0x563617b87d8BB3F2f14BB5a581f2E19F80b52008`(社区识别为 Kuan Sun / @KuanSun1990),在 Venus 持有 vUSDT / vUSDC / vXRP / vETH / vWBETH 等大额抵押头寸。
- **攻击者:** `0x7fd8f825e905c771285f510d8e428a2b69a6202a`。SlowMist 将该攻击归因于朝鲜 **Lazarus Group**(此为安全方归因,非本所独立认定)。
- **时间:** 2025-09-02(链上 `updateDelegate` 交易时间戳 09:05:30 UTC,已核)。
- **手法定性:** 社工钓鱼 + 钱包扩展被篡改 + 硬件钱包盲签 → 代理权劫持。**协议合约本身未被攻破。**

---

## 2 根因:钓鱼盲签 / 恶意 delegate(合约没坏,坏在签名)

Venus 的 Comptroller 提供 `updateDelegate(address delegate, bool approved)` 接口,允许用户授权某地址代表自己执行借/还/赎回等操作——这是**协议设计内的合法功能**。问题不在合约,而在于受害者**在不知情下签署了这笔授权**:

1. **设备被控:** 攻击者伪造 Zoom 会议链接(经 Telegram 引导),受害者访问钓鱼站并在引导下运行恶意代码,设备被完全接管。
2. **钱包扩展被掉包:** 攻击者利用 Chrome 开发者模式,复制原版钱包扩展并以匹配 manifest 密钥的方式重新导入,**保留相同扩展 ID 而不触发完整性校验**,从而篡改扩展逻辑。
3. **操作被替换:** 受害者本意是执行 `redeemUnderlying`(赎回 USDT),被篡改的扩展在底层把它**替换成 `updateDelegate`**。
4. **硬件钱包盲签:** 受害者的硬件钱包**不支持详细签名数据解析且开启了盲签(blind signing)**,屏幕无法显示这其实是一笔"授予代理权"交易,受害者照常点了确认。
5. **授权落链:** 一笔 `updateDelegate(attacker, true)` 上链,攻击者获得对受害者 Venus 账户的完整代理权。

> 取证要点:**这条线和合约漏洞无关。** Comptroller 严格按代码执行了一次合法授权;唯一的"漏洞"是人——人看不懂 calldata,而硬件钱包在该场景下没有把语义翻译给人看。与 Polymarket 盲签授权劫持同构:**攻击面从"打穿合约"转移到"骗过签名确认"。**

---

## 3 攻击流程

```
[攻击前夜 09-01]
攻击者 0x7fd8…202a 预存约 21.18 BTCB + 205,000 XRP(用于代受害者还款、解锁抵押)
        │
[设备入侵]
伪造 Zoom 链接 → 钓鱼站运行恶意代码 → 受害者设备被完全控制
        │
[钱包掉包]
Chrome 开发者模式重导篡改版扩展(同 ID,不触发完整性校验)
        │
[盲签劫持]  TX 0x75eee705…be0e2 @ 2025-09-02 09:05:30 UTC
受害者本意 redeemUnderlying → 被替换为
  Comptroller.updateDelegate(0x7fd8…202a, true)   ← calldata: 0xddbf54fd + attacker + 0x01
硬件钱包盲签 → 攻击者取得代理权
        │
[抽干仓位]
攻击者以受害者名义:用 Lista 闪电贷 ~285 BTCB + 自有 BTCB/XRP 代还受害者负债
→ 赎回受害者抵押品(USDT/USDC/WBETH/FDUSD/ETH)至自有地址
```

---

## 4 规模统计

| 项目 | 数据 | 来源/核验 |
|---|---|---|
| 关键劫持交易 | `0x75eee705a234bf047050140197aeb9616418435688cfed4d072be75fcb9be0e2` | cast 已核 |
| 区块 / 时间 | block 59740608 / 2025-09-02 09:05:30 UTC | cast 已核 |
| 调用合约 (to) | `0xfD36E2c2a6789Db23113685031d7F16329158384`(Venus Comptroller / Unitroller) | cast 已核(合约有代码) |
| 调用方法 | `updateDelegate(address,bool)` 选择器 `0xddbf54fd` | cast 4byte + cast sig 双核 |
| 参数 | delegate = `0x7fd8…202a`,approved = `true(0x01)` | calldata 解码已核 |
| 受害者 | `0x563617b87d8BB3F2f14BB5a581f2E19F80b52008` | cast tx `from` 已核 |
| 攻击者 | `0x7fd8f825e905c771285f510d8e428a2b69a6202a` | calldata 参数 + PeckShield/CertiK |
| 初报损失 | ~$27M(未扣负债的毛额) | PeckShield 初报 |
| 实际净损 | **~$13.5M**(扣除受害者既有负债后) | PeckShield 修正 / SlowMist |
| 被抽资产(初报口径) | vUSDT $19.8M、vUSDC $7.15M、vXRP $146K、vETH $22K,及 285 BTCB | PeckShield/媒体(未逐笔链上核) |
| 追回 | **全额追回**(治理强制清算攻击者头寸) | Venus/Chainalysis-Hexagate |

**与 $3.7M 事件的区分(取证更正):**

| 维度 | 本案(钓鱼盲签) | $3.7M 事件 |
|---|---|---|
| 时间 | 2025-09-02 | 2026-03(约 3 月中) |
| 性质 | **用户被钓鱼盲签**,合约未破 | **协议级漏洞利用**(供应上限/Thena 喂价操纵 + 闪电贷) |
| 攻击对象 | 单一大户的私人仓位 | 协议市场机制本身 |
| 金额 | ~$13.5M(净) | ~$3.7M |
| 根因 | `updateDelegate` 盲签 | supply cap / 价格操纵 |

> 注:$3.7M 事件本所未做独立链上核验,此处仅据公开报道用于澄清两案不同,**不作为已核事实**。

---

## 5 资金追踪(Venus 是否暂停 / 追回)

- **协议暂停:** Hexagate 在攻击发生前约 18 小时已监测到可疑协议级活动并告警;劫持交易上链后约 **20 分钟,Venus 暂停了全部市场**(pause markets),并冻结 `EXIT_MARKET` 等操作,防止抵押品被进一步赎出。
- **强制清算:** Venus 发起**紧急治理投票(VIP)**,社区一致通过,授权对攻击者头寸进行**强制清算**,将被盗资产导向协议控制的回收地址。约 **攻击后 7 小时**完成对攻击者钱包的强制清算。
- **二次冻结:** 另有治理提案**冻结攻击者仍控制的约 $3M 资产**。
- **结果:** 约 **12 小时内全额追回并恢复运营**(UTC 21:58 宣布全面恢复)。攻击者非但未获利,因被冻结反而净亏约 $3M。
- **取证判断:** 本案"追回"依赖 Venus 治理对借贷市场的**特殊清算/暂停权限**——这是一把双刃剑(能救人,也意味着协议保有强干预能力)。对普通用户而言,**不能指望每次都被治理救回**;本案能追回有其偶然性(资产仍滞留在协议借贷头寸内、可被清算)。

---

## 6 防御建议

**针对个人 / 大户(本案核心教训):**
1. **关闭硬件钱包"盲签",启用明文/EIP-712 解析:** 本案致命点是硬件钱包未解析 calldata。务必使用支持交易明文解析的固件/机型,**看不懂的交易一律不签**。
2. **签名前模拟(simulate):** 用 Tenderly、钱包内置模拟、或交易前置防火墙(如 Blockaid/Pocket Universe 类)预演本笔交易的**资产/权限变更**;若看到"授予 delegate 权限"而你本意是赎回,立即终止。
3. **定期审查并撤销授权/代理:** 周期性检查 Venus `updateDelegate` 状态及各 ERC-20 approval(revoke.cash 等),对陌生 delegate/spender 立即撤销。
4. **隔离签名环境:** 高额仓位用专用、干净设备签名;**不要在装过 Zoom/会议类可疑软件、开过开发者模式的浏览器**上操作大额钱包。
5. **警惕"Zoom/招聘/投融资"社工剧本:** 伪造会议链接、要求"装客户端/运行脚本"是 Lazarus 等团伙的标准开场;任何要你运行代码/装东西的"会议"默认视为攻击。

**针对协议方:**
6. 对 `updateDelegate` 等高权限授权增加**前端二次确认 + 风险提示 + 链上监控告警**(本案 Hexagate 的提前预警是追回关键)。
7. 保留并演练**紧急暂停 + 治理快速响应**流程(本案 20 分钟暂停、7 小时清算是追回前提)。

---

## 7 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2025-09-01 | 攻击者预存 ~21.18 BTCB + 205,000 XRP,准备代受害者还款 |
| 攻击前 ~18h | Hexagate 监测到可疑协议级活动并告警 |
| 2025-09-02 09:05:30 | **劫持交易上链**:受害者盲签 `updateDelegate(0x7fd8…202a, true)`(tx `0x75eee…be0e2`,block 59740608)|
| 随后 | 攻击者用 Lista 闪电贷代还负债、赎回受害者抵押品至自有地址 |
| +约 20 分钟 | Venus **暂停全部市场**,冻结 EXIT_MARKET |
| +约 5 小时 | 安全校验后部分功能恢复 |
| +约 7 小时 | 紧急治理投票通过,**强制清算攻击者钱包** |
| +约 12 小时 | **全额追回**,UTC 21:58 全面恢复运营;另冻结攻击者约 $3M |

---

## 来源

- The Block —《Venus Protocol pauses after user loses funds in suspected phishing attack》 https://www.theblock.co/post/369040/venus-protocol-pauses-after-user-loses-27-million-in-suspected-phishing-attack
- SlowMist —《In-Depth Analysis of the $13 Million Venus User Hack》 https://slowmist.medium.com/slowmist-in-depth-analysis-of-the-13-million-venus-user-hack-13f35287a743
- PeckShieldAlert(经 blockchain.news 转载,$27M→delegate→0x7fd8…202a) https://blockchain.news/flashnews/venus-protocol-user-drained-of-about-27m-via-phishing-token-approval-to-0x7fd8-202a-key-trading-watchpoints
- PeckShield 修正(实际约 $13.5M,ChainCatcher) https://www.chaincatcher.com/en/article/2202653
- Chainalysis / Hexagate —《How Chainalysis and Hexagate Stopped the Venus Protocol Hacker》 https://www.chainalysis.com/blog/hexagate-and-community-stops-a-hack-on-venus-protocol/
- crypto.news —《Venus Protocol recovers $13.5M lost in phishing attack》 https://crypto.news/venus-protocol-recovers-funds-phishing-attack-2025/
- Protos —《Fears of $27M Venus Protocol hack turn out to be phishing attack on power user》 https://protos.com/fears-of-27m-venus-protocol-hack-turn-out-to-be-phishing-attack-on-power-user/
- (用于区分的 $3.7M 协议级事件,非本案)Cointelegraph —《Venus Protocol 3.7 million supply cap attack》 https://cointelegraph.com/news/venus-protocol-3-7-million-supply-cap-attack
- 链上自核:BSC RPC `https://bsc-dataseed.binance.org`,foundry `cast`(tx / block / 4byte / sig / code 已核,见第 4 节)

## 免责声明

本报告基于公开报道与链上可复核数据撰写,旨在技术复盘与安全教育。**不指认任何具体自然人**(攻击归因 Lazarus Group 系引用第三方安全机构结论,非本所独立认定);**不构成法律意见**;**不保证任何资金可被追回**(本案追回有其特定条件,不可推广)。地址、交易哈希与金额以链上数据为准,媒体口径金额可能存在初报/修正差异。© 2026 DuoLaSafe
