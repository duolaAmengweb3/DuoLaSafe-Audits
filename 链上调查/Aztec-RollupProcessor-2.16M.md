# Aztec 私有 Rollup 桥(RollupProcessor)escapeHatch 缺陷被盗 ~$2.16M 链上取证复盘

> DuoLaSafe 链上取证 · 事件 2026-06 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

> 标题更正说明:种子线索称"Aztec 相关跨链桥",经核实确为 **Aztec** 项目,但被攻击的是其 **已废弃的 Private Rollup Bridge / RollupProcessor 合约**(2021 上线、2022 下线),而非当前在用的 Aztec L2。同周另有一起针对 **Aztec Connect** 的 ~$2.19M 攻击(6 月 14 日),为独立事件,本报告聚焦 6 月 17 日的 RollupProcessor 事件。

---

## 0 一句话结论

2026-06-17 18:34:47 UTC,攻击者向 Aztec 已废弃且不可升级的 RollupProcessor 合约(`0x7379…A2ba`)调用紧急逃生函数 `escapeHatch(bytes,bytes,bytes)`,提交了一份将 `outputOwner` 指向自己、且绕过所有权与签名校验的伪造证明,单笔交易把桥内约 1,158 ETH + 150,000 DAI + ~0.47 renBTC(合计 ~$2.16M)提走。根因是逃生函数缺乏访问控制与证明—资金归属绑定校验;因合约不可升级、团队 2022 年已弃管,资金无法冻结或回滚。

---

## 1 背景

- **项目**:Aztec —— 以太坊上的隐私/ZK-Rollup 项目。
- **受害合约**:Private Rollup Bridge 的 `RollupProcessor`,链上地址 `0x737901bea3eeb88459df9ef1be8ff3ae1b42a2ba`。该产品 2021 年上线、2022 年下线("sunset in 2022"),但合约 **immutable(不可升级)** 且团队已放弃管理权,残留资产仍锁在链上。
- **关联组件**:`TurboVerifier` 验证器合约 `0x48cb7ba00d087541dc8e2b3738f80fdd1fee8ce8`(escapeHatch 证明的链上验证入口)。
- **背景脆弱性**:旧式 Rollup 合约通常保留一个"逃生舱(escape hatch)"——当 rollup provider 离线时,用户可凭证明直接从 L1 取回自己的资金。这类紧急通道天然弱化了正常流程的权限约束,一旦校验不严即成单点。
- **时点背景**:本次为该周第二起 Aztec 废弃合约被盗(6/14 Aztec Connect ~$2.19M 在前),两起均被安全团队指向相近的"公共输入绑定 / 状态边界"类缺陷。

> 链上已核:受害合约与 TurboVerifier 当前均存在字节码(`cast code` 非空);受害 RollupProcessor 当前 ETH 余额 = 0、DAI 余额 = 0,与"被清空"一致。

---

## 2 漏洞根因(核心)

调用入口为 `escapeHatch(bytes,bytes,bytes)`,函数选择器 **`0xd1c65264`**(已用 `cast 4byte` 反查确认)。根据 SlowMist / BlockSec 公开分析,结合本次交易 calldata,根因为:

1. **逃生函数缺乏访问控制**:`escapeHatch` 没有 `onlyOwner`、没有 rollup-provider 校验、没有对提交者的签名验证——任意外部地址都能调用并构造提款。
2. **证明未绑定资金归属**:证明系统没有把"最终输出 note(资金应归属谁)"正确绑定到真正的受益人。攻击者可在证明的公共输出里把 `outputOwner` 直接填成自己的地址。本次 calldata 中即可见攻击者地址 `…6952d9246e9afe8b887b2877225163436f78e97f` 被编码进证明输入。
3. **验证器对 `rollupSize=0` 放行**:据 SlowMist,`TurboVerifier` 在 `rollupSize` 被置 0 时仍接受逃生证明(被当作"一笔逃生交易"处理),配合上面两点,使一份"内容自定义、归属自定义"的证明被合约当作合法提款执行。
4. **L1 层无二次归属校验**:验证器确认后,RollupProcessor 在 L1 直接按证明里的 `outputOwner / publicOutput` 放款,未在出金前独立校验资金所有权——证明一过即放钱。

一句话:**把"紧急取回自己的钱"的通道,变成了"凭一份自填证明取走别人的钱"**,且整条路径上没有任何一处独立验证"这笔钱本该归谁"。因合约不可升级,该缺陷在下线 4 年后仍可被触发。

> 已链上核实:选择器 `0xd1c65264` = `escapeHatch(bytes,bytes,bytes)`;交易 `to` 即受害合约;`value=0`(不附带 ETH,纯靠证明出金);`nonce=0`(攻击地址首次发交易即为本攻击,符合"一次性钱包")。
> 未链上核实(报告引用):`rollupSize=0` 放行、证明—归属绑定缺失的内部逻辑细节,源自 SlowMist/BlockSec 分析,非本团队逐字节复核。

---

## 3 攻击流程(含 HitBTC 起步资金 = 可能的身份线索)

1. **起步资金(身份线索)**:据多家报道(TronWeekly、Coinlaw、Namecoin News 等),攻击地址在作案前由 **HitBTC 提现钱包**注入约 **0.134 ETH** 作为 gas 起步资金。这是少有的中心化交易所触点——HitBTC 留有 KYC/提现记录,是后续身份溯源的关键锚点。
   - 取证说明:该 0.134 ETH 的具体注资交易需归档节点(archive)回溯;本次所用公共 RPC 拒绝归档查询(返回 "Archive requests require a personal token"),**故 HitBTC→攻击者的注资交易哈希未由本团队链上逐笔复核**,此条按安全方报道采信。攻击地址 `nonce=0` 即发起攻击,与"刚被注资的全新钱包"一致,旁证此说。
2. **构造证明**:攻击者准备一份伪造的逃生证明,`outputOwner` 指向自身、`publicOutput` 设为目标金额,利用 `rollupSize=0` 等参数让 `TurboVerifier` 放行。
3. **单笔提款**:`2026-06-17 18:34:47 UTC`(区块 25339094),攻击地址 `0x6952…E97F` 调用 `escapeHatch`(tx `0xab30…c2b5`),交易 **status=1 成功**,gasUsed 453,576,把桥内约 1,158 ETH + 150,000 DAI + ~0.47 renBTC 一次性提出。
4. **无法阻止**:合约不可升级、团队已弃管,无暂停/回滚手段。
5. **转移痕迹**:截至 2026-06-27,攻击地址仅余 0.000028 ETH 与 0.00015 DAI,renBTC、WETH 余额为 0——**赃款已基本转出该地址**(该钱包仅作一次性作案与中转,nonce 已增至 11)。

> 已链上核实:交易时间、区块、from/to、status、gasUsed、攻击者当前残余余额、受害合约被清空。

---

## 4 规模统计

| 项目 | 数值 | 核实方式 |
|---|---|---|
| 被盗 ETH | ~1,158 ETH | 安全方报道(SlowMist/PeckShield);本次单 tx 无 ERC20 Transfer 日志,ETH 走内部转账,未经归档逐笔复核 |
| 被盗 DAI | 150,000 DAI | 同上 |
| 被盗 renBTC | ~0.47–0.5 renBTC | 同上(各源 0.4696 / 0.47 / 0.5 略有出入) |
| 总价值 | ~$2.15–2.16M | 安全方报道(部分源按价折 ~$2.21M) |
| 攻击地址当前余额 | 0.000028 ETH / 0.00015 DAI / 0 renBTC / 0 WETH | **本团队链上核实** |
| 受害合约当前余额 | 0 ETH / 0 DAI | **本团队链上核实**(已被清空) |
| 攻击地址 nonce | 11(作案为 nonce 0) | **本团队链上核实** |

金额口径差异说明:不同报道在 ETH 计价时点与 renBTC 精度上略有出入($2.15M / $2.16M / $2.21M),本报告以 ~$2.16M 为中值,赃物结构(1,158 ETH + 150k DAI + ~0.47 renBTC)各源一致。

---

## 5 资金追踪

- **入口锚点**:HitBTC 提现钱包 → 攻击地址 ~0.134 ETH 起步资金(报道采信,待归档复核)。这是本案最有价值的溯源线索——HitBTC 应留有该提现账户的 KYC 与 IP/设备记录。
- **作案地址**:`0x6952d9246e9aFE8B887B2877225163436F78E97F`(EOA,nonce 0 即作案,典型一次性钱包)。
- **出金合约**:`0x737901bea3eeb88459df9ef1be8ff3ae1b42a2ba`(RollupProcessor,现已清空)。
- **赃款流向**:截至 2026-06-27,作案地址已几乎清空,资产已转出;具体下游(混币 / 跨链 / CEX)需归档节点与图谱工具进一步追踪,本报告所用公共 RPC 不支持归档回溯,**未在本报告中给出下游路径**。
- **建议监控**:对 `0x6952…E97F` 的所有出向地址、以及 1,158 ETH / 150k DAI / renBTC 量级的并合转账设地址标签与告警;就 HitBTC 注资交易向交易所发起情报请求。

---

## 6 修复与防御建议

- **下线即清退**:产品 sunset 时不应仅"停用前端",应同步将合约内残留资产迁出 / 触发受控清退。本案核心教训——**不可升级 + 弃管 + 残留资金 = 永久暴露的攻击面**。
- **逃生通道必须强校验**:emergency/escape 类函数也要有访问控制(provider 校验、用户签名),且证明必须 **绑定资金归属**(outputOwner 不可由提交者任意指定)。
- **验证器边界**:禁止 `rollupSize=0` 等退化输入绕过常规约束;对公共输入(public input)与 L2 状态做强绑定,堵住 L1/L2 状态边界绕过。
- **出金前二次校验**:L1 放款前独立校验资金所有权,不可"证明过即放钱"。
- **可升级 / 可暂停设计**:对仍持有用户资产的桥合约保留受控的暂停或迁移能力,而非交付后完全弃管。
- **CEX 协同溯源**:对类似起步资金来自 CEX(此处 HitBTC)的事件,第一时间向交易所发起 KYC 情报请求与地址冻结协查。

---

## 7 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2021 | Aztec Private Rollup Bridge / RollupProcessor 上线 |
| 2022 | 该产品下线(sunset),合约不可升级、团队弃管,资产残留链上 |
| 2026-06-14 | 同项目 Aztec Connect 被盗 ~$2.19M(独立事件,根因相近) |
| 2026-06-17 18:34:47 | 攻击者调用 `escapeHatch` 提走 ~$2.16M(区块 25339094,tx `0xab30…c2b5`,**已核**) |
| 2026-06-18 | SlowMist / BlockSec 等披露根因(escapeHatch 缺乏校验、public input 绑定问题) |
| 2026-06-27 | 取证复核:作案地址已基本清空,受害合约余额归零(**本团队链上核实**) |

---

## 来源

- TronWeekly:《Aztec Network Exploit: $2.16M Drained From Deprecated Bridge》 https://www.tronweekly.com/aztec-network-exploit-2-16m-drained-from/
- Coinlaw:《Aztec Hit by Second $2.1M Hack in Days as Bridge Drained》 https://coinlaw.io/aztec-second-2-1m-hack-private-rollup-bridge/
- CryptoTimes:《Aztec Network's RollupProcessor Exploited for $2.21 Million》 https://www.cryptotimes.io/2026/06/18/aztec-networks-rollupprocessor-exploited-for-2-21-million/
- Protos:《Aztec Network hit by second hack this week as escapeHatch drained of $2M》 https://protos.com/aztec-network-hit-by-second-hack-this-week-as-escapehatch-drained-of-2m/
- DARKNAVY:《Aztec Private Rollup Bridge Escape-Hatch Claim-Proof Drain》 https://www.darknavy.org/web3/exploits/aztec-private-rollup-bridge-escape-hatch-claim-proof-drain/
- SlowMist(Medium):《Analysis of the $2.19 Million Asset Theft from Aztec Connect》 https://slowmist.medium.com/analysis-of-the-2-19-million-asset-theft-from-aztec-connect-d867c59b1fc6
- Coinpedia / Namecoin News 等报道(HitBTC 0.134 ETH 起步资金、赃物结构)
- 链上自验:以太坊主网 RPC `https://ethereum-rpc.publicnode.com`,工具 Foundry `cast`(交易、区块、选择器、余额、字节码)

---

## 免责声明

本报告基于公开链上数据与第三方安全机构公开报道整理,仅作技术研究与风险提示之用。报告**不指认任何特定个人或实体**为攻击者(链上地址不等于现实身份);**不构成任何法律意见或投资建议**;**不保证被盗资金可被追回**。报告中明确标注"本团队链上核实"的为我方使用上述 RPC 自行复核;标注"报道采信 / 未链上核实"的部分(如 HitBTC 注资交易、各资产精确金额、合约内部逻辑)源自第三方,读者应自行复核。不同来源在金额口径上存在出入,已在文中注明。© 2026 DuoLaSafe.
