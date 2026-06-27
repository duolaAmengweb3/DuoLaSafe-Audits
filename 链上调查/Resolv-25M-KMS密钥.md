# Resolv Labs $25M 被盗:云端 KMS 密钥失守,凭空增发 8000 万枚 USR

> DuoLaSafe 链上取证 · 事件 2026-03-22 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0. 一句话结论

攻击者攻破了 Resolv 的云基础设施、拿到托管在 AWS KMS 中的特权签名私钥(SERVICE_ROLE,EOA 地址 `0x15CAd41e…6de398`),用约 10 万 USDC 的小额存款触发两笔 `completeSwap`,在 2026-03-22 凭空铸出 **8000 万枚无抵押 USR**,套现约 **11,000+ ETH(约 2,500 万美元)**。根因是**链下单点密钥 + 合约无铸币上限校验**,不是智能合约逻辑被绕过——合约严格按签名执行,被攻破的是密钥本身。

---

## 1. 背景:Resolv、USR 与 KMS 在铸币里的角色

- **Resolv Labs** 是一个 delta 中性的稳定币协议,发行 **USR**(锚定 1 美元)及其质押封装版 **wstUSR**。USR 的支撑来自协议持有的真实资产(ETH 抵押 + 对冲头寸)。
- **铸币流程是两步、链下授权式的**:用户先链上发起 `requestSwap`(存入 USDC 等抵押),协议的**链下服务**根据应铸数量用一个**特权私钥签名**,再由持有 `SERVICE_ROLE` 的地址链上调用 `completeSwap` 完成铸币。
- 这个特权私钥托管在 **AWS KMS(云端密钥管理服务)** 中。换句话说,"该铸多少 USR" 的最终裁决权,落在一个**云端单点密钥**上。该 `SERVICE_ROLE` 自 2024-12-26 起被授予地址 `0x15CAd41e…6de398`(链上验证为 EOA,无合约代码),**不是多签**。

---

## 2. 漏洞根因:云密钥管理 = 单点

核心根因有两层,缺一不可:

1. **链下单点签名密钥(首要根因)**:铸币授权依赖一个托管在 AWS KMS 中的特权私钥,由单个 EOA(而非多签/阈值签名)持有。攻击者攻破 Resolv 的云基础设施、拿到这把密钥后,就能"合法地"为任意金额签名授权铸币。这是一个**云基础设施 / 密钥管理失守**问题,不是合约漏洞。
2. **合约无铸币上限 / 抵押比例校验(放大器)**:`completeSwap` 只校验签名有效性,**不在链上校验"铸出的 USR 与实际存入抵押的比例"**,也没有任何单笔/单地址铸币上限。于是一个有效签名就能用约 10 万 USDC 铸出 5000 万 USR。

> 取证判断:合约"按代码正确执行"了——它信任了链下签名。真正失守的是**那把云端私钥**。即便合约逻辑完美,只要密钥是单点云托管且无链上风控兜底,结果不变。

公开报道未披露 AWS KMS 被攻破的**具体技术路径**(凭据泄露 / IAM 配置 / 内部环境沦陷等)。**本报告不臆造该细节**,仅确认根因定性为"云基础设施沦陷导致特权密钥被控"。

---

## 3. 攻击流程(链上已核)

1. **铺垫**:攻击者用 `SERVICE_ROLE` EOA `0x15CAd41e…6de398` 作为发起方,目标合约 `0xa27a69Ae…E55861`(Resolv 铸币/swap 合约)。
2. **第一笔铸币**:`completeSwap`,函数选择器 `0xfc44d58c`,swap ID = 30,铸出 **50,000,000 USR**(calldata 末位解码为 `50000000 * 1e18`),对应约 10 万 USDC 存款。
   - tx:`0xfe37f25e…dc33743`,区块 24710031,时间 **2026-03-22 02:21:35 UTC**(链上确认 status=1 成功)。
3. **第二笔铸币**:同一发起方、同一合约,再铸出 **30,000,000 USR**。
   - tx:`0x41b6b937…2db1f18f`,区块 24710428,时间 **2026-03-22 03:41:47 UTC**。
4. **共计铸出 8000 万枚无抵押 USR**,涌入 DEX/借贷池套现。
5. **变现**:USR → wstUSR / 稳定币 → ETH,通过 DEX 兑换分散到多个收款地址。

---

## 4. 规模统计

| 项目 | 数值 | 来源 / 核实方式 |
|---|---|---|
| 攻击日期 | 2026-03-22 | 链上区块时间戳 |
| 首笔铸币 | 50,000,000 USR | cast 解码 calldata(swap ID=30) |
| 首笔时间 | 02:21:35 UTC | cast 区块时间戳 |
| 次笔铸币 | 30,000,000 USR | CertiK + cast 确认 tx 存在 |
| 次笔时间 | 03:41:47 UTC | cast 区块时间戳 |
| 总增发 | **80,000,000 USR(无抵押)** | 两笔合计 |
| 攻击者真实投入 | 约 10–20 万 USDC | 安全方报道(未逐笔链上复核) |
| 套现规模 | 约 11,000+ ETH(约 2,300–2,500 万美元) | 链上余额核实 |
| USR 脱锚最低 | 报道范围 $0.20 至 $0.0025(不同 DEX/口径) | 安全方报道 |
| 外溢损失 | Fluid/Instadapp 约 1000 万+ 坏账;约 15 个 Morpho 金库受影响 | Halborn 报道(未链上复核) |

> 金额口径说明:不同安全机构对"被盗价值"给出 $23M / $24.5M / $25M 等略有差异(取决于 ETH 计价时点与是否计入 wstUSR);"$80M" 指增发面值,"约 $25M" 指实际套现价值。本报告以链上可核数据为准,其余标注来源。

---

## 5. 资金追踪(链上已核)

- **SERVICE_ROLE / 发起方 EOA**:`0x15CAd41e6BdCaDc7121ce65080489C92CF6de398`(被盗的特权签名密钥,链上确认为无代码 EOA)。
- **铸币目标合约**:`0xa27a69Ae180e202fDe5D38189a3F24Fe24E55861`。
- **主套现地址**:`0x8ED8cF0C1c531C1b20848E78f1CB32fa5B99b81C`
  - **截至本次取证,链上余额约 11,056.85 ETH**(`cast balance` 实测,约 2,480 万美元量级)。
- **其余关联收款地址**(安全方报道,部分持有 wstUSR / ETH,未逐一链上复核全部余额):
  - `0x04A288a7789DD6Ade935361a4fB1Ec5db513caEd`(主要 wstUSR 接收方)
  - `0x9FeeEAEc113E6d2DCD5ac997d5358eee41836e5f`
  - `0x6Db6006c38468CDc0fD7d1c251018b1B696232Ed`
  - `0xb945eC1be1f42777F3AA7D683562800B4CDD3890`
- **相关 tx**:
  - 首笔 `requestSwap`(报道):`0x590b5c66…ade732c89`
  - 首笔 `completeSwap`(链上已核):`0xfe37f25e…dc33743`
  - 次笔 `requestSwap`(报道):`0xe5bae64e…aa17ae4b`
  - 次笔 `completeSwap`(链上已核):`0x41b6b937…2db1f18f`

> 公开报道**未提及** Tornado Cash 或具体跨链桥/交易所充值路径。本报告**不臆造**混币与出金路径,仅记录"USR→wstUSR→ETH 经 DEX 兑换并分散到多地址"这一已确认事实。

---

## 6. 修复与防御建议

针对"云密钥管理单点"这一根因:

1. **去单点化签名权**:特权铸币密钥改为**多签 / MPC / 阈值签名**,任何单一密钥(含 KMS 中的)被攻破都不足以授权铸币。
2. **链上风控兜底,不信任链下数字**:在 `completeSwap` 等铸币入口强制**链上校验抵押/铸出比例**,设置**单笔与滚动时间窗的铸币上限(rate limit)**,异常超额直接 revert。链上才是最后防线。
3. **KMS 最小权限与隔离**:严格 IAM 最小权限、密钥使用与签发环境网络隔离、关闭非必要导出/调用权限,KMS 调用全量审计日志 + 异常告警。
4. **铸币熔断 / 守护者**:独立 guardian 监控供应量突增,可在 N 分钟内暂停铸币与 DEX 兑换,争取响应窗口。
5. **实时供应量监控**:对 USR 总供应、单地址持仓、与抵押储备的偏离做秒级监控告警(本案两笔铸币间隔约 80 分钟,留有干预窗口)。

---

## 7. 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2024-12-26 | `SERVICE_ROLE` 授予 EOA `0x15CAd41e…6de398`(单点签名密钥,后被攻破) |
| 2026-03-22 约 01:50 | 攻击者发起首笔 `requestSwap`(约 10 万 USDC,swap ID=30)— 报道时间 |
| 2026-03-22 **02:21:35** | 首笔 `completeSwap` 铸出 **5000 万 USR**(链上已核) |
| 2026-03-22 02:21 后数分钟 | USR 跌破 $0.80,开始脱锚 |
| 2026-03-22 **03:41:47** | 次笔 `completeSwap` 铸出 **3000 万 USR**(链上已核) |
| 2026-03-22 当日 | 8000 万 USR 涌入 DEX,USR 深度脱锚;变现为 ETH 分散到多地址 |
| 2026-03-22 之后 | Resolv 暂停相关操作;外溢至 Fluid、Morpho 等借贷市场 |
| 2026-06-27 | 主套现地址仍持约 11,056 ETH(本次取证链上实测) |

---

## 来源

- Chainalysis — Lessons from the Resolv Hack: https://www.chainalysis.com/blog/lessons-from-the-resolv-hack/
- Halborn — Explained: The Resolv Hack (March 2026): https://www.halborn.com/blog/post/explained-the-resolv-hack-march-2026
- CertiK — Resolv Protocol Incident Analysis: https://www.certik.com/blog/resolv-protocol-incident-analysis
- Blockaid — How a Compromised Key Minted $80M in Resolv's USR: https://www.blockaid.io/blog/how-a-compromised-key-minted-80m-in-resolvs-usr-stablecoin-and-triggered-a-depeg
- CoinDesk — Resolv stablecoin crashes after $80M exploit: https://www.coindesk.com/markets/2026/03/23/resolv-stablecoin-drops-70-after-usd80-million-exploit-after-attacker-mints-usr
- NomosLabs — Resolv Labs $24.5M USR Unauthorized Minting via AWS KMS Compromise: https://nomoslabs.io/archive/resolv-labs-2026
- 链上数据:Ethereum 主网,经 `cast`(tx / receipt / block / balance / calldata 解码)独立复核,RPC ethereum-rpc.publicnode.com

## 免责声明

本报告基于公开报道与公开链上数据整理,仅供安全研究与风险参考。报告**不指认任何特定自然人或法律主体**为攻击者;地址、交易与时间均为链上公开信息。本报告**不构成法律意见**,**不保证任何资金可被追回**。部分金额因计价时点与口径不同存在差异,已尽量标注来源与核实方式;未能链上独立核实者已明确注明"报道"。© 2026 DuoLaSafe.
