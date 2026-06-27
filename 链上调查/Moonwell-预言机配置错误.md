# Moonwell cbETH 预言机配置错误事件复盘(MIP-X43)

> DuoLaSafe 链上取证 · 事件 2026-02-15 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

2026-02-15,Moonwell 治理提案 MIP-X43 上线 Chainlink OEV wrapper 时,把 cbETH 的喂价误配为**只取 cbETH/ETH 这一段、漏掉了 ETH/USD 那一段**,导致 cbETH 的美元价从约 $2,200 被错算为约 **$1.12**;清算人与套利机器人在错价窗口内以约 $1 的代价夺取了 **1,096.317 cbETH**,给协议留下约 **$1,779,044** 坏账。这是一起**预言机价格组合配置错误**事件,非合约被盗、非私钥泄露,根因在变更评审与上线前健全性校验缺失。

---

## 1 背景:Moonwell 借贷与预言机喂价架构

Moonwell 是一套 Compound/Aave 式的超额抵押借贷协议,部署在 Base、Optimism Mainnet 与 Moonbeam。用户存入抵押资产(如 cbETH)按一定抵押率借出其他资产;当抵押品的美元价值跌破清算线,清算人可代偿部分债务、折价夺取抵押品。因此**抵押品的美元定价**是清算/借贷安全的核心输入,完全依赖预言机。

cbETH(Coinbase Wrapped Staked ETH)本身没有直接的链上 USD 喂价。其美元价需要**两段价格组合**:

```
cbETH/USD = (cbETH/ETH 兑换比率) × (ETH/USD 价格)
```

- cbETH/ETH:cbETH 相对 ETH 的兑换率,数值约 1.x(cbETH 含质押收益,略高于 1)。
- ETH/USD:ETH 的美元价,数量级约 2,000+。

只有把两段相乘,才能得到 cbETH 约 $2,200 的真实美元价。本次事件,正是这条乘法链路的第二段被漏掉。

MIP-X43 的目的是为 Base 与 Optimism 核心市场启用 **Chainlink OEV wrapper**(Oracle Extractable Value 包装合约,用于回收预言机更新带来的可提取价值)。在替换喂价路由的过程中,cbETH 的价格派生公式被错误改写。

---

## 2 漏洞根因:价格组合漏了 ETH/USD 一段(核心)

根据 Moonwell 治理论坛官方事件总结(MIP-X43 cbETH Oracle Incident Summary)及多家安全/媒体报道,根因明确为**预言机喂价配置错误**:

- 正确逻辑:`cbETH/USD = cbETH/ETH × ETH/USD`。
- 实际配置:预言机**只返回了 cbETH/ETH 这一段的原始兑换率**,未再乘以 ETH/USD。
- 结果:cbETH 的"美元"报价直接退化成约 **1.12**(即 cbETH/ETH 比率量级),而非约 **$2,200**。错价幅度约 **1,960 倍**。

这是典型的**复合预言机(composite oracle)漏配一段基础价格**:配置层把多段价格的乘积链路断在了中间,系统拿一个"无量纲的兑换比率"当成了"美元价"。代码层面表现为价格派生公式/缩放(scaling)逻辑错误,而非外部 Chainlink 数据源本身被污染——这一点区别于"喂价数据被攻击"的传统预言机攻击。

补充背景(取证如实记录,不作主观渲染):多家媒体(Cointelegraph、Decrypt、crypto.news 等)及审计员 pashov 指出,相关 pull request 的部分提交在 GitHub commit 记录中显示由 AI 模型 **Claude Opus 4.6** 共同署名(co-authored),被部分报道称为"首批与 AI 代写 Solidity 相关的重大 DeFi 事件之一"。pashov 同时评价该错误"是连资深 Solidity 工程师也可能犯的",真正的失效在于缺乏端到端集成测试与上线前校验。Moonwell 官方未将事件直接定性为"由 AI 代码导致"。**DuoLaSafe 立场:本报告不对代码作者归因,根因定性为配置评审与上线校验缺失。**

---

## 3 影响 / 利用过程

错价一旦生效,cbETH 抵押头寸在协议账面上瞬间"几乎一文不值",同时 cbETH 作为借出资产又变得"极其便宜"。两个方向都被滥用:

1. **清算方向(已发生主要损失)**:cbETH 抵押头寸被判定为严重不足额,清算人/机器人**以约 $1 的代偿成本**夺取大量 cbETH 抵押品。错价让清算几乎零成本,collateral 被以白菜价搬空。
2. **借贷方向**:错价下 cbETH 报价仅约 $1.12,使用者可用极少抵押"超额借出"被低估的 cbETH,凭空制造更多坏账(媒体报道描述了这一机制,具体被利用规模归入下表统计口径)。

合计:清算人共夺取 **1,096.317 cbETH**;协议产生约 **$1,779,044** 坏账。Moonwell 声明仅 Base 上的 cbETH 核心市场受影响,**Base 与 OP Mainnet 上其他市场未受波及**。

错价窗口极短(检测到讹误仅在执行后约 4 分钟),但因预言机修正需经治理投票与时间锁,清算在窗口内已造成既成损失。

---

## 4 规模统计

| 项目 | 数值 | 来源/口径 |
|---|---|---|
| 事件时间(MIP-X43 执行) | 2026-02-15 18:01 UTC | Moonwell 治理论坛官方总结 |
| 监控检测到讹误 | 2026-02-15 18:05 UTC(约 4 分钟后) | 同上 |
| cbETH 错误报价 | ≈ $1.12 | 多源一致 |
| cbETH 真实/参考价 | ≈ $2,200 | 多源一致;后续补偿亦按 $2,200 计 |
| 错价倍数 | ≈ 1,960× | 由上述两值推算 |
| 被夺取 cbETH | 1,096.317 cbETH | Moonwell 官方/媒体一致 |
| 协议总坏账 | ≈ $1,779,044(报道亦写 $1,779,044.83) | Moonwell 官方总结 |
| 其中 cbETH 计价坏账 | ≈ $1,033,393.71(467.7556 cbETH) | Moonwell 官方总结 |
| 受影响借款人 | 181 名(Base) | 恢复方案口径 |
| 净受损口径(补偿基准) | ≈ $2.68M 净损失 | 恢复方案口径(见第 5 节) |
| 受影响链/市场 | 仅 Base cbETH 核心市场 | Moonwell 声明 |

> 注:坏账 ≈ $1.78M 与补偿口径 ≈ $2.68M 不矛盾——前者是协议账面坏账,后者是按 cbETH $2,200 计算、覆盖 181 名借款人的**净损失补偿口径**,统计基准不同。
>
> 取证留白:截至数据截止日,公开来源(官方总结、The Block、Decrypt、Cointelegraph 等)**均未披露可复核的合约地址或交易哈希**(预言机聚合器、ChainlinkCompositeOracle、cbETH mToken/市场、MIP-X43 时间锁交易、具体清算 tx)。本报告据红线**不臆造任何地址/哈希**;待官方或浏览器侧出现可核对的链上凭证后再行补录。

---

## 5 处置

- **止损**:Moonwell 将 Base 上受影响的 cbETH 核心市场**供应上限与借款上限降至 0.01**,阻止新借款与新抵押供应,遏制进一步损失。
- **修正排期**:预言机喂价的永久修正须经治理投票与时间锁(报道提及约 5 天的投票/timelock 周期),修复提案于事件次日(2026-02-16)排上治理。窗口内清算因此仍有发生。
- **用户补偿(恢复方案)**:针对 Base 上 181 名借款人、约 **$2.68M 净损失**:
  - 即时拨付约 **$310,000**,来自 **Apollo Treasury**,按比例(pro-rata)分配给受影响地址;
  - 剩余约 **$2.37M** 通过未来协议收入(净协议费 + OEV 收入)在**最长 12 个月**内偿付,未领取部分到期失效;
  - 分发采用 **Sablier** 流式支付;
  - 方案需 Moonwell DAO 批准,并附带将 Apollo DAO(MFAM)并入主 Moonwell DAO(WELL)的治理整合。

历史背景(如实记录,反映这是 Moonwell 半年内第三起预言机相关事件):

| 时间 | 事件 | 损失口径 |
|---|---|---|
| 2025-04 | Term Finance 配置错误 | ≈ $1.6M 损失(约 $1M 已挽回) |
| 2025-10 | Chainlink 定价错误(AERO/VIRTUAL/MORPHO) | $12M+ 清算,$1.7M 坏账 |
| 2025-11 | wrsETH 预言机故障 | ≈ $3.7M 坏账 |
| 2026-02 | 本次 cbETH 配置错误 | ≈ $1.78M 坏账 |

> 半年内预言机相关坏账累计已超 $7M(媒体口径),提示预言机变更治理是该协议的系统性薄弱环节。

---

## 6 修复与防御建议

针对"复合预言机漏配一段价格"这一类配置错误,DuoLaSafe 建议:

1. **预言机配置评审(强制四眼)**:任何喂价路由/派生公式变更须独立第二人评审,逐段核对价格组合链路(cbETH/ETH × ETH/USD)完整、量级、单位与缩放因子一致。AI 辅助生成的喂价/缩放代码必须经人工逐行复核,不得直接合入。
2. **价格完整性校验(链上断路器)**:在合约层加入价格健全性断言——单步价格相对上一区块/参考源的**偏离阈值**(如 >5% 即拒绝或熔断)、价格**量级/边界检查**(cbETH 美元价不可能落在 $1 量级)、组合价格的**最小价格段数校验**。错价达 1,960 倍本应被任何边界检查拦截。
3. **上线前端到端健全性检查(integration test)**:在 fork 主网环境对真实 Chainlink 喂价做端到端集成测试,断言新路由下 cbETH/USD 落在合理区间;此举可在不动用真实资金的前提下提前暴露漏配的 ETH/USD 段——正是 pashov 指出的缺失环节。
4. **变更与告警闭环**:本次监控在约 4 分钟内已检出讹误,但缺少能在**治理时间锁之外**快速生效的应急熔断(guardian pause)。建议为预言机异常配置可由 guardian 即时触发的"市场暂停/喂价冻结",绕过 5 天 timelock。
5. **抵押品分类风控**:对 cbETH 等 LST/LRT 类多段定价资产单列预言机风险等级,变更时触发更高级别评审与更严边界。

---

## 7 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2025-04 | Term Finance 配置错误事件(背景) |
| 2025-10 | AERO/VIRTUAL/MORPHO Chainlink 定价错误(背景) |
| 2025-11 | wrsETH 预言机故障(背景) |
| 2026-02-15 18:01 | MIP-X43 执行,启用 Chainlink OEV wrapper;cbETH 喂价被误配为仅取 cbETH/ETH,漏掉 ETH/USD,报价跌至 ≈ $1.12 |
| 2026-02-15 18:05 | 监控系统检出价格讹误(约 4 分钟后);清算/套利已在窗口内发生 |
| 2026-02-15(随后) | cbETH 核心市场供应/借款上限降至 0.01,止损;清算人累计夺取 1,096.317 cbETH,协议坏账 ≈ $1,779,044 |
| 2026-02-16 | 永久修正提案排上治理(需投票 + 时间锁) |
| 2026-02-18 前后 | 官方事件总结发布;AI 共同署名与审计讨论见诸媒体 |
| 2026-02-19 前后 | 恢复/补偿方案公布:Apollo Treasury 即拨 ≈ $310K + 未来收入 ≈ $2.37M / 12 个月,经 Sablier 分发,覆盖 181 名借款人 ≈ $2.68M 净损失 |

---

## 来源

- Moonwell 治理论坛(官方一手):MIP-X43 cbETH Oracle Incident Summary — https://forum.moonwell.fi/t/mip-x43-cbeth-oracle-incident-summary/2068
- The Block：DeFi lending protocol Moonwell hit with $1.8 million bad debt after oracle misconfiguration — https://www.theblock.co/post/390302/defi-lending-protocol-moonwell-hit-with-1-8-million-bad-debt-after-oracle-misconfiguration
- Decrypt：Oracle Error Leaves DeFi Lender Moonwell With $1.8 Million in Bad Debt — https://decrypt.co/358374/oracle-error-leaves-defi-lender-moonwell-1-8-million-bad-debt
- Cointelegraph：$1.78M 'Vibe-Coded' Oracle Bug Puts AI-Coauthored Contracts Under Scrutiny — https://cointelegraph.com/news/moonwell-exploit-cbeth-oracle-misprice-ai-commits-testing-audits
- crypto.news：Moonwell's AI-coded oracle glitch misprices cbETH at $1, drains $1.78M — https://crypto.news/moonwells-ai-coded-oracle-glitch-misprices-cbeth-at-1-drains-1-78m/
- gncrypto.news：Moonwell hit with 1.78 million bad debt after cbETH oracle glitch — https://www.gncrypto.news/news/moonwell-oracle-error-cbeth-misprice-leaves-18m-bad-debt/
- Cryptonomist：Moonwell recovery: $2.68M cbETH compensation & governance — https://en.cryptonomist.ch/2026/02/19/moonwell-recovery-cbeth-compensation/

## 免责声明

本报告基于上述公开来源与可获取信息整理,仅供安全研究与风险教育之用。报告**不指认任何具体个人或团队**对事件负责;对 AI 共同署名等事项仅作如实记录,不作责任归因。本报告**不构成任何法律意见、投资建议或审计结论**。因公开来源未披露可复核的合约地址与交易哈希,相关链上凭证留待后续补录,本报告内不臆造任何地址或哈希。

© 2026 DuoLaSafe
