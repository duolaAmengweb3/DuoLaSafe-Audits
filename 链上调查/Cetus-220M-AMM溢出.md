# Cetus Protocol ~$220M 被盗事件链上取证复盘(Sui 链 · 2025-05)

> DuoLaSafe 链上取证 · 事件 2025-05 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

攻击者利用 Cetus CLMM 流动性数学中 `checked_shlw`(左移溢出校验)的一个**错误掩码常量**,在添加流动性时让 u256 左移悄然溢出、最高有效位被截断,致使协议把"添加巨量流动性所需的代币"误算成近乎 1 个单位,从而以极少代币撬动天量流动性头寸、再抽走真实储备;单日损失约 **$220M–$223M**,其中约 **$60M** 经跨链桥外逃至以太坊,约 **$162M(约 1.6 亿)** 在 Sui 链上被验证者紧急冻结,后经链上治理投票返还。本文仅就公开技术材料复盘根因与资金路径,Sui 链上凭证以 Sui 浏览器为准。

---

## 1 背景:Cetus AMM 与集中流动性数学

Cetus Protocol 是 Sui 生态最大的 DEX / AMM,采用集中流动性做市(CLMM,Concentrated Liquidity Market Maker,类似 Uniswap V3 模型)。其核心机制:

- 流动性提供者(LP)在一个**价格区间(tick 区间)**内提供流动性,而非全价格区间;区间越窄,同等资金的"虚拟流动性"杠杆越高。
- 系统需要在"添加流动性"时,根据目标流动性 `L`、当前价格、tick 边界,反算出需要存入多少 token A / token B(`get_delta_a` / `get_delta_b`)。
- 这套反算依赖 **u256 定点数运算**,其中包含大量移位(shift)操作做定点缩放。移位若溢出而不被正确拦截,token 数量的换算就会被腐蚀。

本次漏洞正落在"添加流动性时反算所需 token A 数量"这一步的溢出校验上。

> 据公开分析,受攻击主体为 haSUI/SUI 等池子;BlockSec/SlowMist 标注目标池对象 `0x871d8a227114f375170f149f7e9d45be822dd003eba225e83c05ac80828596bc`(据报道,Sui 浏览器待复核)。

---

## 2 漏洞根因:`checked_shlw` 溢出校验的掩码错误(核心)

### 2.1 缺陷代码

漏洞位于 `get_delta_a` 计算路径中调用的 `checked_shlw`(checked shift-left word,带校验的左移)。该函数本应在执行"左移 64 位"前,先判断输入是否过大、左移后会超出 u256 范围;若会溢出则报错中止。

问题出在它的**溢出判定掩码用错了常量**(多个安全方口径一致):

- 实际使用的掩码:`0xffffffffffffffff << 192`,数值约为 `2^256 − 2^192` —— 这是一个**极大**的阈值。
- 正确的边界应为:`1 << 192`(即 `2^192`)。

### 2.2 为什么能"用极少代币撬动巨量流动性"

校验逻辑大致是"输入若 ≥ 掩码则视为溢出"。由于掩码被错误地设成了 `2^256 − 2^192` 这个极大值:

- 任何**大于 `2^192` 但小于 `0xffffffffffffffff << 192`** 的输入,都会**通过**这个溢出检查(因为它没达到那个被抬高的错误阈值)。
- 但这类输入一旦真的**左移 64 位**,结果就会**超出 u256 范围**,高位被静默截断(silent truncation)。

这个被截断、被腐蚀的中间值,随后被用于 `get_delta_a`(添加流动性所需 token A 数量)的计算。结果是:

> 协议在"记账上"给攻击者记入了一个**天量的流动性额度**,但"算出来要存入的 token A"却被腐蚀成**近乎 1 个单位**。

据 SlowMist/BlockSec 披露,攻击者一次添加流动性时**声称添加** `10,365,647,984,364,446,732,462,244,378,333,008` 这一量级的流动性,而**实际只付出约 1 个 token**。一旦这个"低价铸造"的头寸被系统接受,攻击者再**移除流动性**时,就按被夸大的记账兑付了**真实的池子储备**。

本质:**记账(虚增的流动性)与实付(被截断的、近乎 0 的存入)之间被人为撕裂**,差额即被攻击者从池子真实储备中提走。

### 2.3 修复方向

正确做法是在左移前强制判断 `n >= 1 << 192` 即视为溢出并中止(或等价地掩出高位、若有置位则中止)。SlowMist 给开发者的建议:对智能合约中**所有数学函数的边界条件**做严格校验。

---

## 3 攻击流程(据 SlowMist / BlockSec 复盘,链上交易待 Sui 浏览器复核)

各安全方口径基本一致,典型单池攻击分四步:

1. **闪电贷 + 砸价**:借入约 **10,024,321.28 haSUI**(并/或换出约 **5,765,124.79 SUI**),把目标池价格瞬间砸低约 99.9%,把价格推到一个极端 tick。
2. **开极窄区间头寸**:在极窄的 tick 区间(据报道 ticks 300000–300200,区间宽度约 1.00496621%)创建流动性头寸 —— 区间越窄,触发溢出路径所需的数值越易构造。
3. **触发溢出、低价铸造**:利用 `checked_shlw` 掩码缺陷,使 `get_delta_a` 反算出的"所需 token A"被截断为约 1 个单位,却铸造出 `1.03×10^34` 量级的天量流动性头寸。
4. **移除流动性、抽走真实储备**:分多笔交易移除被虚增的流动性,提走池中真实的 haSUI / SUI 等储备;归还闪电贷后净留约 10,024,321.28 haSUI 与 5,765,124.79 SUI(据报道)。

该套路在**多个池子**上重复执行,逐池抽干。

> 据 BlockSec,攻击前两天攻击者曾有一次**失败的预演尝试**(待复核)。

---

## 4 规模统计

| 项目 | 数值 | 来源口径 / 状态 |
|---|---|---|
| 事件时间 | 2025-05-22 | SlowMist / BlockSec / The Block |
| 总损失(估) | ~$220M–$223M(部分报道达 $230M) | 各方区间,口径略有出入 |
| 经跨链桥外逃至以太坊 | ~$60M | SlowMist / DL News |
| Sui 链上被冻结 | ~$162M(DL News 记 ~$160M) | The Block / DL News |
| 攻击声称添加的流动性(单笔) | 10,365,647,984,364,446,732,462,244,378,333,008(~1.03×10^34) | SlowMist / BlockSec |
| 实际付出 | 约 1 个 token | SlowMist / BlockSec |
| 错误掩码 | `0xffffffffffffffff << 192`(≈2^256−2^192) | Dedaub / BlockSec / SlowMist |
| 正确边界 | `1 << 192`(2^192) | Dedaub / BlockSec |

> 金额区间($220M / $223M / $230M)因统计快照时点、币价、是否含未提走部分而异,本文标"约";精确以各安全方原文与链上快照为准。

---

## 5 资金追踪(含部分被 Sui 验证者冻结)

**外逃部分(~$60M):** 攻击者将一部分资产经 Sui Bridge、Circle、Wormhole、Mayan 等桥/通道跨出至以太坊(据报道)。BlockSec 标注的 EVM 落点地址 `0x89012a55cd6b88e407c9d4ae9b3425f55924919b`,涉及约 3,000 USDT、40.88M USDC、1,771 SOL、8,130.4 ETH;并进一步将约 20,000 ETH 转入 `0x0251536bfcf144b88e1afa8fe60184ffdb4caf16`(据报道,EVM 浏览器待复核)。

**冻结部分(~$162M):** Sui 验证者协同采取紧急行动,在链上拦截攻击者控制的地址,使大部分被盗价值滞留在 Sui 上,未能完全桥出。

**治理返还:** Sui 社区发起链上治理投票,将冻结资产移交由 **Cetus + Sui Foundation + OtterSec** 共管的多签信托(经一次网络升级执行)。据报道,投票于 2025-05-28 显示约 52% 支持(DL News 快照),正式截止 6-03、可于 5-29 提前关闭;另有报道称早期(5-29 前后)支持率达约 90%。该"由验证者冻结/由治理返还"的做法引发**中心化与抗审查性**争议:批评者认为依赖中心化决策侵蚀了区块链的去信任属性。

**白帽要约与赔付:** Cetus 曾向攻击者提出**白帽要约**(据报道含约 $6M 量级 / 一定数量 ETH 作为奖励、不予追责),攻击者未接受并开始尝试洗钱(据报道)。Cetus 最终以"返还的 ~$162M + 自有现金储备约 $7M + Sui Foundation 约 $30M USDC 贷款"组合,赔付用户、并在事件后约两周(据报道 2025-06-08 前后)重启平台,受影响池子恢复至原流动性的约 85%–99%。

> 取证声明:本节"地址 / 交易哈希 / 桥路径 / 投票百分比"均来自安全方与媒体报道,**未在本次工作中逐一在 Sui / 以太坊浏览器核验**,一律标"据报道 / 待复核";Sui 为非 EVM 链,object/交易凭证以官方 Sui 浏览器(suiscan / suivision)为准。本文不指认任何具体个人或实体为攻击者。

---

## 6 修复与防御建议

1. **数学库边界全覆盖审计**:对所有移位 / 缩放 / 定点运算的溢出校验,逐一核对掩码常量与比较方向。本案根因即一个常量(`0xffff…<<192` vs `1<<192`)之差。正确实现:左移前判断 `n >= 1 << 192` 即溢出中止。
2. **不可信任"看起来对"的 checked 函数**:命名带 `checked_`/`safe_` 不代表逻辑正确;应有针对溢出临界值的**单元测试与不变量测试**(property-based / fuzzing),专门覆盖 `2^192` 附近边界。
3. **添加/移除流动性的对账不变量**:校验"记入流动性"与"实际转入储备"的一致性,任何"近乎 0 存入换天量流动性"应触发熔断。
4. **CLMM 极窄 tick 区间 + 闪电贷砸价**应纳入风控模型:对单交易内"价格剧烈偏移 + 极窄区间建仓 + 大额移除"组合设阈值监控。
5. **应急可暂停 + 事件响应预案**:Cetus 之所以能挽回大部分,得益于 Sui 验证者层的紧急冻结能力 —— 但这也暴露 L1 干预的中心化争议,项目方应在合约层具备自有的快速暂停 / 限额机制,减少对 L1 救援的依赖。

---

## 7 时间线(据公开报道,精确凭证以链上为准)

| 时间(2025) | 事件 |
|---|---|
| 5-22 | 攻击发生;社区发现 Cetus 流动性骤降、池子被掏空,估损约 $220M–$230M;约 $60M 经桥外逃至以太坊 |
| 5-22(同日) | Sui 验证者协同在链上拦截/冻结攻击者地址,约 $162M 滞留 Sui |
| 5-22 前两天 | 据报道攻击者曾有一次失败的预演尝试(待复核) |
| 5-28 | DL News 报道治理投票约 52% 支持(快照) |
| 5-29 | 投票可提前关闭;另有报道称早期支持率约 90% |
| 6-03 | 投票正式截止日 |
| 约 6-08 | Cetus 重启平台;以"返还资金 + 自有储备 + Sui Foundation 贷款"赔付用户,池子恢复约 85%–99% |

---

## 来源

- SlowMist(慢雾):《Analysis of the $230 Million Cetus Hack》— https://slowmist.medium.com/slowmist-analysis-of-the-230-million-cetus-hack-ee569af040f2
- BlockSec:《Cetus Incident: One Unchecked Shift Drains $223M…》— https://blocksec.com/blog/cetus-incident-one-unchecked-shift-drains-223m-largest
- Dedaub:《The Cetus AMM $200M Hack: How a Flawed "Overflow" Check Led to Catastrophic Loss》— https://dedaub.com/blog/the-cetus-amm-200m-hack-how-a-flawed-overflow-check-led-to-catastrophic-loss/
- Cyfrin:《Inside The $223M Cetus Exploit: Root Cause And Impact Analysis》— https://www.cyfrin.io/blog/inside-the-223m-cetus-exploit-root-cause-and-impact-analysis
- The Block:《Sui DEX Cetus Protocol restarts platform after recovering from $223 million exploit》— https://www.theblock.co/post/357386/sui-dex-cetus-protocol-restarts-platform-after-recovering-from-223-million-exploit
- The Block:《Sui community passes governance vote to recover stolen Cetus funds…》— https://www.theblock.co/post/356347/
- DL News:《Sui network votes to hack the hacker who drained $220m from Cetus》— https://www.dlnews.com/articles/defi/sui-validators-votes-hack-the-cetus-hacker-and-return-160m/

---

## 免责声明

本报告基于上述公开安全分析与媒体报道整理,部分链上凭证(地址、交易哈希、桥路径、投票百分比)未在本次工作中逐一于 Sui / 以太坊区块链浏览器核验,相关项已明确标注"据报道 / 待复核"。本文**不指认任何具体个人或实体**为攻击者,**不构成任何法律意见或投资建议**,**不保证任何资金的追回**。金额与时间存在统计口径差异,请以原始来源与链上数据为准。© 2026 DuoLaSafe.
