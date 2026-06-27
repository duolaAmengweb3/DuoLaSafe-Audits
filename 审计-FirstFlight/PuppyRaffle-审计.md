# PuppyRaffle 智能合约安全审计报告

> DuoLaSafe 智能合约审计 · CodeHawks ai-puppy-raffle · 2026-06-27
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 一、审计概要

PuppyRaffle 是一个抽奖合约:用户支付入场费参与抽奖,赢家获得 80% 奖池 + 一只随机稀有度的小狗 NFT,20% 作为手续费归集到 `feeAddress`。本次审计对 `src/PuppyRaffle.sol` 进行人工代码审计,并为每一个高危/严重发现编写了 **可运行、且实际 PASS 的 Foundry PoC**。

**结论:发现 5 个真实漏洞(2 Critical + 3 High),全部已用 PoC 证明。** 其中任意一个 Critical 都可导致全部用户资金被盗或抽奖结果被操纵。**强烈建议在主网部署前完全重写资金流与随机数逻辑。**

| 编号 | 严重度 | 标题 | PoC 状态 |
|------|--------|------|----------|
| H-01 | **Critical** | `refund()` 重入,清空整个合约余额 | PASS |
| H-02 | **Critical** | 弱随机数,中奖者与稀有度可预测/可操纵 | PASS |
| H-03 | **High** | `totalFees` 使用 `uint64`,手续费会计溢出 | PASS |
| H-04 | **High** | `withdrawFees` 严格相等校验,可被强制转账永久 DoS | PASS |
| H-05 | **High** | `enterRaffle` 重复校验为 O(n²),Gas DoS | PASS |

---

## 二、审计范围

- **标的仓库**:`CodeHawks-Contests/ai-puppy-raffle`(GitHub)
- **被审文件**:`src/PuppyRaffle.sol`
- **编译器**:Solidity `0.7.6`(Foundry / Solc 0.7.6)
- **依赖**:OpenZeppelin Contracts `v3.4.0`(ERC721 / Ownable / Address)、`Brechtpd/base64`
- **PoC 文件**:`test/DuoLaSafePoC.t.sol`(随报告一并交付,可直接 `forge test` 运行)
- **不在范围**:部署脚本 `script/`、链下基础设施、经济模型设计、Gas 优化(仅在构成 DoS 时报告)

---

## 三、发现详情

### H-01 · Critical · `refund()` 重入,可清空整个合约

**位置**:`PuppyRaffle.sol:96-105`

```solidity
function refund(uint256 playerIndex) public {
    address playerAddress = players[playerIndex];
    require(playerAddress == msg.sender, "PuppyRaffle: Only the player can refund");
    require(playerAddress != address(0), "PuppyRaffle: Player already refunded, or is not active");

    payable(msg.sender).sendValue(entranceFee);   // ← 先打钱(外部调用)

    players[playerIndex] = address(0);            // ← 后改状态
    emit RaffleRefunded(playerAddress);
}
```

**根因**:违反 Checks-Effects-Interactions 顺序。`sendValue` 在把 `players[playerIndex]` 置零之前就向 `msg.sender` 转账。攻击者用合约参与,在 `receive()/fallback()` 里回调 `refund(myIndex)`,此时状态尚未更新,`require` 全部通过,于是循环退款,直到合约余额被掏空 —— 包括所有诚实玩家的入场费。

**影响**:协议资金 100% 被盗。任意攻击者只需 1 份入场费即可作为"敲门砖",拿走奖池里全部资金。

**PoC**(`test_H01_ReentrancyDrainsContract`):4 名诚实玩家先注入 4 ETH 奖池,攻击者投入 1 ETH 发起重入,最终合约余额归零,攻击者拿走 5 ETH(诚实玩家 4 ETH + 自己 1 ETH)。

```
[PASS] test_H01_ReentrancyDrainsContract() (gas: 585426)
```
断言:`address(puppyRaffle).balance == 0` 且 `attacker.balance == 5 ether`,均通过。

**修复**:遵循 CEI,先改状态再转账;并加 OpenZeppelin `ReentrancyGuard`:
```solidity
players[playerIndex] = address(0);
emit RaffleRefunded(playerAddress);
payable(msg.sender).sendValue(entranceFee);
```

---

### H-02 · Critical · 弱随机数,中奖者与稀有度完全可预测

**位置**:`PuppyRaffle.sol:128-129`(winner)、`139`(rarity)

```solidity
uint256 winnerIndex =
    uint256(keccak256(abi.encodePacked(msg.sender, block.timestamp, block.difficulty))) % players.length;
...
uint256 rarity = uint256(keccak256(abi.encodePacked(msg.sender, block.difficulty))) % 100;
```

**根因**:随机数完全由链上公开/可被影响的输入构成 —— `msg.sender`(攻击者自选)、`block.timestamp`、`block.difficulty`(矿工/验证者可操纵,合并后为 `prevrandao`,在同一区块内对发起者已知)。任何人都能在链下/同笔交易内复现该计算,只在"自己中奖"或"中传奇 NFT"的区块里才调用 `selectWinner`。

**影响**:抽奖公平性彻底失效。攻击者可保证自己中奖、独吞奖池,并定向铸造稀有/传奇 NFT。

**PoC**(`test_H02_PredictableWinner`):测试用与合约完全相同的公开输入,在调用 `selectWinner()` **之前**就算出中奖者索引与稀有度,随后链上结果与预测逐字节一致。

```
[PASS] test_H02_PredictableWinner() (gas: 288266)
  actual winner : 0x0000000000000000000000000000000000000004
```
断言:`previousWinner() == predictedWinner`,通过。

**修复**:接入 **Chainlink VRF**(可验证随机数),禁止使用 `block.*` 与 `msg.sender` 作为随机源。

---

### H-03 · High · `totalFees` 用 `uint64`,手续费会计溢出

**位置**:`PuppyRaffle.sol:30`、`134`

```solidity
uint64 public totalFees = 0;
...
totalFees = totalFees + uint64(fee);   // ← uint256 fee 被强转 uint64,会静默溢出
```

**根因**:Solidity 0.7 不带溢出检查;`fee`(uint256)被强转为 `uint64` 后累加。`uint64` 最大值 ≈ 18.446 ETH。当单场抽奖手续费(20% 奖池)超过该值时,`totalFees` 回绕(wrap),记录的手续费远小于实际持有的 ETH。

**影响**:① 手续费会计永久错误;② 由于 `withdrawFees` 要求 `balance == totalFees`(见 H-04),溢出后两者永远不相等,**全部手续费被永久锁死**。

**PoC**(`test_H03_FeeOverflow`):100 名玩家 × 1 ETH = 100 ETH 奖池,手续费 20 ETH > uint64 上限。实测:

```
[PASS] test_H03_FeeOverflow() (gas: 5419848)
  real_fee_balance_wei : 20000000000000000000   (合约真实持有 20 ETH 手续费)
  totalFees_uint64_wei :  1553255926290448384   (uint64 回绕后仅记 ~1.553 ETH)
  uint64_max_wei       : 18446744073709551615
  lost_fees_wei        : 18446744073709551616   (= 2^64,被"蒸发")
```
断言:`totalFees < realFeeBalance` 且 `withdrawFees()` revert,均通过。

**修复**:将 `totalFees` 改为 `uint256`;升级到 Solidity 0.8+(内建溢出检查)或使用 `SafeMath`;移除危险的 `uint64` 强转。

---

### H-04 · High · `withdrawFees` 严格相等校验,可被强制转账永久 DoS

**位置**:`PuppyRaffle.sol:157-158`

```solidity
function withdrawFees() external {
    require(address(this).balance == uint256(totalFees), "PuppyRaffle: There are currently players active!");
    ...
}
```

**根因**:用 `address(this).balance == totalFees` 做严格相等校验。合约余额可被外部**强制改变**:通过 `selfdestruct(target)` 或在合约部署前向其地址预存款,均可强制注入 wei,绕过任何 `payable` 限制。一旦余额比 `totalFees` 多出哪怕 1 wei,等式永远不成立。

**影响**:任何人只需花费 1 wei 即可**永久冻结全部手续费提取**。属于无前置条件、零成本的拒绝服务攻击。

**PoC**(`test_H04_WithdrawFeesDoS`):正常抽奖后 `balance == totalFees`(本应可提)。攻击者用 `ForceSend` 合约 `selfdestruct` 强送 1 wei,此后 `withdrawFees()` 永久 revert。

```
[PASS] test_H04_WithdrawFeesDoS() (gas: 356640)
```
断言:`balance > totalFees` 且 `withdrawFees()` revert,通过。

**修复**:不要用合约余额做会计校验;改为按 `totalFees` 记账提款,并允许 `>=`:
```solidity
uint256 feesToWithdraw = totalFees;
totalFees = 0;
(bool success,) = feeAddress.call{value: feesToWithdraw}("");
require(success, "...");
```

---

### H-05 · High · `enterRaffle` 重复校验为 O(n²),Gas DoS

**位置**:`PuppyRaffle.sol:85-90`

```solidity
for (uint256 i = 0; i < players.length - 1; i++) {
    for (uint256 j = i + 1; j < players.length; j++) {
        require(players[i] != players[j], "PuppyRaffle: Duplicate player");
    }
}
```

**根因**:每次 `enterRaffle` 都对**整个已存在的** `players` 数组做双重嵌套循环去重,复杂度 O(n²)。随着玩家增多,每笔入场交易的 Gas 成本急剧上升。

**影响**:① 越晚进场的人付的 Gas 越离谱,本质上是对后进场者不公平 / 软性 DoS;② 攻击者可先用大量地址灌满数组,使后续任何人进场都因超出区块 Gas 上限而 revert,**永久锁死抽奖参与**。

**PoC**(`test_H05_EnterRaffleQuadraticGasDoS`):对比"第 1 批 100 人"与"第 2 批 100 人"的 Gas:

```
[PASS] test_H05_EnterRaffleQuadraticGasDoS() (gas: 25553194)
  gas_first_100  :  6516006
  gas_second_100 : 18994806     (同样 100 人,却贵 2.91 倍)
  ratio_x100     : 291
```
断言:`gasSecond100 > gasFirst100 * 2`,通过。增长呈二次方,确认 DoS。

**修复**:用 `mapping(address => bool)` 或 `mapping(address => uint256)` 记录是否已参与,把去重降到 O(1);或改用每轮递增的 `raffleId` 配合映射,避免遍历数组。

---

## 四、对抗性验证与已排除项

为避免"凑数",以下点经实际验证后**判定不构成可证明的高危**,故不列入发现:

- **`getActivePlayerIndex` 返回 0 的歧义**:索引 0 的真实玩家与"未找到"返回值相同。这是一个真实的逻辑瑕疵(Low/Info),但单独无法导致资金损失或权限提升 —— 它只是放大 H-01 的可用性,**不另列高危**。
- **`selectWinner` 中 `_safeMint` 在转账之后**:若赢家是不实现 `onERC721Receiver` 的合约,`_safeMint` 会 revert,使整笔 `selectWinner` 回滚。这是 Medium 级活性风险,但奖池资金不会丢失(可重抽),**不计入本次高危清单**。
- **`changeFeeAddress` 缺少零地址校验**:仅 `onlyOwner` 可调用,属可信角色操作失误风险(Low),**排除**。
- **`enterRaffle` 中 `players.length - 1` 在空数组上的下溢**:实际进入循环前已 `push` 了至少一个玩家(`require` 保证 `msg.value == fee * len`,len≥1),0.7 下虽可下溢但循环条件使其不可达,**未发现可触发路径,故不报**。
- **重入是否真的能跨"诚实玩家资金"提走**:已用 PoC 实测确认攻击者最终余额 = 5 ETH(含 4 名诚实玩家的钱),**非理论推断**。

所有列出的 5 项发现均以 `forge test` 实际 PASS 的 PoC 为证,无任何臆测条目。

---

## 五、方法论

1. **环境复现**:`--depth 1` clone 后补齐 git submodule 依赖;因官方最新 forge-std 要求 Solidity ≥0.8.13 与本合约 0.7.6 冲突,降级 forge-std 至 `v1.1.1`(支持 ≥0.6.2)并补 `ds-test`,使 `forge build` / `forge test` 全绿(基线 18 测试全 PASS)。
2. **人工审计**:按抽奖类合约常见高危清单逐项排查 —— 退款重入、弱随机数、费用会计溢出、数组型 DoS、重复参与校验、严格余额校验、CEI 顺序、强制转账。
3. **PoC 驱动验证**:每个 High/Critical 单独编写 Foundry 测试(攻击者合约 + 断言),要求**实际 PASS** 才计入;数值证据(被盗金额、溢出回绕值、Gas 倍率)用 `log_named_uint` 精确提取。
4. **对抗性排除**:对每个疑似点反向追问"能否真的触发、能否真的造成损失",无法 PoC 证明的一律降级或排除。

**复现命令**:
```bash
cd /tmp/ff-puppyraffle
export PATH="$HOME/.foundry/bin:$PATH"
forge build
forge test --match-contract DuoLaSafePoC -vv
# => 5 passed; 0 failed
```

---

## 六、免责声明

本报告基于审计时点提供的指定代码快照,采用人工审计 + Foundry PoC 验证的方法完成。安全审计无法保证发现全部漏洞,亦不构成对代码绝对安全的背书或任何投资/财务建议。修复后应重新审计。DuoLaSafe 不对基于本报告的任何决策导致的损失承担责任。

> DuoLaSafe 智能合约审计 · CodeHawks ai-puppy-raffle · 2026-06-27
> 联系:Telegram @dsa885 · X @hunterweb303
