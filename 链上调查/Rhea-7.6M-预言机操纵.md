# Rhea Finance 被盗事件链上取证复盘:从"预言机操纵"到 Margin 滑点校验缺陷的真相

> DuoLaSafe 链上取证 · 事件 2026-04 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

种子线索"协调的预言机操纵"是 CertiK 等在事发数小时内发布的**初步推断**;Rhea 官方复盘与第三方取证(Rekt News、QuillAudits)随后确认,真正根因**不是预言机被喂价污染,而是 Burrowland 杠杆交易(Margin Trading V2)滑点保护逻辑的输入校验缺陷**——`get_token_out()` 把多跳兑换路由里各中间段的 `min_amount_out` 累加求和,得出一个与路由终端真实产出毫无关系的"虚高最小产出值",并以此通过安全检查;攻击者用 123 个假代币合约 + 25 个新建流动性池构造的"刻意设计的兑换路由",绕过该校验、批量开仓提走真实资产。**初报损失约 $7.6M,官方复盘修订为约 $18.4M**;截至发稿约 $11.2M 已返还/冻结。(均据报道,核心 tx/账户已在 NearBlocks 复核)

---

## 1 背景:Rhea Finance 及其"价格依赖"

- **Rhea Finance** 于 2025 年初由 NEAR 上的 **Ref Finance(DEX)** 与 **Burrow Finance(借贷,合约即 Burrowland)** 合并而成,据报道一度占 NEAR 生态 DeFi TVL 95% 以上,是该链主要的现货 DEX + 借贷 + 杠杆交易层。(据报道)
- 涉事功能是 **Margin Trading V2(2024-07 上线)**,构建在 Burrowland 借贷之上,开仓时通过 Ref Finance 执行兑换路由。
- **价格/安全依赖的关键事实**:Rhea 于 2025-08 宣布与 **Pyth Network** 合作、号称全产品线接入实时价格。但据 Rekt News 取证,**出事的 Margin 模块在滑点校验环节并未真正以 Pyth 喂价作为终端产出的强约束**——`is_min_amount_out_reasonable()` 拿到的是被累加污染的"最小产出值",Pyth 这道闸因输入已失真而形同虚设。这正是"预言机操纵"叙事产生混淆的来源:**问题不在喂价数据本身,而在协议如何计算并使用兑换产出。**(据报道)

---

## 2 漏洞根因:不是预言机污染,是滑点校验"数错了东西"

按 Rekt News / QuillAudits 取证,核心缺陷在 Burrowland 的 `get_token_out()`:

- 该函数对一条多跳兑换路由,**把每个中间步骤的 `min_amount_out` 累加(sum)**,而非隔离出路由**终端**的真实产出。
- 攻击者设计的路由**反复把 USDC 当作中间跳**:`zec.omft.near → fake → fake → USDC → fake → USDC → … → fake → USDC`。每一段经过 USDC 的腿都贡献一个自己的 `min_amount_out`,被累加进总和。
- 于是滑点保护算出一个**天文级的 `min_token_p_amount`**,并把它送入基于 Pyth 的合理性检查 `is_min_amount_out_reasonable()` —— 检查"通过"了,但它校验的是一个与现实无关的数字。
- 路由实际执行后,真实返回的 USDC 仅 **7,925 个最小单位**,而被"验证通过"的最小值是 **32,595,520,035,000,000,000,000**——**相差超过 410 万倍**。
- 最致命的一环:结算函数 `on_open_trade_return()` **"到账多少就记多少",对此前那个已验证的最小值不做任何回校**。校验用的是中间产出、结算用的是终端实收,**两者从未被强制要求一致**。

> 取证定性:这是一个 **设计层/逻辑层的输入校验缺陷(business-logic flaw)**,而非合约被攻破或私钥泄露。代码"按写的执行",但没人追问"一条路由能否被设计成让这个累加变得灾难性地错"。BlockSec 2022 年对 Burrowland 的两次审计指出过 7 个中低风险问题,但 Margin V2 是审计两年后(2024)才加入的功能。(据报道)

---

## 3 攻击流程(据报道,关键节点已链上复核)

1. **准备期(2026-04-13 起)**:据报道攻击者约 **42 小时**预备,前一天还做了三轮完整"彩排"。Subject 钱包于 04-15 经 dust 转账创建,5 分钟内经 `intents.near` 充值,再分发至中间账户。
2. **铺池(04-16 上午)**:部署 **123 个假同质化代币合约**(共享 code hash `BBeoVgxZC5Ce1ef7nErevX98QonNsedBFfqzep5RV1Vu`);在 Ref Finance 新建 **25 个流动性池(pool 8514–8538)**,分层结构:ZEC ↔ 一级假币、假币 ↔ 假币交叉池、假币 ↔ USDC 池。
3. **构造恶意路由开仓**:用上述"刻意设计的兑换路由",通过 5 个 worker 钱包**批量开大量 Margin 仓位**。借出的 debt token 被导入攻击者自己的假币池,**只有微不足道的 position token 返还给协议**,仓位严重抵押不足。
4. **校验绕过 + 结算**:滑点校验因累加缺陷被绕过;结算函数照单全收实际到账,缺口达 410 万倍量级。
5. **清算级联**:大量远低于债务要求的仓位触发**强制清算**,**抽干协议储备池**、放大损失。
6. **撤离**:5 个 worker 钱包并行分批从假池撤流动性 → 汇入 master 账户 → 归集到 collector 账户。整轮据报道 worker 钱包派发后 **10 秒内、约 1,142 笔交易**完成主体提取。

**链上复核(NearBlocks)**:
- Worker 开仓代表性交易 `4H5kQ4HNWX4cqdksbwarbwmVZYVwRub25eWT2k97r1AN`:✅ 已核 —— 状态 Success,2026-04-16 09:47:12 UTC,签名/接收方为 worker `d4e8…0b03`,方法 `open_position`,经 Burrow 开仓并在 Ref 执行多笔 swap。
- Collector 账户 `31ac7a2705…724a540`:✅ 已核 —— 账户存在,**1,142 笔交易**,创建于约两个月前,末次活动 2026-04-16,与取证叙述吻合。

---

## 4 规模统计

> 金额单位 USD(部分按报道时点估算);"初报"= CertiK/媒体 04-16 口径,"修订"= Rhea 官方 04-17 复盘口径。

| 项目 | 数值 | 来源/状态 |
|---|---|---|
| 初报损失 | ~$7.6M | CertiK/媒体 04-16,据报道 |
| **修订后总损失** | **~$18.4M** | Rhea 官方复盘 04-17,据报道 |
| 已返还/冻结合计 | ~$11.2M | 据报道(The Block / AMBCrypto) |
| 攻击者返还 USDC | ~$3.36M(约 3.359M USDC) | 存回借贷合约,据报道 |
| 攻击者返还 NEAR | 1.56M NEAR(约 $3.5M) | 存回借贷合约,据报道 |
| USDT 被冻结 | ~$4.34M(含 Tether 冻结 $3.29M + NEAR Intents $1.05M) | 据报道 |
| 仍在外追踪中 | ~$5.6M | 据报道 |
| ZEC 进入屏蔽池(难追) | ~$4M(约 12,095 ZEC) | 经 `zec.omft.near` 入 Zcash shielded pool,据报道 |
| 桥至以太坊的 USDC | ~$3.4M 以 aUSDC 存入 Aave | 可追踪、当时未拉黑,据报道 |

被盗资产跨 **USDC / USDT / ZEC / NEAR(wNEAR)** 多种。

---

## 5 资金追踪(据报道,主路径 tx 见下)

- 归集路径:worker 钱包 → master `72633832…1af621c5` → collector `31ac7a27…724a540`。
- 经 **NEAR Intents** 三步出金:① 内部 intents 向兄弟钱包扇出;② `ft_withdraw` 取回真实 USDC 至 NEAR;③ 对 `zec.omft.near` 调 `ft_withdraw`,将 ZEC 直接打入 Zcash 统一地址/屏蔽池。
- **USDC 约 $3.4M** 桥至以太坊,落入攻击者 ETH 钱包 `0xbb5fa936469cadb8907f3aef80f5b53f55bc11f6`,存入 Aave 成 aUSDC。
- **取证警示信号**:操作中途出现刻意的 **USDT→USDC** 兑换,显示攻击者**预知 Tether 可冻结 USDT**;批量提取尺寸高度均一(约 10,583 USDC / 10,578 USDT 区块),指向**脚本化提取流水线**。

Master→Collector 代表性转账(据报道):
- 1,700,000 NEAR:`AJ42stVaKFsU2xYVZxzKFVRHvraeWgeEWxym7orJiGEY`
- 460,455 USDC:`CXEnUrkeACi96BTNMJTbq4umK1EGFhnTfqJpieBMUd8F`
- 446,582 USDT:`CHmaMXtnXrU9mBe3GYPPnGMMPT8ziKaJien9vdJ8VkPZ`
- 7,095 ZEC:`6NyvczzGBdEDZtxsT7XYxcGD2fdSZcVrWdGX7sS1PE1p`
- Collector→Burrow 部分返还:`Fe4JXLSq8iBJFTVRvo6ye48G8JGofuG5xfwUgfn55Yca`

> 以上交易哈希/账户均以 NearBlocks 为准可自行复核;本报告仅对 collector 账户与 worker 开仓代表交易做了直接核验(见 §3),其余 tx 标"据报道"。

**归因**:Aurora Labs / Near Intents 联合创始人 Alex Shevchenko 据报道向攻击者发送链上消息,称"已识别你及你的关联账户"并要求返还剩余资金(联系 tx 据报道为 `6r5c2iZighKJRcjXLkBbhQJxZ5dmzKTZDnqT7cmd8gh6`)。**本报告不指认任何具体自然人。**

---

## 6 修复与防御建议

针对本案"校验中间产出、结算终端实收、二者不强制一致"的根因:

1. **终端产出强约束,而非累加中间值**:滑点/最小产出校验必须基于**路由终端的真实 token 与数量**;严禁对多跳路由各段 `min_amount_out` 做求和。结算时**用同一口径回校实收 vs 已验证最小值**,不一致即 revert。
2. **多源 + TWAP 抗操纵定价**:对抵押/开仓估值采用 **TWAP(时间加权均价)** 与**多源预言机交叉校验**(Pyth + 链上 TWAP + 偏离阈值熔断),避免单笔/瞬时价或新建池价格直接入账。
3. **新池/新资产流动性阈值与冷却期**:对作为抵押或路由中介的资产,设**最小流动性、最小价格历史时长、最小池龄(cooling period)**;两小时内新建的池不得用于喂价或抵押估值。
4. **新功能纳入审计与不变量测试**:Margin V2 在初版审计两年后才加入却未同等覆盖——任何改动核心估值/结算路径的功能须**重新审计 + 形式化不变量**(如"已验证最小值 ≤ 实际产出")。
5. **限速与异常熔断**:单地址高频批量开仓、10 秒内上千笔、储备池快速抽干等模式应触发**自动暂停**。
6. **稳定币冻结协同预案**:本案 Tether 冻结发挥关键作用,协议应预置与发行方/CEX 的应急联络与拉黑流程。

---

## 7 时间线(UTC,据报道;✅ 为已链上复核节点)

- **2026-03 月中**:Rhea 据报道向 Zcash 社区提交 $54,200 的 Zcash Gateway 集成资助申请。
- **2026-04-13**:攻击准备开始;同日 Zcash Community Grants 批准该集成(攻击前三天)。
- **2026-04-15**:Subject 钱包经 dust 创建,5 分钟内经 `intents.near` 充值并分发。
- **2026-04-16 上午**:部署 123 个假代币、建 25 池(8514–8538);worker 派发后约 10 秒内 ~1,142 笔交易完成主体提取。✅ Worker 开仓 tx `4H5kQ…r1AN` 时间戳 **09:47:12 UTC**;✅ Collector 账户末次活动 04-16。
- **2026-04-16(攻击后数小时)**:CertiK Alert 首发预警(初步定性"预言机操纵");Tether 确认冻结 $3.29M;Rhea 发首份声明(仅称暂停受影响合约)。
- **2026-04-17**:Rhea 发布完整技术更新,确认 **Margin Trading 滑点保护缺陷**为根因,损失修订为 **~$18.4M**;QuillAudits 发布取证线程;Alex Shevchenko 发链上消息归因并喊话返还。
- **此后**:约 $11.2M 返还/冻结,约 $5.6M 仍在追踪;约 $4M ZEC 进入 Zcash 屏蔽池追踪难度高。

---

## 来源

- Rekt News — *Rhea Finance Rekt*(核心技术取证、账户/tx):https://rekt.news/rhea-finance-rekt
- Halborn — *Explained: The Rhea Finance Hack (April 2026)*:https://www.halborn.com/blog/post/explained-the-rhea-finance-hack-april-2026
- AMBCrypto — *Rhea Finance revises exploit losses to $18.4M, confirms slippage flaw*:https://ambcrypto.com/rhea-finance-revises-exploit-losses-to-18-4m-confirms-slippage-flaw-as-funds-partially-recovered/
- The Block — *Rhea Finance post-mortem puts exploit losses at $18.4 million*:https://www.theblock.co/post/397961/rhea-finance-post-mortem-exploit-losses-18-4-million-double-initial-estimates
- BeInCrypto — *Rhea Finance Loses $7.6 Million in Oracle Exploit*:https://beincrypto.com/rhea-finance-near-exploit-oracle/
- CoinEdition — *$18.4M Rhea Finance Hack Built Over Two Days*:https://coinedition.com/18-4m-rhea-finance-hack-built-over-two-days-post-mortem-reveals/
- 链上复核:NearBlocks(账户 `31ac7a27…724a540`、交易 `4H5kQ…r1AN`)— https://nearblocks.io

---

## 免责声明

本报告基于公开报道与公开链上数据整理,部分情节以"据报道"标注、未经一手复核者不应视为定谳。本报告**不指认任何特定自然人**,仅就链上地址/合约行为做技术描述。本报告**不构成法律意见、投资建议或任何追回保证**,亦不保证被盗资金可被追回。引用第三方报道不代表 DuoLaSafe 对其准确性背书。© 2026 DuoLaSafe.
