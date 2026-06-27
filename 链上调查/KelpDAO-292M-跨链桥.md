# KelpDAO rsETH 跨链桥 2.92 亿美元被盗事件 · 链上取证复盘

> DuoLaSafe 链上取证 · 事件 2026-04-19 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0. 一句话结论

攻击者并未攻破智能合约,而是攻陷了 LayerZero 跨链桥的**链下验证层**:KelpDAO 的 rsETH OFT 采用 1-of-1 单 DVN(仅 LayerZero Labs 自营验证者)配置,攻击者污染该 DVN 所依赖的 RPC 节点并对外部节点发起 DDoS 迫使其切换到被控节点,使唯一验证者对一条**源链上从未发生的销毁/锁仓消息**完成签名背书,以太坊侧 OFT 合约据此"如设计般"释放了 116,500 枚无背书 rsETH(约 2.92 亿美元),随后被用作 Aave 等借贷市场抵押品套出真实资产并跨链外逃;LayerZero 与 Chainalysis 归因朝鲜 Lazarus Group(TraderTraitor 子单元)。

---

## 1. 背景:LayerZero 跨链消息机制与 DVN

LayerZero V2 的跨链消息安全由 **DVN(Decentralized Verifier Network,去中心化验证者网络)** 承担。其工作模型(本案相关部分):

- 源链上,OApp/OFT 通过 EndpointV2 发出一个跨链 packet(含 nonce、GUID、收款人、金额等),并触发 `PacketSent` 事件。
- 一组 DVN 各自通过 **RPC 节点查询源链状态**,确认该 packet 对应的源链事件真实发生,然后对消息提交链下背书(attestation)。
- 目的链 EndpointV2 收到足额 DVN 背书后,将消息交付给目标 OApp/OFT,后者据此 mint/释放资产。

安全性取决于 DVN 的"数量阈值"配置:OApp 可要求 **X-of-Y** 多个独立 DVN 同时背书。LayerZero 文档推荐多 DVN 冗余;而 **KelpDAO rsETH 部署使用了默认的 1-of-1 配置**——必需 DVN 数 = 1、可选 DVN 数 = 0,唯一验证者为 LayerZero Labs 自营 DVN。这意味着:**只要污染这一个验证者所信任的数据源,即可单点伪造任意跨链消息。**

链上锚点(已用 cast 核实,以太坊主网):

- LayerZero EndpointV2:`0x1a44076050125825900e736c501f859c50fE728c`(有合约代码,即攻击交易的 `to`)。
- rsETH 代币合约:`0xa1290d69c65a6fe4df752f95823fae25cb99e5a7`,`symbol()` / `name()` 均返回 `rsETH`(已核实)。
- rsETH OFT/适配器合约:`0x85d456b2dff1fd8245387c0bfb64dfb700e98ef3`,其 `token()` 返回 `0xA1290d…99e5A7`(即上述 rsETH),确认为 rsETH 的跨链端点(已核实)。
- 单一 DVN 合约:`0x589dedbd617e0cbcb916a9223f4d1300c294236b`(有合约代码,已核实;身份为"LayerZero Labs DVN"系据公开报道)。

> 注:DVN 名义身份("LayerZero Labs 自营")与"1 必需 / 0 可选"的具体配置数字来自 LayerZero 与第三方(Rekt、OpenZeppelin、Halborn)公开复盘,DuoLaSafe 已核实合约存在性,未独立复核其 DVN 配置存储槽。

---

## 2. 漏洞根因:验证非对称 + 源链销毁未被独立校验

核心根因有两层,二者叠加才构成本案:

**(a) 单点信任(1-of-1 DVN)。** 仅一个验证者决定一条价值数亿美元消息的真伪,无任何独立第二方需要附议。这把"分布式验证"退化为"中心化验证",且该验证者并不在 KelpDAO 控制之下。

**(b) 验证非对称——源链事件未被密码学约束。** DVN 的背书证明的是"我看到了源链发生了 X",而非"源链密码学地证明发生了 X"。DVN 对源链真伪的判断**完全依赖它查询的 RPC 节点返回的链状态**。当这些 RPC 被替换为恶意软件、且只对 DVN 的 IP 返回伪造结果时,DVN 会"诚实地"对一条**源链上根本不存在的销毁/锁仓**完成背书。以太坊侧 OFT 合约逻辑本身无错,它只是忠实执行了"收到足额背书 → 释放资产"。

公开复盘给出的**伪造证据(取证语气,DuoLaSafe 未独立访问源链 Unichain 复核,故标注为转引)**:

- 源链 Unichain 的出站 nonce 从未推进到伪造 packet 所声称的位置(报道称源链对应序号根本不存在);
- 攻击发生时 Unichain 上 rsETH 供应量仅约 49.26 枚,**物理上不可能销毁 116,500 枚**;
- Unichain 上无对应的 `Transfer` / `Burn` / `PacketSent` 事件。

这三点是判定"无背书凭空铸造"的关键。DuoLaSafe 在以太坊侧已独立核实了"凭空到账 116,500 枚 rsETH"这一结果(见 §3),源链"零销毁"一侧依赖公开报道。

**审计为何未发现:** 标准智能合约审计审查的是合约字节码逻辑,通常**显式排除**集成配置(DVN 阈值)、链下基础设施依赖与 RPC 信任假设——而本案失效正发生在这一审计盲区。这也是为什么"Zero Bugs Found"——代码无 bug,配置与信任模型有致命缺陷。

---

## 3. 攻击流程(已核实结果 + 转引手法)

**手法(转引 Chainalysis / OpenZeppelin / Halborn / Rekt):**

1. 攻击者获取了 DVN 正在查询的 RPC 节点清单,拿到其中**两个 LayerZero 自营内部 RPC 节点**的访问权,替换其运行的软件,使其只对 DVN 的来源 IP 返回伪造的源链状态,对其他调用者仍返回真实数据(隐蔽性)。
2. 同时对 DVN 所依赖的**外部 RPC 节点发起 DDoS**,迫使其故障切换(failover)到被攻击者控制的内部节点。
3. DVN 被隔离在攻击者掌控的数据环境中,对一条伪造的跨链消息(声称源链已销毁/锁仓 116,500 rsETH)完成背书,目的链据此释放资产。

**结果(DuoLaSafe 已用 cast 链上核实,以太坊主网):**

- 攻击交易:`0x1ae232da212c45f35c1525f851e4c41d529bf18af862d9ce9fd40bf709db4222`
  - 状态 `1`(成功),区块 `24908285`,gasUsed `94456`。
  - 区块时间戳 `1776533735` = **2026-04-18 17:35:35 UTC**(已核实)。
  - 交易 `from`:`0x4966260619701a80637cDbdAc6A6cE0131f8575E`(攻击执行地址);`to`:LayerZero EndpointV2(上文)。
  - 交易回执日志中包含一笔 rsETH(`0xa1290d…99e5A7`)`Transfer`,金额 `0x…18ab7a47948bcfd00000` = **116,500.0**(cast 解码已核实),收款人 `0x8B1b6c9A6DB1304000412dd21Ae6A70a82d60D3b`。
  - OFT 交付事件中的 packet **GUID** = `0x3f4510d855cf3a805fec59daafae640d290749b7bf1e5450f91b5fb0018b3b4e`,事件内 nonce 字段 `0x7670` = **30320**(cast 解码已核实)。
  > 说明:部分公开报道将该跨链序号简记为"nonce 308",与链上 OFT 事件字段值 30320 不一致;DuoLaSafe 以链上实测值为准,差异可能源于不同计数口径,不影响"凭空铸造 116,500 枚"这一结论。

- 第二笔约 9.5 万 ETH 等值(报道称约 40,000 rsETH / 约 9,500 万美元)的盗取尝试被 KelpDAO **暂停合约成功拦截**(此数额来自公开报道,未单独核交易)。

---

## 4. 规模统计

| 项目 | 数值 | 来源/核实 |
|---|---|---|
| 直接被盗 | 116,500 rsETH ≈ 2.92 亿美元 | 链上核实(Transfer 金额 = 116,500);USD 估值据公开报道 |
| 被拦截的二次盗取 | ≈ 40,000 rsETH ≈ 9,500 万美元 | 公开报道(Chainalysis/Rekt) |
| 攻击时间 | 2026-04-18 17:35:35 UTC | 链上核实(区块 24908285 时间戳) |
| 被盗占 rsETH 流通量 | 约 18% | 公开报道(Halborn) |
| 用于 Aave 抵押的 rsETH | ≈ 89,567 枚 | 公开报道(Rekt/Aave 治理) |
| 由抵押套出的借款 | ≈ 82,650 WETH +约 821 wstETH(报道亦称约 1.9 亿美元) | 公开报道(Rekt/KuCoin) |
| Aave 形成的坏账 | ≈ 1.77 亿美元(部分情景测算更高) | 公开报道(KuCoin / Aave 治理 / The Defiant) |
| Arbitrum 安全委员会冻结 | 30,766 ETH | 公开报道(Chainalysis/Rekt) |
| 事件后 48h DeFi TVL 流出 | 约 132 亿美元(其中 Aave 约 84.5 亿) | 公开报道(Rekt) |

> 除"116,500 / 攻击时间"两项为 DuoLaSafe 链上独立核实外,本表其余数字均转引公开报道,未逐项上链复核。

---

## 5. 资金追踪

**已核实的链上地址(以太坊主网,cast 核实 nonce/balance 均非零、确为活跃 EOA):**

- 攻击执行地址 `0x4966260619701a80637cDbdAc6A6cE0131f8575E`(攻击交易 `from`,nonce 6)。
- 收款/主控地址 `0x8B1b6c9A6DB1304000412dd21Ae6A70a82d60D3b`(攻击交易收款人,nonce 7,仍有少量余额)。
- 关联地址 `0x5d3919F12bCc35c26Eee5F8226A9bee90c257Ccc`(nonce 3;在 Arbitrum 上为下方冻结相关交易的发起方)。
- 关联地址 `0xCBb24A6B4DAfaAA1a759A2F413eA0eB6AE1455CC`(nonce 13)。
- Aave 分支地址 `0x1F4C1c2e610f089D6914c4448E6F21Cb0db3adeF`(nonce 11;报道称供应 53,000 rsETH、借出约 52,440 WETH)。

**启动资金(Tornado Cash):**

- 资助交易 `0xcb2ee450d6e770216dc3061750b4ac5b5fa494666bcf7eaa936411733e2ef7ee`,区块 `24906342`,`to` 为 `0xd90e2f925DA726b50C4Ed8D0Fb90Ad053324F31b`(Tornado 类路由,value=0,符合提款调用形态)——已核实交易存在。报道称攻击者在抽干前约 10 小时由 Tornado Cash 取得小额种子 gas。
  > DuoLaSafe 仅核实该交易存在与 `to`/value;"约 10 小时前 / 具体金额"为公开报道。

**外逃路径(转引 PeckShield / Cyvers / Rekt):**

- 把无背书 rsETH 在 **Aave V3** 等借贷市场抵押,套出 WETH/wstETH 等真实资产(借贷协议承担坏账);另有 Compound V3、Euler 等敞口。
- Arbitrum 安全委员会(报道称 9/12 票通过)冻结 30,766 ETH 后,残余资金主要经 **THORChain(ETH→BTC)** 出逃,辅以 Umbra、Chainflip、BitTorrent 链;报道估算约 75,701 ETH(约 1.75 亿美元)被换为比特币。

**Arbitrum 侧冻结交易(已核实存在):** `0x5618044241dade84af6c41b7d84496dc9823700f98b79751e257608dac570f6b` 在 Arbitrum One(区块 454686044)存在,`from` = `0x5d3919…257Ccc`。该交易在以太坊主网不存在(故只能在 Arbitrum 复核),与"Arbitrum 安全委员会链级冻结"叙事一致;DuoLaSafe 未进一步解码其内部冻结语义。

**善后:** Aave 牵头"DeFi United"倡议,Lido、EtherFi、Ethena、Stani Kulechov 等承诺投入 ETH 填补 rsETH 缺口(Stani 5,000 ETH、EtherFi 5,000 ETH、Lido 2,500 stETH 等);KelpDAO 后续宣布完成 rsETH 恢复的运营部分(均据公开报道)。

---

## 6. 修复与防御建议

**针对 OApp/OFT 部署方(KelpDAO 类):**

1. **禁用 1-of-1,强制多 DVN 阈值。** 对高价值资产采用 X-of-Y 多 DVN(至少含一个独立于 LayerZero Labs 的第三方 DVN),使单点污染不足以放行消息。
2. **DVN 必须使用多源、跨提供商、含归档/共识级别的 RPC,并对返回做交叉校验。** 任一 RPC 在故障切换中被孤立时应触发告警而非静默 failover;对源链事件应核对区块哈希/收据 Merkle 证明而非仅"读到了状态"。
3. **链上金额/供应不变量做硬约束。** 在目的链交付侧引入"单笔/单窗口铸造上限"、"与源链已锁仓总量对账"等熔断;本案 116,500 枚远超源链约 49 枚供应,本应被不变量拦截。
4. **保留并演练快速暂停(circuit breaker)。** KelpDAO 暂停合约成功拦下二次约 9,500 万美元盗取,证明可暂停设计有效——应缩短从异常检测到暂停的响应时间。

**针对借贷/集成协议(Aave 类):**

5. 对 LST/LRT 等跨链可铸造抵押品设置**供给上限与预言机健康检查**,识别"短时间巨量新增抵押"异常,避免成为洗钱与变现出口。

**针对审计方:**

6. 安全评估范围必须**显式覆盖 DVN/桥配置、RPC 信任模型与链下故障切换路径**,而非止步于合约字节码;交付物应单列"集成与基础设施配置风险"。

---

## 7. 时间线(UTC)

- **2026-04-18 约 15–17 时:** 攻击者经 Tornado Cash 取得种子 gas(资助交易 `0xcb2ee4…`,区块 24906342;"约 10 小时前"据报道)。
- **2026-04-18 17:35:35:** 攻击交易 `0x1ae232…` 上链(区块 24908285),凭空铸造/释放 116,500 rsETH 至 `0x8B1b…0D3b`(链上核实)。
- **2026-04-18 起:** 无背书 rsETH 被抵押至 Aave 等,套出 WETH/wstETH;KelpDAO 暂停合约,拦下二次约 9,500 万美元盗取(报道)。
- **2026-04-19:** 多家安全方(Chainalysis/PeckShield/Cyvers/SlowMist 等)与 KelpDAO/LayerZero 发布事件说明;初步归因 Lazarus/TraderTraitor。
- **2026-04-20:** Arbitrum 安全委员会紧急行动,冻结 30,766 ETH;Aave 发布 rsETH 事件报告。
- **2026-04-21 至 04-23:** Aave 各市场 rsETH 储备冻结/再暂停反复调整。
- **2026-04-24:** 公布恢复与坏账核算;"DeFi United"倡议成型。
- **2026-05-上旬:** LayerZero 公开承认"在允许自营验证者以高风险配置守护高价值资产上犯了错误",收紧桥安全。

---

## 来源

- Chainalysis — Inside the KelpDAO Bridge Exploit (April 2026): https://www.chainalysis.com/blog/kelpdao-bridge-exploit-april-2026/
- OpenZeppelin — $292 Million Lost, Zero Bugs Found: Lessons From the rsETH Bridge Exploit: https://www.openzeppelin.com/news/lessons-from-kelpdao-hack
- Rekt News — KelpDAO: https://rekt.news/kelpdao-rekt
- Halborn — Explained: The Kelp DAO Hack (April 2026): https://www.halborn.com/blog/post/explained-the-kelp-dao-hack-april-2026
- Decrypt — LayerZero Pins $292M KelpDAO Bridge Hack on North Korea's Lazarus Group: https://decrypt.co/364872/layerzero-pins-292m-kelpdao-bridge-hack-on-north-koreas-lazarus-group
- CoinDesk — LayerZero says it 'made a mistake' in $292 Million Kelp exploit: https://www.coindesk.com/tech/2026/05/09/layerzero-says-it-made-a-mistake-in-usd292-million-kelp-exploit
- KuCoin — KelpDAO rsETH Exploit: $177M Bad Debt on Aave: https://www.kucoin.com/blog/kelpdao-rseth-exploit-how-292m-layerzero-bridge-attack-created-177m-bad-debt-in-aave
- Aave Governance — rsETH Incident Report (April 20, 2026): https://governance.aave.com/t/rseth-incident-report-april-20-2026/24580
- TRM Labs — North Korea Stole 76% of All Crypto Hack Value in 2026: https://www.trmlabs.com/resources/blog/north-korea-stole-76-of-all-crypto-hack-value-in-2026-with-just-two-attacks
- 链上数据自核:Ethereum 主网 / Arbitrum One / Unichain(经 cast 1.5.1 查询,RPC: ethereum-rpc.publicnode.com 等),截至 2026-06-27。

## 免责声明

本报告基于公开报道与链上可复核数据撰写,凡未经 DuoLaSafe 独立上链核实之处均已明确标注为"转引/据报道"。本报告**不指认任何具体自然人身份**(归因 Lazarus/TraderTraitor 系转述 LayerZero 与 Chainalysis 等机构判断),**不构成法律意见或投资建议**,**不保证任何资产可被追回**。地址与交易哈希仅用于技术取证说明,可能随调查推进而更新。© 2026 DuoLaSafe。
