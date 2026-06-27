# BriVault 智能合约审计报告

> DuoLaSafe 智能合约审计 · CodeHawks 2025-11-brivault · 2026-06-27
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 一、范围

| 项目 | 内容 |
|------|------|
| 标的 | `CodeHawks-Contests/2025-11-brivault`（Tournament Vault – Betting） |
| 提交 | `--depth 1` 主分支(审计当日) |
| 合约 | `src/briVault.sol`(193 nSLOC)、`src/briTechToken.sol` |
| 标准 | ERC4626 代币化金库 + Ownable |
| 工具链 | Foundry(forge 0.8.34)、OpenZeppelin v5.6.1、solady |
| 已知问题 | README 标注 "No known Issues" |

**协议逻辑**:用户在赛事开始前 `deposit`(扣参与费)→ `joinEvent`(选队、记录份额)→ 赛后 owner `setWinner` → 押中队伍的赢家按份额瓜分整个金库(含输家本金)。

本报告**只列出已用可运行 Foundry PoC 证明(全部 PASS)的发现**,绝不臆测凑数。

---

## 二、发现汇总

| 编号 | 严重度 | 标题 |
|------|--------|------|
| C-01 | **Critical** | `withdraw` 用 `balanceOf` 计份额,join 后再存款可掏空整个奖池、令诚实赢家归零 |
| C-02 | **Critical** | `deposit` 中 `stakedAsset[receiver] =` 覆盖式赋值,二次存款导致首笔本金永久卡死 |
| M-01 | Medium | `_convertToShares` 用实时金库余额计价,首存通胀 / 直接转账可稀释后来者份额 |

---

## C-01(Critical):`withdraw` 用 `balanceOf` 计份额,joinEvent 后再次存款可掏空整个奖池

### 位置
`src/briVault.sol`
- `joinEvent`(L242-269):`userSharesToCountry[msg.sender][countryId] = balanceOf(msg.sender)` 与 `totalParticipantShares` / 隐含的 `totalWinnerShares` 在此**快照**。
- `_getWinnerShares`(L191-198):`setWinner` 时累加各赢家 `userSharesToCountry[user][winnerCountryId]` 得到 `totalWinnerShares`。
- `withdraw`(L294-315):`uint256 shares = balanceOf(msg.sender);` 然后 `assetToWithdraw = Math.mulDiv(shares, finalizedVaultAsset, totalWinnerShares)`。

### 根因
赢家可领取金额的**分子**用的是提款时刻的 `balanceOf(msg.sender)`(实时余额),而**分母** `totalWinnerShares` 是 `joinEvent` 时按当时余额做的**快照**之和。两者口径不一致。

攻击者只需:`deposit` → `joinEvent`(此刻把较小的份额计入 `totalWinnerShares`)→ **再次 `deposit`**。第二次存款给攻击者额外 mint 了份额,推高了 `balanceOf`,但 `totalWinnerShares` 不再更新。于是攻击者的 `shares/totalWinnerShares` 比例被人为放大,可领走远超其公平份额、直至掏空 `finalizedVaultAsset`,后续诚实赢家因金库余额不足而 `withdraw` 直接 revert。

### 影响
直接资金被盗 + 协议彻底资不抵债。PoC 中攻击者净投入 ~29.55 ether,**领走全部 39.4 ether 奖池**,诚实赢家 u1 应得 19.7 ether 却拿到 **0**。属可重复、无需特殊前置条件的 Critical。

### PoC(`test/DuoLaSafePoC.t.sol::test_PoC2_postJoin_deposit_inflates_payout`)

核心步骤:u1 存 10 ether 并 join 队伍 5;攻击者存 10 ether、join 队伍 5(快照计入),**再存 10 ether**;u2 存 10 ether join 输家队伍 7 充实奖池;owner 设赢家为 5;攻击者先提款。

```
forge test --match-test test_PoC2_postJoin_deposit_inflates_payout -vv
```

```
[PASS] test_PoC2_postJoin_deposit_inflates_payout()
  totalWinnerShares (snapshot): 19700000000000000000
  attacker balanceOf (incl. post-join topup): 19700000000000000000
  u1 balanceOf: 9850000000000000000
  finalizedVaultAsset: 39400000000000000000
  attacker withdrew: 39400000000000000000   <-- 掏空整个奖池
  attacker net invested: 29550000000000000000
  vault balance remaining for u1: 0          <-- 诚实赢家归零
  u1 owed by formula: 19700000000000000000
```

断言 `vaultBalNow < u1Owed`(资不抵债)与 u1 `withdraw` 必然 revert 均通过。

### 修复
1. `withdraw` 必须用**报名时快照的赢家份额**而非实时 `balanceOf`:即 `uint256 shares = userSharesToCountry[msg.sender][winnerCountryId];`,且领取后将其清零防重入式重复领取。
2. 从根本上禁止 `joinEvent` 之后再 `deposit`,或在 `deposit` 中同步维护已报名用户的份额账本。
3. 建议引入“一人一次有效报名 + 份额冻结”的不变量,并在每次状态变更后核对 `Σ赢家可提 ≤ finalizedVaultAsset`。

---

## C-02(Critical):`stakedAsset` 覆盖式赋值,二次存款使首笔本金永久卡死

### 位置
`src/briVault.sol::deposit`(L207-237),关键行 L222:
```solidity
stakedAsset[receiver] = stakeAsset;   // 覆盖,而非 +=
```
配合 `cancelParticipation`(L275-289):`refundAmount = stakedAsset[msg.sender]`(只退最后一次)、`_burn(msg.sender, balanceOf(...))`(销毁全部份额)。

### 根因
`deposit` 把 `stakedAsset[receiver]` **整体覆盖**为本次净额,而非累加。但每次存款都把本金真实转入金库、并真实 mint 份额。用户二次存款后,`stakedAsset` 只记得最后一笔的金额,首笔本金在账本上凭空消失。

### 影响
- 任何二次存款(常见“加注/补仓”操作)用户,`cancelParticipation` 只能退回**最后一笔**,首笔本金永久滞留合约,无任何函数能取回 → 用户资金直接损失。
- 同理 `withdraw` 等下游账本也基于错误的 `stakedAsset` / 重复 push 的 `usersAddress`,可叠加放大损失与会计错乱。
- 因 `deposit(receiver)` 的 receiver 与 `msg.sender` 解耦,第三方还能存款覆盖他人 `stakedAsset`,构成定向 grief。

### PoC(`test/DuoLaSafePoC.t.sol::test_PoC1_doubleDeposit_loses_first_stake`)

```
forge test --match-test test_PoC1_doubleDeposit_loses_first_stake -vv
```

```
[PASS] test_PoC1_doubleDeposit_loses_first_stake()
  stakedAsset after 1st deposit: 9850000000000000000
  stakedAsset after 2nd deposit: 985000000000000000    <-- 被覆盖
  principal sent in (net of fee, both deposits): 10835000000000000000
  refunded on cancel: 985000000000000000               <-- 只退最后一笔
  victim funds stranded in vault: 9850000000000000000   <-- 首笔本金卡死
```

用户净投入 ~10.835 ether,取消时只退回 ~0.985 ether,**9.85 ether 永久卡死**。

### 修复
- 将 L222 改为累加:`stakedAsset[receiver] += stakeAsset;`。
- `deposit` 的份额应铸给 `receiver` 而非 `msg.sender`(当前 L231 `_mint(msg.sender, ...)` 与 `stakedAsset[receiver]` 口径不一致,二者必须统一)。
- `cancelParticipation` 退款金额应与销毁份额对应的资产严格一致,并清理 `usersAddress` 中的重复/失效记录。

---

## M-01(Medium):`_convertToShares` 用实时金库余额计价,首存通胀 / 直接转账稀释后来者

### 位置
`src/briVault.sol::_convertToShares`(L156-166):以 `IERC20(asset()).balanceOf(address(this))` 作为定价基准,而非记账型 `totalAssets`。

### 根因
份额价格 = `totalSupply / 真实余额`,任何向金库**直接转账**(donation)都会无偿抬高份额价格,使后来存款者按被抬高的价格 mint 到更少份额。这是经典 ERC4626 首存通胀模式;此处因金库逻辑自定义,虽不能像标准 4626 那样直接套利赎回,但能**稀释后来者在 `joinEvent` 中快照的份额**,削弱其在奖池中的占比。

### 影响 / 已用 PoC 验证
`test/DuoLaSafePoC.t.sol::DuoLaSafePoC3::test_PoC3_firstDepositInflation` 已 PASS:攻击者先存 0.001 ether 拿到 ~9.85e14 份额,再**直接转 10 ether** 进金库;受害者随后存 5 ether 只 mint 到 ~4.85e14 份额(远低于公平的 ~4.925e18):
```
atk shares: 985000000000000
vault bal: 10000985000000000000
victim shares for 5 ether: 485064721124969   <-- 被严重稀释
```
因合约缺少标准赎回路径,直接套利受限,故定为 Medium(份额稀释 / 报名占比受损),但与 C-01 叠加可放大危害。

### 修复
改用**记账型** `totalAssets`(独立状态变量随存取更新),而非 `balanceOf`;并采用 OpenZeppelin v5 的虚拟偏移(decimals offset)缓解通胀。

---

## 三、对抗性验证与排除项

为避免凑数,以下点经核查后**排除**或降级,不作为发现上报:

- **`setWinner` 权限**:仅 `onlyOwner` 且 `block.timestamp > eventEndDate`、`WinnerAlreadySet` 防重设,逻辑自洽。owner 设错赢家属信任假设,非合约漏洞。
- **重入**:`withdraw` / `cancelParticipation` 在外部 `safeTransfer` 前已 `_burn` 并清零 `stakedAsset`,标准 ERC20 资产下无经典重入。(注:若资产为回调型 token 仍需复核,但标的限定标准 ERC20。)
- **`deposit` 时间门** `block.timestamp >= eventStartDate`、`joinEvent` 的 `> eventStartDate`、`cancelParticipation` 的 `>=` 边界:存在 1 秒边界不一致(join 用 `>`,deposit/cancel 用 `>=`),属低危边界瑕疵,无法构造有意义 PoC,不单列。
- **`setCountry` 可重复调用覆盖队伍名**:owner 信任范围内,且 `winner` 在 `setWinner` 时已固化为字符串快照,未发现可利用路径。
- **`getCountry` 对未设置 index 返回 `invalidCountry`**:行为符合预期。
- 上述每条均尝试编写 PoC,**无法令其 PASS 者一律不上报**。

---

## 四、方法论

1. 克隆标的,通读 README / protocolFlow,明确金库资金流与不变量。
2. 人工逐函数审计,重点对照金库高危清单:存取份额会计、首存通胀、汇率/价格操纵、提取权限、重入、奖励分配口径一致性。
3. 对每个疑似 High/Critical 编写 Foundry PoC 置于 `test/DuoLaSafePoC.t.sol`,要求 `forge build` 通过且目标测试 **PASS** 方可定级。
4. 对抗性自检:逐一尝试证伪(写反向 PoC、核查边界与信任假设),无法证明者降级或排除。
5. 复现命令(环境):
```bash
export PATH="$HOME/.foundry/bin:$PATH"
cd /tmp/ff-brivault
forge install OpenZeppelin/openzeppelin-contracts foundry-rs/forge-std vectorized/solady
forge build
forge test --match-contract DuoLaSafePoC -vv
forge test --match-contract DuoLaSafePoC3 -vv
```
（注:标的 `remappings.txt` 缺 `@openzeppelin/contracts/` 与 `forge-std/` 映射,审计时已补全以便编译。）

---

## 五、免责声明

本报告基于审计当日所克隆的代码快照,仅就所列范围内合约进行人工审计 + PoC 验证,**不构成对代码无其他漏洞的保证**,亦不构成投资或安全背书。修复后应重新审计。DuoLaSafe 仅对已通过可运行 PoC 证明的发现负责,所有发现均可在上述环境复现。

> DuoLaSafe · Telegram @dsa885 · X @hunterweb303
