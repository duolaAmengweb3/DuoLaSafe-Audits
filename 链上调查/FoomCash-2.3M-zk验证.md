# Foom Cash ~$2.3M 被盗:Groth16 verifier 可信设置缺陷导致 zk 证明可伪造

> DuoLaSafe 链上取证 · 事件 2026-03-02 · 数据截至 2026-06-27,可复核
> 联系:Telegram @dsa885 · X @hunterweb303

---

## 0 一句话结论

Foom Cash 的链上 Groth16 verifier 在可信设置(trusted setup)Phase 2 阶段漏跑了 snarkjs 的随机化贡献步骤,导致验证密钥里的 `gamma`(γ)与 `delta`(δ)两个 G2 参数都停在默认的 BN254 G2 生成元、彼此相等;配对校验等式因此退化为恒等式("1=1"),攻击者无需任何有效 witness 即可构造能通过校验的伪造证明,在 ETH 与 Base 两链循环调用提款逻辑,放空奖池,合计约 $2.26M(约 24.28T FOOM)。其中约 $1.84M 由白帽(Decurity / duha)抢跑追回。

---

## 1 背景:Foom Cash 与 zk 证明在其中的角色

Foom Cash 是一个基于零知识证明的隐私型 DeFi/抽奖(privacy lottery)协议,自我定位为"升级版 Tornado Cash",部署在 Ethereum 主网与 Base 两条链上。其隐私机制依赖 zk-SNARK(Groth16 方案,BN254 曲线):用户存入资金时生成承诺(commitment),提款时提交一个零知识证明,证明"我知道某个已存入承诺对应的秘密、且对应 nullifier 未被花费",而不暴露存款与提款地址的关联。

在这条信任链里,**链上 verifier 合约是唯一的安全闸门**:它持有电路对应的验证密钥(verification key,含 α、β、γ、δ 及 IC 点),并对每笔提款执行配对(pairing)校验。只要 verifier 接受了一个证明,合约就放款。整个协议的资金安全完全压在"verifier 只接受真证明、拒绝假证明"这一条 soundness(可靠性)假设上。本案正是这条假设在部署环节被打破。

链上核验(ETH 主网):
- FOOM 代币:`0xd0d56273290d339aaf1417d9bfa1bb8cfe8a0933`,`symbol()` 返回 "FOOM",`decimals()` = 18(已用 cast 核实)
- ETH 奖池(Lottery)合约:`0x239af915abcd0a5dcb8566e863088423831951f8`(有约 22KB 字节码)
- ETH Verifier 合约:`0xc043865fb4D542E2bc5ed5Ed9A2F0939965671A6`(约 2KB 字节码,体量与 Groth16 verifier 一致)
- Base 奖池:`0xdb203504ba1fea79164af3ceffba88c59ee8aafd`
- Base Verifier:`0x02c30D32A92a3C338bc43b78933D293dED4f68C6`(字节码体量与 ETH verifier 相同,符合"同一份误配 verifier 部署到两链"的描述)

---

## 2 漏洞根因:zk verifier 的可信设置配置缺陷

### 2.1 Groth16 校验等式与 soundness 的来源

Groth16 的链上校验本质是一组椭圆曲线配对等式,形式约为:

```
e(A, B) = e(α, β) · e(L, γ) · e(C, δ)
```

其中 A、B、C 是证明者提交的三个证明元素;α、β、γ、δ 与 IC 点来自验证密钥;L(即 vk_x)由公共输入(root、nullifierHash、recipient 等)线性组合得到。

**soundness 之所以成立,关键在于 γ 与 δ 在可信设置中被各自独立、随机地"加密化"(toxic waste τ 被销毁),使得 γ、δ 在群里彼此线性无关。** 正因为线性无关,等式右侧的 `e(L,γ)` 项和 `e(C,δ)` 项无法相互抵消,攻击者无法自由凑出一个 C 把公共输入项消掉——他必须真的拥有满足电路约束的 witness。

### 2.2 误配:Phase 2 的随机化步骤被跳过 → γ = δ

根因是部署时的一个致命疏漏:在 snarkjs 的 Groth16 **Phase 2(circuit-specific)可信设置**中,负责把 γ、δ 从默认的 G2 生成元随机化的那一步 CLI 命令**从未执行**。结果是验证密钥里:

```
gamma2 (γ in G2) == delta2 (δ in G2) == BN254 的 G2 生成元(默认占位值)
```

安全方报道直接指出 "the verifier contract had delta2 equal to gamma2 in G2",根因被定性为 "a 'fatal' deployment oversight during its Phase 2 trusted setup process"——不是 Groth16 算法本身的问题,而是部署/配置层把占位参数当成了正式参数。

### 2.3 为何假证明能过:等式退化为恒等式

一旦 γ = δ,`e(L,γ)·e(C,δ)` 变成 `e(L,γ)·e(C,γ) = e(L+C, γ)`,γ、δ 不再线性无关,soundness 直接坍塌。攻击者无需 witness,可纯代数地凑出一组 (A,B,C) 让两边都化为 1:

- 取 `A = α`、`B = β` → 左侧 `e(A,B) = e(α,β)`,与右侧第一项相消;
- 取 `C = −vk_x`(vk_x 即 L,由攻击者自选的公共输入 root/nullifier/recipient 算出)→ 让右侧剩余的公共输入项整体抵消为 1;
- 最终校验等式退化为 **1 = 1**,verifier 无差别接受。

也就是说,verifier 已经丧失"区分真证明与假证明"的能力。攻击者可对任意 nullifierHash 计算出配套的 C,其余输入随意填,逐笔通过校验提款。

> 取证说明:α、β、IC 点、γ/δ 这些值编码在 verifier **合约字节码**(constant)而非可读 storage 槽中,本报告未对字节码逐字节反汇编核出 γ==δ 的原始坐标;该具体相等关系采信 rekt.news 与 cryip(dev.to)的反编译结论,链上侧仅独立核实了 verifier 合约存在、体量与攻击资金流(见第 5 节)。

---

## 3 攻击流程

安全方还原的执行步骤(机械式、可循环):

1. 攻击合约从链上 verifier 读取验证密钥中的 α、β 与 IC 点;
2. 用自选的公共输入(root、nullifier、recipient)计算 vk_x(L);
3. 令 `A = α`、`B = β`、`C = −vk_x`,组装出伪造证明;
4. 调用奖池的提款/领取函数(报道记为 `collect()`),证明通过校验,资金转出到 recipient;
5. 递增 nullifier、改一组新的公共输入,回到第 1 步循环。

放空效率(安全方数据):Base 上约 10 次迭代抽干约 99.97% 流动性;ETH 上约 30 次迭代抽干约 99.99%。

链上核验(ETH 主网,已用 cast 核实):
- 主攻击/回收 tx:`0xce20448233f5ea6b6d7209cc40b4dc27b65e07728f2cbbfeb29fc0814e275e48`,区块 24539650,时间戳 **2026-02-26 07:39:11 UTC**;
- 该 tx 的 `from` = `0x46c403e3DcAF219D9D4De167cCc4e0dd8E81Eb72`(即 whitehat-rescue.eth / Decurity 的 EOA),`to` 为一个攻击/回收合约;
- tx 日志含一条 FOOM Transfer:`from` = 奖池 `0x239af9...`、`to` = `0x46c403...`,`data` 解码为 **4,047,820,800,000 FOOM**(4.0478e12,18 位精度),并伴随奖池合约一条领取事件——证实资金确由奖池流向该 EOA。

> 注:此 tx 的 from 即白帽地址,说明链上能直接核到的这一笔属"白帽抢救/搬空"动作;恶意攻击者在 Base 侧的原始提款笔次本报告未逐笔核到 tx,采信安全方描述。

---

## 4 规模统计

| 项目 | 数值 | 来源/核验 |
|---|---|---|
| 事件链上发生时间(本 tx) | 2026-02-26 07:39:11 UTC | cast 核实(区块 24539650 时间戳) |
| 公开披露日期 | 2026-03-02 前后 | 安全方/媒体报道 |
| 受影响链 | Ethereum 主网 + Base | cast 核实两链合约均有字节码 |
| 损失总额 | 约 $2.26M(报道亦记作 ~$2.3M) | 安全方报道 |
| 被放空 FOOM 总量 | 约 24,283,773,519,600 FOOM(≈24.28T) | 安全方报道 |
| 单笔(本 tx,ETH)转出 | 4,047,820,800,000 FOOM(≈4.05T) | cast 解码 Transfer data |
| 追回金额 | 约 $1.84M(约 81%) | 安全方报道 |
| 未追回 | 约 $0.32M–$0.50M(Base 侧) | 安全方报道 |
| 白帽 duha 赏金 | $320,000 | 安全方报道 |
| Decurity 安全费 | $100,000 | 安全方报道 |
| 同源前例 | Veil Cash(Base,数日前,损失约 2.9 ETH,100% 追回) | 安全方报道 |

> 金额($)采信安全方估值,未做独立计价核算;FOOM token 数量为链上 cast 解码所得。

---

## 5 资金追踪

- **ETH 侧(已链上核实):** 主 tx `0xce2044...` 由 `0x46c403e3DcAF219D9D4De167cCc4e0dd8E81Eb72`(whitehat-rescue.eth / Decurity)发起,将 FOOM 自奖池 `0x239af9...` 转出。安全方称 Decurity 独立发现 γ==δ 缺陷后抢跑放空 ETH 主网奖池,数小时内归还约 $1.84M,事后协商收取 $100K 安全费。Decurity 相关回收 tx:`0xfed2dc60634b321fab073312168b327a47fdd76d2a39489249e4ef986671e83f`(本报告未逐字段二次核验)。
- **Base 侧:** 白帽 "duha"(duha_real)在 Base 上抢先保全资金,但保留了约 $320K–$330K 的 FOOM,后被协议方以赏金形式追认为白帽行为($320K bounty)。
- 涉及的其他 EOA(采信报道,未逐一链上画像):`0x73f55A95D6959D95B3f3f11dDd268ec502dAB1Ea`、`0xa30841846259c02eb540059100b57d87c2384358`。

> 取证立场:本报告不指认上述地址背后的自然人身份;"白帽/攻击者"角色定性采信安全方与协议方公开口径。

---

## 6 修复与防御建议(针对 zk verifier / 可信设置 / 证明校验)

1. **可信设置流程强制化与留痕。** Groth16 Phase 2 的 circuit-specific 贡献(随机化 γ、δ)必须执行,并把每一步 transcript / 贡献哈希存档、公开,做仪式(ceremony)审计。把"是否跑过随机化步骤"纳入部署前必检清单,而非依赖人工记忆。
2. **部署前断言验证密钥参数的合法性。** 在部署脚本里加硬性断言:`gamma2 != delta2`、`gamma2 != G2_generator`、`delta2 != G2_generator`,任一为默认占位值即拒绝部署。可对验证密钥做一次"已知应失败的假证明"负向测试——若假证明能过,立即阻断上线。
3. **verifier 与电路一致性校验。** 用与生产同一份 `.zkey` 重新导出 verifier,逐字节比对链上字节码中的 vk 常量;CI 中加入 snarkjs `zkey verify` 与 verifier 导出一致性检查。
4. **审计覆盖到"配置/部署"层而非只看电路。** 本案电路逻辑未必有错,错在可信设置产物的部署配置。审计范围须包含可信设置仪式、zkey 生成、verifier 导出、链上 vk 常量四个交接点。
5. **多链部署逐链独立核验。** 本案同一份误配 verifier 被部署到 ETH 与 Base 两链——多链应对每条链的 vk 参数单独跑负向测试,不假设"一处正确即处处正确"。
6. **上线后监控与熔断。** 对提款频率、单位时间放款量、nullifier 复用模式设阈值告警与可暂停开关,缩短"被发现到被抽干"的窗口。

---

## 7 时间线

| 时间(UTC) | 事件 | 核验 |
|---|---|---|
| 事发数日前 | Veil Cash(Base)因同型 Groth16 误配被攻击,损失约 2.9 ETH,100% 追回,技术手法被公开 | 安全方报道 |
| 2026-02-26 07:39:11 | ETH 主网主 tx `0xce2044...` 上链:白帽地址自奖池转出约 4.05T FOOM(放空动作) | cast 核实 |
| 2026-02-26(同日前后) | ETH/Base 两链奖池被循环放空,合计约 $2.26M(~24.28T FOOM);Decurity 抢跑 ETH、duha 保全 Base | 安全方报道 |
| 数小时内 | Decurity 归还约 $1.84M(约 81%);duha 保留约 $320K 后由协议追认 | 安全方报道 |
| 2026-03-02 前后 | 协议方与媒体公开披露,定性为 Phase 2 可信设置部署疏漏(γ==δ);verifier 已修复 | 安全方报道 |
| 事后 | duha 获 $320K 赏金,Decurity 获 $100K 安全费 | 安全方报道 |

> 日期说明:链上可独立核到的关键 tx 时间为 **2026-02-26**;**2026-03-02** 为公开披露/通报日。两者并存,均如实标注。

---

## 来源

- rekt.news,"The Unfinished Proof"(addresses / tx / 攻击机制): https://rekt.news/the-unfinished-proof
- Cryptopolitan,"'Upgraded Tornado Cash' Foom.Cash faces almost $2.3M loss in exploit": https://www.cryptopolitan.com/foom-cash-faces-2-3m-loss-in-exploit/
- FinanceFeeds,"Foom Cash Recovers $1.84M After $2.26M Exploit With Help From White Hat Hacker": https://financefeeds.com/foom-cash-recovers-1-84m-after-2-26m-exploit-with-help-from-white-hat-hacker/
- Cryptotimes,"FOOMCASH Loses $2.26M in Copycat zkSNARK Exploit": https://www.cryptotimes.io/2026/02/26/foomcash-loses-2-26m-in-copycat-zksnark-exploit/
- dev.to (cryip),"The $1.8M FOOM Club Exploit: When a Groth16 Verifier Misconfiguration Breaks Soundness": https://dev.to/cryip/the-18m-foom-club-exploit-when-a-groth16-verifier-misconfiguration-breaks-soundness-5b9
- ainvest,"Foom.Cash Exploit: $2.26M Loss, $1.83M White-Hat Recovery Flow": https://www.ainvest.com/news/foom-cash-exploit-2-26m-loss-1-83m-white-hat-recovery-flow-2603/
- 链上自核:cast 1.5.1(ETH publicnode / Base publicnode RPC),tx `0xce2044...`、FOOM token、ETH/Base verifier 与奖池合约字节码

---

### 免责声明

本报告基于截至 2026-06-27 的公开信息与链上数据整理,仅供安全研究与技术复盘之用。报告不指认任何特定自然人或实体的法律责任,不构成法律意见、投资建议或资产追回承诺。链上地址与角色定性采信公开报道与协议方口径,可能随新证据更新。部分加密学细节(verifier 字节码内 γ==δ 的原始坐标)采信第三方反编译结论,未逐字节独立复核。© 2026 DuoLaSafe。
