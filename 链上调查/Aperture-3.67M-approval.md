# Aperture Finance ~$3.67M 被盗事件链上取证复盘:任意调用滥用历史授权

> DuoLaSafe 链上取证 · 事件 2026-01-25 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

2026-01-25,Aperture Finance 的链上合约因一个内部"自定义 swap"函数(选择器 `0x1d33`,主入口 `0x67b34120`)将**调用目标 target 与 calldata 完全交由调用者控制且未做白名单校验**,攻击者把 target 指向 ERC-20 代币合约、calldata 构造为 `transferFrom(受害者, 攻击者, amount)`,借受害者此前对 Aperture 合约的**历史授权**在合约上下文中被动调用,跨以太坊/Arbitrum/Base 多链盗走约 **$3.67M**;以太坊主战 tx `0x8f28a7f6…` 已链上核实成功执行,单笔即从一个受害地址抽走 **36.918 WBTC**。根因是**任意外部调用(arbitrary-call)+ 输入校验缺失**,而非私钥泄露或预言机操纵。

---

## 1 背景

**Aperture Finance** 是一个集中流动性管理 / 意图(intent)执行类 DeFi 协议,核心业务是围绕 Uniswap V3/V4 头寸(集中流动性 LP)做自动化的再平衡、限价单、杠杆 LP 等"路由+执行"操作。为完成这些操作,其执行合约需要:
- 用户**预先授权**(ERC-20 `approve` / Uniswap V3 头寸 NFT `setApprovalForAll`)给 Aperture 的路由/执行合约;
- 执行合约在用户发起意图时,代用户把资产转入、做 swap、铸造或调整 V3 头寸。

这种"授权一次、合约代为执行"的架构是该类协议的通用模式,但也意味着:**执行合约一旦能被诱导发起任意 `transferFrom`,所有历史授权立刻变成攻击面**。本次受影响的即是其 V3/V4 执行合约族,以太坊侧已核实的受害合约为 `0xD83d960deBEC397fB149b51F8F37DD3B5CFA8913`(链上 codesize 19,443 字节,真实部署合约)。

---

## 2 漏洞根因(核心:approval / 任意调用处理缺陷)

据 BlockSec、SolidityScan 两家独立安全机构的逆向分析,合约为闭源,根因可归纳为:

**(1) 自定义 swap 走低级 `call`,target/calldata 由调用者控制**
内部函数 `0x1d33()` 通过低级 `call` 执行"自定义 swap",接收三个攻击者可提供的参数:
- `target` —— 被调用地址;
- `calldata` —— 调用数据;
- `expectedOutput` —— 用于校验的预期输出值。

合约**未将 `target` 限制为合法 DEX 路由 / 池子白名单**。攻击者把 `target` 设为任意 ERC-20 代币合约,把 `calldata` 构造成 `transferFrom(victim, attacker, amount)`。由于该 `call` 在受害(Aperture)合约的上下文中执行,代币合约看到的 `msg.sender` 是 Aperture 合约本身——于是会**认可受害者此前对 Aperture 合约的授权**,转账被放行。

**(2) 校验位置错置:只校验"授权 spender",不校验"执行 target"**
BlockSec 总结的关键缺陷:合约"对 approval 的 spender 做了校验,却没有校验实际的执行 target",留下可利用缺口。

**(3) `expectedOutput` 由攻击者控制,绕过余额/滑点检查**
攻击者自填 `expectedOutput`,使本应拦截异常输出的余额/滑点校验形同虚设,从而用极小自有资金完成后续 V3 头寸铸造,掩盖资金流。

**(4) 同一根因的姊妹案:SwapNet**
同期 SwapNet 因几乎相同的模式(易受影响选择器 `0x87395540`)被盗约 $13.4M,两案合计约 $17M,被安全方归为"同一类任意调用漏洞"。本报告仅就 Aperture 部分($3.67M)展开核实。

> 一句话:**授权信任的是合约,合约却替任意人发起 `transferFrom`** —— 这是 approval 模式下最经典、也最致命的 arbitrary-call 缺陷。

---

## 3 攻击流程(带 tx)

以太坊主战交易(已用 `cast` 链上核实):

- **tx**:`0x8f28a7f604f1b3890c2275eec54cd7deb40935183a856074c0a06e4b5f72f25a`
- **区块**:24,313,234 · **时间**:2026-01-25 17:10:35 UTC · **status = 1(成功)**
- **攻击者 EOA**:`0xe3E73f1E6acE2B27891D41369919e8F57129e8eA`
- **本笔部署的攻击合约**:`0x5c92884dFE0795db5ee095E68414d6aaBf398130`
- **受害合约**:`0xD83d960deBEC397fB149b51F8F37DD3B5CFA8913`

链上日志还原的步骤:

1. **包装 ETH**:调用 `WETH.deposit()`(`0xC02aaa…WETH` Deposit 事件),为后续铸造 V3 头寸准备少量自有资金。
2. **触发任意调用**:通过 `0x1d33()` 把 target 指向 WBTC(`0x2260FAC5…`,链上 `symbol()` 核实 = "WBTC"),calldata 构造为 `transferFrom(受害者, 攻击者, amount)`。
   - 链上 WBTC `Transfer` 日志:from `0x5240b03b…`(受害地址)→ to `0xe3e73f1e…`(攻击者 EOA),`data = 0xdc0de334`。
   - 解码:`0xdc0de334 = 3,691,897,652`,WBTC 为 8 位精度 → **36.918 WBTC**,即本笔单一受害者被抽走的金额(约 $3.6M 量级,与该以太坊腿 $3.67M 报道吻合)。
3. **绕过校验**:用攻击者自填的 `expectedOutput` 跳过余额检查。
4. **铸造 V3 头寸做收尾**:与 Uniswap V3 NonfungiblePositionManager(`0xC36442…`,`symbol()` 核实 = "UNI-V3-POS")交互铸造头寸(NFT tokenId `0x1205ba` 铸给攻击合约),用最小资金完成流程。

> 同一 tx 既部署攻击合约又执行,故顶层 `input` 是部署字节码;链上可见的 **WBTC `transferFrom` 日志是本案的取证铁证**,直接坐实"借历史授权 + 任意调用"的盗取路径。

---

## 4 规模统计

| 项目 | 数据 | 核实方式 |
|---|---|---|
| 总损失 | ~$3.67M | 多家安全媒体一致(Aperture 部分) |
| 受影响链 | 以太坊、Arbitrum、Base | BlockSec / SolidityScan |
| 以太坊单笔被盗(WBTC) | 36.918 WBTC | `cast` 解码 `0xdc0de334` ÷ 1e8 |
| 主战 tx | `0x8f28a7f6…25a` | `cast receipt` status=1,块 24313234 |
| 攻击者 EOA | `0xe3E73f…E8eA` | 链上 from 字段 |
| 攻击合约 | `0x5c9288…8130` | 链上 contractAddress 字段 |
| 受害合约(ETH) | `0xD83d96…8913` | 链上 to / codesize 19443 |
| 同根因姊妹案 SwapNet | ~$13.4M | BlockSec(合计约 $17M) |

> 说明:$3.67M 为跨链合计的媒体口径;以太坊侧已逐字段链上核实,Arbitrum/Base 侧金额取自安全方报道,未逐链 cast 复核,故以表中标注为准。AMLBot 另给出更大口径(含关联地址、未动用 USDC)的 ~$13M 资金画像,与上述存在地址聚类口径差异,本报告以已链上核实部分为准。

---

## 5 资金追踪

以下为安全方(PeckShieldAlert / AMLBot)披露、本报告未逐笔 cast 复核的链上情报,标注来源:

- **混币**:PeckShieldAlert 监测到攻击者地址将约 **1,242 ETH(约 $2.4M)** 存入 **Tornado Cash** 进行洗白。
- **跨链归集**:AMLBot 称资金经 **Relay Protocol / Superbridge** 等高吞吐桥从 Base 归集至以太坊主网,再分散到一批新建中转地址。
- **关联地址**(AMLBot 口径,聚类待进一步核实):
  - 攻击者 EOA `0xe3E73f1E6acE2B27891D41369919e8F57129e8eA`(本报告链上已核实为主战发起者);
  - `0x5FF8645BbC6c8B4390aA228A3e8bf08240F333b4`(约 $15K,据称一年多前由 Tornado Cash 注资,疑与 Li.Fi 攻击者网络有关联);
  - Base 侧归集地址 `0x6cAad74121bF602e71386505A4687f310e0D833e`(AMLBot 标注,未链上复核)。

> 资金追踪部分以"安全方披露"呈现,凡未经 DuoLaSafe `cast` 逐笔验证的,均不写成已核实。

---

## 6 修复与防御建议

**对协议方(根因修复)**
1. **执行 target 白名单化**:低级 `call` 的目标地址必须限制为受信 DEX 路由 / 池子白名单,严禁调用者把 target 指向任意(尤其是代币)合约。
2. **禁止对外暴露通用 `call` 转发**:若必须支持自定义路由,应对 calldata 的函数选择器做白名单(禁止 `transferFrom` / `approve` / `setApprovalForAll` 等授权敏感选择器)。
3. **校验执行结果而非接受输入声明**:`expectedOutput` 等校验值应由合约从真实余额差额计算,不能由调用者传入。
4. **最小授权 + 即用即收**:改用 Permit2 / 精确额度授权,执行后立即清零额度,避免历史授权长期暴露。
5. **闭源即风险**:本案合约闭源,缺乏外部审查放大了缺陷;关键执行合约应开源并经多方审计。

**对用户(止损)**
1. 立即对 Aperture 风险地址**撤销 ERC-20 授权(`approve` 归零)与 ERC-721 头寸授权(`setApprovalForAll` 撤销)**——官方已发紧急通告要求撤销;
2. 用 Revoke.cash 等工具排查所有曾授权给 Aperture 路由/执行合约的代币与 V3 头寸 NFT。

---

## 7 时间线(UTC)

| 时间 | 事件 |
|---|---|
| 2026-01-25 17:10:35 | 以太坊主战 tx `0x8f28a7f6…` 上链成功(块 24313234),单笔抽走 36.918 WBTC |
| 2026-01-25(当日) | 攻击跨以太坊 / Arbitrum / Base 同步进行,Aperture 侧合计约 $3.67M |
| 2026-01-25(当日) | Aperture Finance 发布紧急通告,呼吁用户撤销 ERC-20 与 ERC-721 头寸授权 |
| 2026-01-25 之后 | PeckShieldAlert 监测到约 1,242 ETH(~$2.4M)流入 Tornado Cash |
| 2026-01 下旬 | BlockSec / SolidityScan / AMLBot 分别发布逆向与资金画像分析,归因任意调用漏洞(与 SwapNet 同根因,合计约 $17M) |

---

## 来源

- BlockSec —《$17M Closed-Source Smart Contract Exploit: Arbitrary-Call Vulnerability in SwapNet and Aperture Finance》https://blocksec.com/blog/17m-closed-source-smart-contract-exploit-arbitrary-call-swapnet-aperture
- SolidityScan —《Aperture Finance Hack Analysis》https://blog.solidityscan.com/aperture-finance-hack-analysis-22dca439ff33
- AMLBot —《$13.5M Lost in Aperture Finance & SwapNet Exploit: Full On-Chain Breakdown》https://blog.amlbot.com/13-5m-lost-in-aperture-finance-swapnet-exploit-full-on-chain-breakdown/
- Cryptopolitan —《Arbitrary-call vulnerability blamed for $17M SwapNet and Aperture Finance hacks》https://www.cryptopolitan.com/arbitrary-call-blamed-swapnet-aperture-hack/
- Cryptopolitan —《Aperture Finance hack funds flow into Tornado Cash》https://www.cryptopolitan.com/aperture-finance-hack-funds-tornado-cash/
- Coinpedia —《DeFi Hack Alert: Aperture Finance Smart Contract Exploit Suffers $3.67M Loss》https://coinpedia.org/news/defi-hack-alert-aperture-finance-smart-contract-exploit-suffers-3-67m-loss/
- Coinfomania —《Aperture Finance Reports Exploit and Urges Users to Revoke Access》https://coinfomania.com/aperture-finance-reports-exploit-and-urges-users-to-revoke-access/
- 链上数据:以太坊主网 `cast` 复核 tx `0x8f28a7f6…25a`(块 24313234,2026-01-25 17:10:35 UTC),WBTC/WETH/UNI-V3-POS 合约 `symbol()` 与日志解码,RPC `https://ethereum-rpc.publicnode.com`

---

## 免责声明

本报告基于公开链上数据与第三方安全机构披露整理,仅供技术研究与风险提示之用。**不指认任何特定个人或实体**;地址聚类与归因部分凡未经 DuoLaSafe 链上逐笔验证的,均已标注为"安全方披露",不代表最终结论。本报告**不构成法律意见、投资建议**,亦**不保证任何被盗资金可被追回**。引用第三方信息其准确性由原始来源负责。

© 2026 DuoLaSafe
