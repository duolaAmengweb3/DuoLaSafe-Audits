# MultiSigTimelock 智能合约审计报告

> DuoLaSafe 智能合约审计 · CodeHawks 2025-12-multisig-timelock · 2026-06-27
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 1. 审计范围

| 项目 | 内容 |
|------|------|
| 标的 | CodeHawks First Flight — Timelock Multi-Signature Wallet |
| 仓库 | `CodeHawks-Contests/2025-12-multisig-timelock` |
| 合约 | `src/MultiSigTimelock.sol`(nSLOC 205) |
| 编译器 | `^0.8.19`(实测 solc 0.8.34) |
| 框架 | Foundry |
| 依赖 | OpenZeppelin `Ownable` / `AccessControl` / `ReentrancyGuard` |

合约目标:3-of-N(N≤5)基于角色的多签钱包,带按金额递增的动态时间锁(<1 ETH 无锁,1–10 ETH 1 天,10–100 ETH 2 天,≥100 ETH 7 天)。

本次审计聚焦多签/时间锁高危类:签名计数与重放、签名去重、owner 对 signer 的增删权限、阈值绕过、时间锁绕过、提案执行校验。

---

## 2. 发现概览

| 编号 | 严重度 | 标题 | 状态 |
|------|--------|------|------|
| H-01 | **High** | `revokeSigningRole` 不清理待处理交易的确认数,被移除签名者的「幽灵确认」仍计入 3-of-N 法定数,可在不足 3 个当前签名者真实同意下执行转账 | 已 PoC 证明 |

> 仅报告能以可运行 PoC 证明的发现。下文「对抗性验证」列出我尝试过但**确认不成立**、故不报告的攻击面。

---

## 3. 详细发现

### H-01 · High · 移除签名者后遗留「幽灵确认」,绕过 3-of-N 法定数

**位置**
- `src/MultiSigTimelock.sol#revokeSigningRole`(L209–240)
- 关联:`_confirmTransaction`(L327–344)、`_executeTransaction`(L350–381)

**根因**

`revokeSigningRole` 在移除一个签名者时,只更新了签名者数组 / 角色 / `s_isSigner`:

```solidity
function revokeSigningRole(address _account) external nonReentrant onlyOwner noneZeroAddress(_account) {
    ...
    s_signers[s_signerCount - 1] = address(0);
    s_signerCount -= 1;
    s_isSigner[_account] = false;
    _revokeRole(SIGNING_ROLE, _account);
}
```

但它**完全没有处理这个账户此前对任何待处理(未执行)交易投下的确认**:

- 交易结构里的累加器 `s_transactions[txnId].confirmations` 不会因移除而递减;
- `s_signatures[txnId][_account]` 仍然保持 `true`。

而执行时的法定数检查只看这个累加器:

```solidity
if (txn.confirmations < REQUIRED_CONFIRMATIONS) {
    revert MultiSigTimelock__InsufficientConfirmations(REQUIRED_CONFIRMATIONS, txn.confirmations);
}
```

于是一笔交易的 `confirmations` 里可能包含**已经不再是签名者**的账户投下的票。多签的核心安全保证是「N 个*当前受信任*签名者中至少 3 个同意」,而这里退化为「历史上累计 3 次确认即可」。

**影响**

- 一个被移除的签名者(例如:私钥泄露、离职、被踢出组织)其确认仍然「永久」计入法定数。owner 移除它本意是撤销其权力,实际却没有撤销它在待处理交易上已经施加的影响。
- 攻击/事故路径:某交易被恶意/可疑签名者确认后,owner 出于安全把该签名者移除——本以为这降低了该交易的支持票,实际上支持票一票未减,交易仍可被任意一名剩余签名者执行,资金外流。
- 极端情况下(H-02 子场景):移除到只剩 1 个签名者,一笔「3-of-N」交易仍可由这唯一签名者单方执行,多签彻底失效。
- 影响资产:钱包内全部 ETH(交易 `value` 任意,只要不超过余额)。

属于**资金可被在不满足真实法定数条件下转走**,故评为 High。

**PoC**

文件:`test/PoC_DuoLaSafe.t.sol`

核心用例 `test_H01_StaleConfirmationsAllowExecutionByNonSigners`:
1. 设 4 个签名者(OWNER、S2、S3、S4);
2. OWNER 提议向 ATTACKER 转 0.5 ETH(<1 ETH,无时间锁);
3. 仅 OWNER、S2 两个「当前可信」签名者同意;S3 也确认了一次,但随后 owner 把 S3 移除;
4. 断言移除后 `confirmations` 仍为 3(幽灵票未减);
5. 任意剩余签名者执行成功,ATTACKER 收到 0.5 ETH——而真正同意的当前签名者只有 2 个。

`test_H02_QuorumMetWithSingleHonestSignerViaRoleChurn` 进一步把签名者移除到只剩 OWNER 一人,`confirmations` 仍为 3,单一签名者完成「3-of-N」执行。

`test_Control_QuorumEnforcedWithoutChurn`(对照组)证明:在没有角色变动时,2 票确实会被法定数检查正确拦截(revert `InsufficientConfirmations(3,2)`),从而证明 H-01 确实源于「遗留的过时状态」,而非根本没有法定数检查。

**forge 输出(必须 PASS,实测)**

```
Ran 3 tests for test/PoC_DuoLaSafe.t.sol:PoC_DuoLaSafe
[PASS] test_Control_QuorumEnforcedWithoutChurn() (gas: 278937)
[PASS] test_H01_StaleConfirmationsAllowExecutionByNonSigners() (gas: 484406)
[PASS] test_H02_QuorumMetWithSingleHonestSignerViaRoleChurn() (gas: 390145)
Suite result: ok. 3 passed; 0 failed; 0 skipped
```

**修复建议**

需在移除签名者时回收其已投出的确认。由于无法在 O(1) 内遍历所有待处理交易,推荐两类方案之一:

方案 A(推荐,执行期动态校验)——在执行时按「当前签名者」重新核验法定数,不再信任累加器:

```solidity
function _countValidConfirmations(uint256 txnId) internal view returns (uint256 c) {
    for (uint256 i = 0; i < s_signerCount; i++) {
        if (s_signatures[txnId][s_signers[i]]) c++;
    }
}
// 执行时:
if (_countValidConfirmations(txnId) < REQUIRED_CONFIRMATIONS) {
    revert MultiSigTimelock__InsufficientConfirmations(REQUIRED_CONFIRMATIONS, _countValidConfirmations(txnId));
}
```

这样只有「当前仍是签名者」且确认过的票才被计入,移除签名者后其票自动失效(数组最多 5,gas 可接受)。

方案 B(确认快照失效)——为每笔交易记录提议时的签名者集合 / epoch,任一角色变动后让旧确认作废、强制重新确认。实现更重,但语义最严格。

无论哪种,均应同时考虑「revoke 后再 grant 同一地址」时 `s_signatures` 仍为 `true` 导致无法重新确认的副作用(方案 A 天然规避,因为它不依赖累加器)。

---

## 4. 对抗性验证与排除(诚实记录)

为避免凑数,以下攻击面经 PoC 实测**确认不成立**,故不报告:

1. **swap-and-pop 是否损坏被搬移签名者的状态** — 测试 `test_swapPopKeepsMovedSignerValid`:移除 S2 后,被搬入其槽位的 S4 仍持有 `SIGNING_ROLE` 且能正常确认。`s_isSigner` 与角色一致,**无 bug**。
2. **大额交易时间锁是否可绕过** — 测试 `test_timelockEnforcedForLargeValue`:100 ETH 交易在 7 天未到时执行 revert,warp 7 天后才成功。`_getTimelockDelay` 边界(`>=`)与 README 描述一致,**无绕过**。
3. **重复确认 / 单签名者刷票** — `_confirmTransaction` 的 `s_signatures[txnId][msg.sender]` 去重有效,同一地址无法重复 +1。
4. **重入** — `_executeTransaction` 遵循 CEI(先置 `executed=true` 再外部 call),且全程 `nonReentrant`,执行重入无法二次提取。
5. **余额校验** — 执行前校验 `txn.value > address(this).balance` 拦截超额,无法透支。

注:H-01 的 `s_signatures` 不清理本身也会引发「revoke 后 re-grant 无法重新确认」的功能性副作用,属于同一根因,归并在 H-01 修复中处理,不另立条目。

---

## 5. 方法论

1. 克隆仓库,通读 README/NatSpec,明确设计意图(3-of-N、动态时间锁、角色驱动)。
2. 人工逐函数审计,重点针对多签/时间锁高危模式:签名计数与去重、owner 增删 signer 的状态一致性、阈值/时间锁绕过、提案-确认-执行全链路状态机。
3. 对每个疑似高危编写独立、可运行的 Foundry PoC(不依赖项目 script,避免外部库噪声),要求 `forge test` 实测 PASS。
4. 对每个「疑似但可能不成立」的攻击面编写对抗性反证,确认成立才入报告,不成立则记入第 4 节排除清单。

环境:Foundry(solc 0.8.34),OpenZeppelin / forge-std。PoC 文件 `test/PoC_DuoLaSafe.t.sol`,全部 3 个用例 PASS。

---

## 6. 免责声明

本报告基于审计时点提供的源码,仅覆盖 `src/MultiSigTimelock.sol`。审计不构成对合约绝对安全的保证,亦不构成任何投资或法律建议。修复后应重新审计并以独立 PoC 复测。DuoLaSafe 不对因使用本报告或部署相关合约产生的任何损失负责。
