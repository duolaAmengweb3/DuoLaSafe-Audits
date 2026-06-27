# Bybit 15 亿美元被盗事件复盘:Safe{Wallet} 前端供应链攻击与 DELEGATECALL 实现替换

> DuoLaSafe 链上取证 · 事件 2026-02 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

攻击者(经 FBI 与多家安全机构归因于朝鲜 Lazarus Group)通过攻陷 Safe{Wallet} 的开发者环境 / AWS S3 前端托管,向签名界面注入针对 Bybit 的恶意 JavaScript,在多签签名者签署一笔常规冷钱包转账时,把交易在底层悄悄篡改为一笔 `DELEGATECALL`,将 Safe 代理合约的实现指针(storage slot 0)改写为攻击者部署的恶意合约,随后调用其 `sweepETH` / `sweepERC20` 清空冷钱包,合计约 40 万枚 ETH 及多种质押衍生品,价值约 14.6 亿美元——史上最大单笔加密资产盗窃。**本报告所引核心地址与 slot 0 状态均经我方用 `cast` 链上复核。**

---

## 1 背景

- **受害方**:Bybit,头部中心化交易所。被盗对象为其以太坊冷钱包(一个 Safe 多签)。
- **被攻击的工具**:Safe{Wallet}(原 Gnosis Safe),被广泛使用的多签金库。本次根因不在 Safe 智能合约本身,而在其**前端 / 托管基础设施**(Web2 供应链)。
- **事发时间**:2025-02-21,资产被一次性转出。公开披露约在 2025-02-26 前后。
- **本质**:这是一起 **Web2 供应链入侵 → Web3 多签签名劫持** 的复合攻击。多签机制本身未被密码学攻破,被攻破的是"签名者看到的内容"与"实际签署的内容"之间的一致性。

---

## 2 漏洞根因(核心)

### 2.1 入口:前端被植入恶意 JS

据 SlowMist 复盘,恶意代码被注入到 Safe{Wallet} 的 AWS S3 托管资源中(疑似 S3 / CloudFront 凭据泄露或 API key 被盗);后续报道(The Block / BleepingComputer 等)进一步指向一台 **Safe 开发者机器被攻陷**作为更上游的入口。受影响的前端文件被识别为 `app.safe.global` 上的 `_app-52c9031bfa03da47.js`。

恶意脚本是**高度定向**的:仅当交易来源匹配特定合约地址(Bybit 的多签合约,以及一个疑似攻击者控制的地址)时才触发篡改逻辑,对其他用户表现正常,因而极难被察觉。

### 2.2 篡改手法:把转账偷换成 DELEGATECALL 实现替换

签名者在界面上看到的是一笔正常的冷钱包转账。但脚本在底层把待签交易改造为一次 `DELEGATECALL`,目标指向攻击者预先部署的恶意逻辑合约。Safe 是**代理合约**模式——其 storage slot 0 保存"实现合约 / masterCopy"地址,所有逻辑通过 delegatecall 转发到该实现。

这次 `DELEGATECALL` 执行的逻辑,就是把 slot 0 改写为恶意实现地址。一旦签名者凑齐多签门限并提交,这笔"看起来像转账"的交易实际把整个金库的逻辑大脑换成了攻击者的代码。

### 2.3 清空:恶意实现暴露 sweep 函数

被替换后,Safe 代理的全部调用都转发到恶意实现。该实现暴露了归集函数,攻击者调用即可把 ETH 与代币一次性扫走。

### 2.4 我方链上复核(关键证据)

我方使用 `cast` 对 SlowMist 给出的核心地址做了独立验证,结果与其叙事完全吻合:

- **恶意实现合约 `0xbDd077f651EBe7f7b3cE16fe5F2b025BE2969516`** 链上有部署字节码。反解其函数选择器:
  - `0x1163b2b0` = `sweepETH(address)`
  - `0x582515c7` = `sweepERC20(address,address)`
  - `0xa9059cbb` = `transfer(address,uint256)`
  这三个选择器明确出现在该合约字节码中,与"用 sweepETH / sweepERC20 清空金库"的描述一致。
- **被攻陷的 Safe 代理 `0x96221423681A6d52E184D440a8eFCEbB105C7242`** 的 **storage slot 0** 当前读出:
  `0x...bdd077f651ebe7f7b3ce16fe5f2b025be2969516`
  即:**该多签的实现指针至今仍指向上述恶意合约**。这是本案最直接的"指纹"——DELEGATECALL 改写实现指针的结果在链上一直未被复原,可由任何人独立复核。

> 复核命令(供他人重现):
> `cast storage 0x96221423681A6d52E184D440a8eFCEbB105C7242 0 --rpc-url <ETH_RPC>`
> `cast code 0xbDd077f651EBe7f7b3cE16fe5F2b025BE2969516 --rpc-url <ETH_RPC>`

---

## 3 攻击流程

| 阶段 | 内容 | 链上 / 取证锚点 |
|---|---|---|
| 1 准备 | 部署恶意实现合约 | `0xbDd077f651EBe7f7b3cE16fe5F2b025BE2969516`,部署时间 SlowMist 记为 **UTC 2025-02-19 07:15:23** |
| 2 投毒 | 向 Safe{Wallet} 前端 / S3 注入定向恶意 JS | 文件 `_app-52c9031bfa03da47.js`(app.safe.global) |
| 3 劫持签名 | 签名者签署"转账",底层被改为 DELEGATECALL 替换实现 | 替换发生 **UTC 2025-02-21 14:13:35**,经三个 Owner 账户签名 |
| 4 清空 | 调用 `sweepETH` / `sweepERC20` 转出资产 | 资产流入攻击者地址 |
| 5 收口 | 攻击后约 2 分钟内移除 / 还原前端恶意代码 | 抹除痕迹 |

> 注:SlowMist 文中将那笔将 Safe 改为恶意版本的事件标注了一个哈希值 `0x46deef0f52e3a983b67abf4714448a41dd7ffd6d32d32da69d62081c68ad7882`。我方未对该哈希做独立链上核对,故此处仅作"出处转述"而不作为我方已核证据;读者请以原文为准。

**已核地址清单(我方 cast 验证):**

- 恶意实现合约:`0xbDd077f651EBe7f7b3cE16fe5F2b025BE2969516`(有字节码,含 sweep 选择器)— 已核
- 被攻陷 Safe 代理:`0x96221423681A6d52E184D440a8eFCEbB105C7242`(代理合约,slot0 指向上述恶意合约)— 已核
- 主要黑客地址(SlowMist 标注):`0x47666Fab8bd0Ac7003bce3f5C3585383F09486E2`(链上为 EOA,无代码,与"外部账户"性质一致)— 性质已核,归属转述
- 初始攻击地址(SlowMist 标注,资金溯源至币安):`0x0fa09C3A328792253f8dee7116848723b72a6d2e`(链上为 EOA)— 性质已核,归属转述

---

## 4 规模统计

下表为 SlowMist 复盘给出的被盗资产构成(美元估值为事发时点口径,随价格波动,仅供参照)。总额约 14.6 亿美元,业界普遍以"约 15 亿美元"概称。

| 资产 | 数量 | 估值(事发口径) |
|---|---|---|
| ETH | 401,347 | ~$10.68 亿 |
| stETH(Lido 质押 ETH) | 90,375.55 | ~$2.60 亿 |
| mETH | 8,000 | ~$0.26 亿 |
| cmETH | 15,000 | ~$0.43 亿 |
| **合计** | — | **~$14.6 亿** |

> 备注:其中 15,000 cmETH 流入地址 `0x1542368a03ad1f03d96D51B414f4738961Cf4443` 后,被 mETH Protocol 方面冻结 / 追回(SlowMist 转述)。该地址性质我方未单独复核,作出处转述。

---

## 5 资金追踪

各取证团队(SlowMist、Chainalysis、TRM Labs、Nansen、以及独立调查者 ZachXBT)对洗白路径的描述一致,要点如下(均为来源转述,具体子地址我方未逐一链上复核):

- **分散**:约 40 万 ETH 被拆分到约 40 个地址,每个约 1 万 ETH,形成多级分发(SlowMist 另记一个二级分发地址 `0xdd90071d52f20e85c89802e5dc1ec0a7b6475f92` 再拆 9 个地址)。
- **衍生品归一**:mETH / stETH 经 Uniswap、ParaSwap 等兑换为约 98,048 ETH,统一为 ETH 形态便于跨链。
- **跨链换 BTC**:大量 ETH 经 **THORChain**(去中心化跨链流动性协议)换成 BTC;Chainflip 等桥也被用于 ETH→BTC(ZachXBT 指出 Chainflip)。TRM / Chainalysis 估计约 12 亿美元(约 85%)经 THORChain 流转。
- **拒不配合的混币 / 交易所**:**eXch** 处理了数千万美元的相关资金,在 Bybit 直接请求后仍拒绝拦截,被列入"告警主体"名单。
- **速度**:洗白速度异常——据 TRM,48 小时内已有至少 1.6 亿美元过水,数日内未被冻结部分基本全部完成洗白。

---

## 6 修复与防御建议

针对本案"前端被劫持 → 盲签 → 实现被替换"的链条,给多签 / 金库运营方:

1. **What-You-See-Is-What-You-Sign(WYSIWYS)**:对每笔多签交易在**独立、离线的设备**上解析并复核 `to / value / data / operation` 原始字段。本案关键信号是 `operation = 1(DELEGATECALL)`——冷钱包的常规出金**不应**是 DELEGATECALL。任一签名者发现 operation 异常即应拒签。
2. **监控实现指针(slot 0)**:对 Safe 代理的 masterCopy / 实现地址做实时监控,任何变更立即告警并暂停。本案至今 slot 0 仍指向恶意合约,说明此类变更本可被一条简单的链上监控规则捕获。
3. **前端去信任化**:不依赖单一托管前端;使用可复现构建、子资源完整性(SRI)、固定版本哈希;对 S3 / CloudFront / 部署管线做最小权限与密钥轮换,关键签名流程考虑本地自托管前端或硬件钱包内解析。
4. **交易模拟 + 白名单**:签名前用 Tenderly 等做交易模拟,核对实际状态变更;对冷钱包目标地址与调用类型设白名单 / 守卫合约(Safe Guard),拦截非常规 operation 与未知 `to`。
5. **开发者机器与供应链**:本案上游疑为开发者机器被攻陷;对有发布权限的设备做强隔离、EDR、硬件密钥、最小权限,警惕针对工程师的社工 / 伪招聘(Lazarus 惯用 TraderTraitor 手法)。
6. **分层与延时**:大额冷钱包出金引入时间锁 / 二次带外确认,给监控与人工拦截留出窗口。

---

## 7 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2025-02-19 07:15:23 | 攻击者部署恶意实现合约 `0xbDd0…9516`(SlowMist 记)|
| 2025-02-19(当日) | 恶意 JS 注入 Safe{Wallet} 前端 / S3 |
| 2025-02-21 14:13:35 | 经三个 Owner 签名,Safe 实现被 DELEGATECALL 替换为恶意合约 |
| 2025-02-21(随后) | 调用 sweepETH / sweepERC20,约 40 万 ETH 等资产被清空;数分钟内前端恶意代码被移除 |
| 2025-02-21~23 | FBI 五日内确认归因朝鲜 Lazarus(TraderTraitor / APT38);48 小时内 ≥1.6 亿美元过水 |
| ~2025-02-26 | 公开技术披露(SlowMist 等)|
| 其后约 10 天 | 未冻结部分基本洗白完毕,约 12 亿美元经 THORChain 换为 BTC |

---

## 来源

- SlowMist:《Bybit's $1.5 Billion Theft Unveiled: Safe{Wallet} Front-End Code Tampered》— https://slowmist.medium.com/bybits-1-5-billion-theft-unveiled-safe-wallet-front-end-code-tampered-84b78f0fa9c2
- SlowMist:《Hacker Techniques and Questions Behind Bybit's Nearly $1.5 Billion Theft》— https://slowmist.medium.com/slowmist-hacker-techniques-and-questions-behind-bybits-nearly-1-5-billion-theft-09f0b59da2e2
- NCC Group:《In-Depth Technical Analysis of the Bybit Hack》— https://www.nccgroup.com/research/in-depth-technical-analysis-of-the-bybit-hack/
- The Block:Lazarus compromise of Safe developer machine — https://www.theblock.co/post/343530/
- BleepingComputer:Lazarus hacked Bybit via breached Safe{Wallet} developer machine — https://www.bleepingcomputer.com/news/security/lazarus-hacked-bybit-via-breached-safe-wallet-developer-machine/
- Chainalysis:Bybit Exchange Hack(Feb 2025)— https://www.chainalysis.com/blog/bybit-exchange-hack-february-2025-crypto-security-dprk/
- TRM Labs:Bybit Hack Update — North Korea Moves to Next Stage of Laundering — https://www.trmlabs.com/resources/blog/bybit-hack-update-north-korea-moves-to-next-stage-of-laundering
- 链上数据:我方使用 `cast`(Foundry)对恶意实现合约字节码、函数选择器、Safe 代理 storage slot 0 做独立复核。

## 免责声明

本报告基于公开来源与可独立复核的链上数据整理,仅用于安全研究与风险警示。报告**不指认任何具体自然人**;地址 / 实体归属(如 Lazarus、Bybit、特定黑客地址)均为转述第三方机构与执法部门的公开结论,我方仅对明确标注"已核"的链上事实负责。本报告**不构成任何法律意见、投资建议或追赃承诺**,DuoLaSafe **不保证任何资产可被追回**。数据截至 2026-06-27,价格类估值随市场波动。

© 2026 DuoLaSafe
