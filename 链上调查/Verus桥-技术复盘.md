# Verus–Ethereum 跨链桥 $11.58M 被盗 —— 技术复盘

> DuoLaSafe 链上取证 · 事件 2026-05-17/18 · **数据截至 2026-06-27 链上快照,可复现**
> 联系:Telegram [@dsa885](https://t.me/dsa885) · X [@hunterweb303](https://x.com/hunterweb303)
> 全文每个地址、交易哈希均可在区块浏览器独立核对。

## 0 · 一句话结论
Verus–Ethereum 跨链桥的 `submitImports`(导入提交)函数,**没有强制校验"以太坊侧要释放的金额"等于"Verus 侧真实锁定/销毁的金额"**。攻击者提交伪造的跨链导入凭证,从桥里领走约 **$11.58M**(103.6 tBTC、1,625 ETH、147,000 USDC),随后全部换成 **5,402.4 ETH**。根因是跨链桥最经典的"金额不守恒"。

## 1 · 背景:桥靠"imports"搬钱
Verus–Ethereum 桥通过提交跨链"导入(imports)"凭证来完成资产转移:一侧锁定/销毁,另一侧凭凭证释放。释放逻辑入口是桥合约的 `submitImports`:
- **Verus 桥合约**:`0x71518580f36FeCEFfE0721F06bA4703218cD7F63`

桥的安全完全建立在"凭证里声明的金额 == 对侧真实发生的金额"这个等式上。

## 2 · 漏洞根因:少校验了"金额守恒"这一条
两侧各有校验逻辑,但**没有任何一侧强制校验跨端金额一致**。`submitImports` 接受了攻击者构造的导入凭证、并据此释放资产,却没有把"声明释放的金额"与"Verus 侧真实锁定的金额"做绑定校验。

> 这是跨链桥被盗的头号根因:一道门两把锁,却没人锁住最关键的"金额守恒"那把。审计桥时,**两侧金额守恒是否被强制、是否可绕过,必须是第一优先级**。

## 3 · 攻击流程(链上实证)
| 时间(UTC) | 动作 | 合约 / method | 交易哈希 |
|---|---|---|---|
| 2026-05-17 23:24 | 准备 | `execute` → `0x66a9893c…dBA8Af` | `0x6e284906abb5d4444eab72cebdfb525300ed5d81df8895f701f7fe4fd66bafc9` |
| 2026-05-17 23:55 | **核心利用** | `submitImports` → 桥 `0x71518580…cD7F63` | `0x6990f01720f57fc515d0e976a0c4f8157e0a9529194c4c15d190e98d087eb321` |

发起地址:**`0x5aBb91B9c01A5Ed3aE762d32B236595B459D5777`**。攻击者通过 `submitImports` 提交伪造导入,桥未校验金额即释放资产;赃款随后被换成 ETH 并归集。(媒体多记为 5/18,实际利用交易时间为 5/17 23:55 UTC。)

## 4 · 规模统计
| 项 | 数值 |
|---|---|
| 直接损失 | **≈ $11.58M** |
| 被盗资产 | 103.6 tBTC、1,625 ETH、147,000 USDC |
| 换成 | **5,402.4 ETH** |
| 发起地址 | `0x5aBb91B9c01A5Ed3aE762d32B236595B459D5777` |
| 归集地址 | `0x65Cb8b128Bf6e690761044CCECA422bb239C25F9` |

## 5 · 资金追踪(关键:别信"资金未动"的旧新闻)
案发当时(5 月)PeckShield 等报道**"5,402 ETH 仍在攻击者钱包、未见移动"**。链上实证却是:

**2026-05-21 19:47–19:50(案发仅 3 天后),归集钱包 `0x65Cb8b…25F9` 分两笔把 5,402 ETH 全部转出:**
| 金额 | 去向 | 交易哈希 |
|---|---|---|
| **4,052 ETH** | `0xF9AB28cB7b72B518e6a351FbdaBe69362cBC1A74` | `0xb428dae60a234c149c8bc4468979356c434726bf8f588b6c97bd7144aa5bcefe` |
| **1,350 ETH** | `0xA8D3662af2Fc73EDE0ba005b9CB10568b7c68372` | `0x84aada67c438869ea19cf6e82fb33b3d2515b636c166dfc356eb8167a15d5e67` |

**我们 2026-06-27 的快照**:归集钱包 `0x65Cb8b…25F9` 余额 **0.0017 ETH**(nonce 5)、发起钱包 `0x5aBb91…5777` 余额 **0.89 ETH**(nonce 3)—— 早已清空。

> **"资金未动"只成立了 3 天。** 这正是 DuoLaSafe 坚持"取证看根因 + 定格带日期快照"的原因:依赖旧新闻"钱还在原地"会被时间打脸;本复盘的价值在**根因(永远成立)**与**这组带日期的链上事实**。

## 6 · 修复与防御建议
1. **跨链桥必须强制校验金额守恒**:释放金额与对侧真实锁定/销毁金额绑定校验,且不可绕过 —— 这是桥安全的命门。
2. **凭证完整性**:`submitImports` 类入口须验证凭证的全部关键字段,缺一不可。
3. **追赃趁早**:本案从"未动"到"清空"仅隔 3 天;真要追回,窗口以天计,需第一时间监控 + 对接交易所/执法。
4. **情报必带时间戳**:任何"资金在某处"的结论都须注明截至日期。

## 7 · 时间线
- **2026-05-17 23:55 UTC** — 攻击者经 `submitImports` 利用桥,盗走约 $11.58M。
- **2026-05-18** — PeckShield 等报道:已换成 5,402.4 ETH,资金"未见移动"。
- **2026-05-21 19:47–19:50 UTC** — 归集钱包分两笔(4,052 + 1,350 ETH)转出,赃款开始分散。
- **2026-06-27** — DuoLaSafe 快照:归集与发起钱包均已清空。

## PoC(可运行复现)

> 用 Foundry 把根因"金额不守恒"做成最小可运行复现。工程:`/tmp/duolasafe-audits/PoC/verus/`(`foundry.toml` solc=0.8.24 + `test/Verus.t.sol`,不依赖 forge-std)。
> 跑法:`export PATH="$HOME/.foundry/bin:$PATH"; cd /tmp/duolasafe-audits/PoC/verus && forge test -vv`
>
> **声明**:链上真实利用涉及 Verus 跨链导入凭证(notarization/import proof)的伪造,细节非公开。本 PoC 不复刻凭证格式,而是把**根因——"submitImports 释放资产时未校验 `释放额 == 源链真实锁定/销毁额`"**用最小桥模型忠实复现;脆弱版被抽干、修复版加一行守恒校验即挡住,精确对应报告第 2、6 节。

**① 脆弱桥:直接按 claimedAmount 释放,不校验源链锁定额(根因)**

```solidity
mapping(address => uint256) public lockedOnSource; // 源链真实锁定额(本应是释放上限)

function submitImports(uint256 claimedAmount, address to) external {
    // ❌ 缺失: require(claimedAmount <= lockedOnSource[to], ...);  —— 跨端金额不守恒
    token.transfer(to, claimedAmount);
}
```

**② 攻击者用伪造 claimedAmount(900_000e18,远超真实存入 1e18)抽走储备**

```solidity
bridge.setLockedOnSource(ATTACKER, 1e18);     // 攻击者源链真实只锁了 1e18
bridge.submitImports(900_000e18, ATTACKER);   // 伪造导入,脆弱版直接释放
// 断言:攻击者凭空领走 900_000e18,储备从 1_000_000e18 被抽到 100_000e18
require(token.balanceOf(ATTACKER) == 900_000e18);
require(token.balanceOf(ATTACKER) > 1e18);    // 领走额 >> 真实锁定额 = 金额不守恒
```

**③ 修复桥:加一行金额守恒校验,攻击者同样调用即 revert**

```solidity
function submitImportsSafe(uint256 claimedAmount, address to) external {
    require(claimedAmount <= lockedOnSource[to], "amount not conserved"); // ✅ 释放额绑定源链锁定额
    lockedOnSource[to] -= claimedAmount;
    token.transfer(to, claimedAmount);
}
// attacker 用 900_000e18 调用 → revert;储备分文未动,合法的 <=1e18 导入仍可正常通过。
```

**实测输出(PASS):**

```
Compiling 1 files with Solc 0.8.24
Compiler run successful!

Ran 3 tests for test/Verus.t.sol:VerusPoCTest
[PASS] testExploit_VulnerableBridge_DrainsReserve() (gas: 775786)
[PASS] testFixed_AllowsHonestClaim() (gas: 836307)
[PASS] testFixed_RejectsForgedClaim() (gas: 832063)
Suite result: ok. 3 passed; 0 failed; 0 skipped
```

**解释**:`testExploit_...` 证明脆弱版按攻击者声明的金额无脑释放,领走额(900_000e18)远超其源链真实锁定额(1e18)——即报告第 2 节的"金额不守恒",桥被抽干;`testFixed_RejectsForgedClaim` 证明仅补上 `claimedAmount <= lockedOnSource[to]` 这一条守恒校验,同样的伪造调用即被 revert、储备分文未动;`testFixed_AllowsHonestClaim` 证明修复不误伤合法导入。这正是报告第 6 节"跨链桥必须强制校验金额守恒、释放额与对侧真实锁定/销毁额绑定"的可运行佐证。

---
*来源:链上数据(以太坊公开 RPC / Blockscout,上述地址与交易可在任意区块浏览器复现);事件与根因报道见 PeckShield、Halborn、CoinDesk、AMBCrypto(2026-05)。*
*独立链上取证 · 不指认任何个人 · 不构成法律意见 · 不保证追回 · © 2026 DuoLaSafe*
