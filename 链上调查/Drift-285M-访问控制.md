# Drift Protocol 约 2.85 亿美元被盗事件复盘 —— 合约没坏,坏在权限与信任

> DuoLaSafe 链上取证 · 事件 2026-04-01 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0. 一句话结论

2026 年 4 月 1 日,Solana 头部永续 DEX **Drift Protocol** 被掏走约 **2.85 亿美元**(超过其 TVL 的一半)。根因**不是智能合约漏洞**,而是一场持续约六个月的社会工程渗透:攻击者以假交易公司身份取得 Drift 治理圈信任,诱导 Security Council 多签签名者**盲签**了内含管理员变更指令的交易,并利用 Solana 的 **durable nonce(持久 nonce)**特性把这些预签名交易"冻"成长期有效的授权,在选定时刻一次性激活,夺取完全管理员权限后用假抵押品抽干金库。这是 2026 年的主线剧本——**合约逻辑是好的,失守的是访问控制与人。**

---

## 1. 背景:Drift 与 Security Council 权限架构

- **Drift Protocol**:Solana 上规模最大的去中心化永续合约交易所之一。事发时金库内为用户托管多种资产(USDC、JLP、cbBTC、wBTC、各类流动性质押代币等)。
- **治理与管理员权限**:Drift 的关键管理员功能——新建市场 / 现货上币、配置预言机、调整风险参数、设置提款上限与熔断——由一套 **Squads 多签**控制。多名安全方报告(Chainalysis、BlockSec)指出,事发时(经 3 月下旬的一次多签迁移后)其配置为 **2/5 阈值(5 名签名者中任意 2 名即可批准)且 0 timelock(无时间锁延迟)**。
- **关键脆弱面**:2/5 阈值意味着只需攻陷/诱导 2 名签名者即可动用最高权限;**0 timelock** 意味着一旦提案通过即可立即执行,**没有给防守方留下任何发现并拦截恶意交易的时间窗口**。

> 取证语气提示:本节"2/5 + 0 timelock"为 Chainalysis 与 BlockSec 两家独立披露,口径一致;原始多签的更早期阈值未被明确公开,故不写。

---

## 2. 漏洞根因:访问控制 + 社会工程(合约没坏)

这是本案的核心,必须讲清三层:

**(1) 不是合约 bug。** 多家安全方(Elliptic、Chainalysis、BlockSec、TRM Labs)的初步结论一致:事件源于**管理员私钥/签名权限被攻陷**(privileged access compromise),攻击者获得的是**合法的管理员控制权**,而非触发了某段有缺陷的合约代码。合约按设计正常执行了一个**被授权的恶意管理员**下达的指令。

**(2) durable nonce 被当成"预授权武器"。** Solana 普通交易用一个很快过期的 blockhash 做时效保护——签了也得马上发,否则失效。**durable nonce** 用一个存在链上 nonce 账户里的固定一次性值替代该 blockhash,使一笔已签名交易**可以无限期保持有效**,直到有人推进(advance)该 nonce 才作废。攻击者正是利用这一点:把"转移管理员权限"的交易做成**休眠的、长期有效的预签名交易**,在数周前就拿到签名,然后在自己选定的时刻引爆。**签名者签的那一刻,不等于执行的那一刻**——这层时间错位让"撤回"几乎不可能。

**(3) 把自己骗进了授权签名者名单。** 攻击者通过盲签机制,诱导 Security Council 中**两名**签名者对"看似例行、实则暗含关键管理员动作"的交易签了名(TRM Labs 表述)。再叠加 3 月下旬的一次多签迁移使旧签名失效后,攻击者**重新凑齐了 2/5 法定人数**(BlockSec 披露 3 月 30 日出现绑定到更新后签名者的新 nonce 账户,表明 2/5 门槛被重新满足)。

> 一句话:**坏的不是密码学,不是合约,是"谁能签、签了什么、什么时候生效"这条信任链。**

---

## 3. 攻击流程

按公开报告还原的关键步骤(时间为 UTC):

1. **铺垫资金(3 月 11 日前后)**:攻击者从受制裁混币器 **Tornado Cash** 提出约 10 ETH 作为启动/燃料资金(BlockSec、TRM Labs)。
2. **伪造抵押品(3 月 12 日起)**:创建假代币 **CVT(CarbonVote Token)**,自控约 80% 供应;在 Solana DEX(报告提及 Raydium)注入约 500 美元真实流动性,在自有钱包间**对敲洗售(wash trading)**,把价格维持在约 1 美元,并部署受控预言机让自动化系统把这个假价当真。
3. **预签名 + nonce 武器化(约 3 月 23–30 日)**:创建多个 durable nonce 账户(部分绑定 Security Council 成员、部分为攻击者自控),诱导签名者**盲签**内含管理员转移指令的休眠交易。
4. **重凑法定人数(3 月下旬多签迁移后)**:迁移使旧签名失效,攻击者重新取得 2/5 签名,3 月 30 日出现绑定更新后成员的新 nonce 账户。
5. **夺权(4 月 1 日约 16:05 UTC 起)**:提交两笔预签名交易(BlockSec 描述为相隔约四个 slot;两家均强调几乎瞬时完成),依次完成**创建并批准恶意管理员转移提案 → 通过 `AdvanceNonceAccount`、`proposalApprove`、`vaultTransactionExecute`、`UpdateAdmin` 把管理员权限转移到攻击者地址**。至此攻击者掌握完全管理员控制权。
6. **抽干金库(约 12 分钟内,共约 31 笔提款)**:以管理员身份把假代币 **CVT 上为新抵押品市场**,切换到攻击者自控预言机把其估值抬到极高,**放松/解除提款上限与熔断**(报告提及把提款上限调到极大),存入被高估的 CVT 作"抵押",然后跨多个金库连续提走真实资产。

> 取证注:不同报告对"两笔交易"的措辞略有差异——Chainalysis 表述为相隔约一秒、BlockSec 表述为相隔约四个 slot;两者共同点是**几乎同时、不可拦截**。此处如实并列,不强行统一。

---

## 4. 规模统计

**总损失:约 2.85–2.86 亿美元**(Chainalysis 精确到 **\$285,279,417.69**;Elliptic 口径约 \$286M;部分早期报道为 \$270M+;均为 2026-04-01 UTC)。占 Drift TVL 50% 以上。

下表为各报告披露的被抽资产构成。**注意:Chainalysis 与 Elliptic 的明细口径不完全一致(尤其 JLP 数额),且并非同一时刻快照,故分列来源,不做合并求和。**

| 资产 | 金额 / 数量 | 来源 |
|---|---|---|
| JLP | 约 1.59 亿美元 | Chainalysis |
| JLP | 约 4,170 万枚(约 1.55 亿美元) | Elliptic |
| USDC | 约 7,140 万美元 | Chainalysis |
| cbBTC | 约 1,130 万美元 | Chainalysis |
| USDT | 约 560 万美元 | Chainalysis |
| USDS | 约 530 万美元 | Chainalysis |
| WETH | 约 470 万美元 | Chainalysis |
| dSOL | 约 450 万美元 | Chainalysis |
| WBTC | 约 440 万美元 | Chainalysis |
| FARTCOIN | 约 410 万美元 | Chainalysis |
| JitoSOL | 约 360 万美元 | Chainalysis |
| 其余 SOL / cbBTC / 流动性质押代币等 | 未逐项披露 | Elliptic |

- **被抽资产种类**:18 种以上代币(Chainalysis)。
- **提款笔数**:约 31 笔(Elliptic、BlockSec),约 12 分钟内完成。
- **波及面**:Chainalysis 称至少 20 个 Solana 协议因 DeFi 可组合性受到牵连或中断。

> 红线说明:个别地址 / 交易签名虽被部分安全方在报告中引用(并附 Solscan 链接),但本团队在数据截止时**未能独立从 Solscan 等浏览器复核到该具体字符串**,故**不在本报告中作为已核实事实写出具体地址/交易哈希**。后续若能在浏览器侧复核,将在更新版补录。

---

## 5. 资金追踪

公开链上分析(Phemex、TRM Labs、Elliptic、Chainalysis)勾勒出的资金路径:

- **预置阶段**:主提款钱包在攻击前约 8 天经 **NEAR Protocol intents** 注资;转出用的中间钱包在攻击前一天经 **Backpack**(需 KYC 的交易所)注资;部分以太坊侧地址此前用 **Tornado Cash** 预先注过资(Phemex)。
- **变现/出逃**:在 Solana 上把被盗资产经 DEX 聚合器(报告提及 Jupiter)**换成 USDC**;部分 **JLP 被销毁**,其余大量换成 **SOL** 并分散到多个钱包(Cryptotimes 口径);随后经 **Wormhole / deBridge 跨桥到以太坊**,在以太坊上换成 **ETH**(Elliptic、TRM Labs)。
- **混币**:路径中穿插使用 **Tornado Cash 等混币器**(Phemex)。
- **取证可用线索**:Elliptic 表示已将与本次事件相关的地址纳入其分析系统供筛查与追踪;**Backpack 因要求身份验证,其 KYC 数据可能为追查提供线索**(Phemex)。

> 取证语气提示:各家对"先换 USDC 还是先换 SOL""JLP 烧毁比例"等细节口径略有差异,本节按来源分述、不强行收敛。

---

## 6. 修复与防御建议

针对"访问控制 + 社工"这一根因,而非补合约:

1. **给最高权限上 timelock**。本案 **0 timelock** 是致命点——任何管理员级动作(改预言机、改提款上限、转管理员、上新抵押品)都应有强制延迟 + 公开告警,给防守方留出拦截窗口。
2. **提高多签阈值并解耦签名者**。2/5 太低;提高到更高门槛,且签名者应来自相互独立、地理/组织分散的实体,避免被同一波社工一锅端。
3. **禁止/严控 durable nonce 用于治理交易**。治理多签应使用短时效交易;若必须用 nonce,需对 nonce 账户的创建与推进做监控告警。
4. **杜绝盲签**。签名者必须能解码并人读交易内容(尤其涉及 `UpdateAdmin`、提款上限、预言机源切换的指令),配套硬件钱包清晰签名(clear signing)与第二人复核。
5. **抵押品与预言机准入治理**。新抵押品上币应有冷静期、多预言机交叉校验、流动性深度门槛,防止"假代币 + 自控预言机 + 洗售价"被当真抵押。
6. **保留熔断与提款上限的不可即时绕过性**。提款上限/熔断的修改本身应受 timelock 与告警约束,不能被一笔管理员交易瞬时解除。
7. **把社工纳入安全模型**。对治理贡献者、签名者建立反社工流程:身份核验、对外"合作交易公司"尽调、关键操作的带外(out-of-band)二次确认。

---

## 7. 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2025 年秋 | DPRK 关联方启动针对 Drift 治理圈的社会工程渗透(以假交易/量化公司身份接触,含数月线下接触)。 |
| 2026-03-11 前后 | 从 Tornado Cash 提出约 10 ETH 作为启动资金。 |
| 2026-03-12 | 创建假代币 CVT,自控约 80% 供应。 |
| 2026-03-23 – 30 | 创建多个 durable nonce 账户,诱导签名者盲签内含管理员转移的休眠交易。 |
| 2026-03 下旬 | 多签迁移至 2/5 阈值、0 timelock;旧签名失效后攻击者重新凑齐 2/5。 |
| 2026-03-30 | 出现绑定更新后签名者的新 nonce 账户,表明 2/5 门槛被重新满足。 |
| 2026-04-01 约 16:05 UTC | 提交两笔预签名交易(相隔约四个 slot / 近乎瞬时),完成管理员权限转移,夺取完全控制。 |
| 2026-04-01 约 16:05–18:31 UTC | 上 CVT 为抵押、切换受控预言机、放松提款限制,约 12 分钟内约 31 笔提款抽干金库。 |
| 攻击后数十分钟内 | 资金经 DEX 聚合器换币、跨 Wormhole/deBridge 桥至以太坊、换成 ETH,穿插 NEAR Intents / Backpack / Tornado Cash。 |
| 2026-04-07 | Solana 基金会在事发约五天后宣布安全整改计划。 |

---

## 来源

- Chainalysis —《Lessons from the Drift Hack: How Privileged Access Led to a $285M Loss》:https://www.chainalysis.com/blog/lessons-from-the-drift-hack/
- BlockSec —《Drift Protocol Incident: Multisig Governance Compromise via Durable Nonce Exploitation》:https://blocksec.com/blog/drift-protocol-incident-multisig-governance-compromise-via-durable-nonce-exploitation
- Elliptic —《Drift Protocol exploited for $286 million in suspected DPRK-linked attack》:https://www.elliptic.co/blog/drift-protocol-exploited-for-286-million-in-suspected-dprk-linked-attack
- TRM Labs —《North Korean Hackers Attack Drift Protocol in $285 Million Heist》:https://www.trmlabs.com/resources/blog/north-korean-hackers-attack-drift-protocol-in-285-million-heist
- The Hacker News —《$285M Drift Hack Traced to Six-Month DPRK Social Engineering Operation》:https://thehackernews.com/2026/04/285-million-drift-hack-traced-to-six.html
- CoinDesk —《How a Solana feature designed for convenience let an attacker drain $270M from Drift》:https://www.coindesk.com/tech/2026/04/02/how-a-solana-feature-designed-for-convenience-let-an-attacker-drain-usd270-million-from-drift
- Phemex News —《Drift Hack Funds Traced to Backpack Accounts》/《Drift Protocol Exploit Linked to Suspected Laundering Network》:https://phemex.com/news/article/drift-hack-funds-traced-to-backpack-accounts-kyc-data-may-hold-clues-70384
- Cryptotimes —《$285M Gone in 12 Minutes: How a Fake Token and Stolen Keys Gutted Drift Protocol》:https://www.cryptotimes.io/2026/04/03/285m-gone-in-12-minutes-how-a-fake-token-and-stolen-keys-gutted-drift-protocol/

> 链上具体地址 / 交易哈希:部分来源在其报告中引用并附 Solscan 链接,但本团队在数据截止(2026-06-27)前未能独立从区块浏览器侧复核到具体字符串,故未在本报告中以"已核实"口径写出。后续可复核后补录。

---

## 免责声明

本报告基于截至 2026-06-27 的公开链上数据与安全方公开披露整理,仅供研究与风险提示。**本报告不指认任何具体个人**;关于 DPRK / UNC4736 的归因为相关安全方以"一致 / 中等置信度"作出的评估,非司法定论。本报告**不构成法律意见,不构成投资建议,不保证任何被盗资金能够被追回**。不同来源在金额与细节上的口径差异已在文中如实标注。© 2026 DuoLaSafe.
