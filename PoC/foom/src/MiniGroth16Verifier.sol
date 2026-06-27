// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
 * ============================================================================
 *  MiniGroth16Verifier — 演示 verifier 退化原理的最小化模型,非真实 Groth16 配对
 * ============================================================================
 *
 *  目的:复现 Foom Cash (~$2.3M) 漏洞根因 ——
 *  Groth16 可信设置 Phase 2 漏跑随机化贡献,导致验证密钥里
 *  gamma(γ) == delta(δ),使配对校验退化为恒等式,无 witness 的伪造证明也能通过。
 *
 *  ----------------------------------------------------------------------------
 *  这不是真实的 BN254 配对实现。
 *  ----------------------------------------------------------------------------
 *  真实 Groth16 链上校验为:
 *
 *      e(A, B) == e(alpha, beta) * e(L, gamma) * e(C, delta)         (配对乘积)
 *
 *  其中 e(·,·) 是 BN254 上的双线性配对,A/B/C 是 G1/G2 上的曲线点,
 *  alpha/beta/gamma/delta/L 来自验证密钥与公共输入。
 *
 *  本模型在【指数域 / 离散对数域】里复现同一代数结构。这是密码学里推理
 *  Groth16 soundness 的标准抽象:把群元素 g^x 用其指数 x 表示,则双线性配对
 *
 *      e(g1^a, g2^b) = T^(a*b)
 *
 *  在目标群里对应指数相乘。目标群元素用其指数(对数)加性表示后,配对乘积
 *  等式就化为指数的加法/乘法等式:
 *
 *      A*B == alpha*beta + L*gamma + C*delta                         (模 r 域运算)
 *
 *  这个抽象【忠实保留了 soundness 依赖 gamma、delta 在指数上线性无关】这一核心:
 *  只要 gamma != delta,L*gamma 与 C*delta 两项不能相互抵消,攻击者无法在不知道
 *  witness 的情况下自由凑出 C 把公共输入项消掉;一旦 gamma == delta,它们坍缩成
 *  L*gamma + C*gamma = (L+C)*gamma,攻击者取 C = -L 即可让该项归零,等式退化为
 *  alpha*beta == alpha*beta(即 "1=1"),verifier 丧失区分真假证明的能力。
 *
 *  我们用 BN254 标量域阶 r 做模运算,使 "-L" 等代数构造与真实曲线上的群运算
 *  同构(群运算在指数上即模 r 的加法/乘法),从而让伪造逻辑不是硬编码的 pass,
 *  而是真正由 gamma==delta 这一条件代数地推导出来。
 */

contract MiniGroth16Verifier {
    // BN254 标量域阶 r(Groth16 见证/标量所在域)。指数域运算全部在此模下进行,
    // 使 "-L" 等代数构造与真实曲线群运算(在指数上即模 r 加法/乘法)同构。
    uint256 internal constant BN254_R =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    // ---- 验证密钥(指数域表示)----
    // alpha, beta, gamma, delta 模拟 G1/G2 上 vk 点的离散对数。
    uint256 public immutable alpha;
    uint256 public immutable beta;
    uint256 public immutable gamma;
    uint256 public immutable delta;

    // 仅用于内部建模公共输入到 L 的线性组合(对应真实 vk 里的 IC 点)。
    uint256 internal immutable icBase;   // IC[0]
    uint256 internal immutable icCoeff;  // IC[1] 的系数(单公共输入,够演示)

    constructor(
        uint256 _alpha,
        uint256 _beta,
        uint256 _gamma,
        uint256 _delta,
        uint256 _icBase,
        uint256 _icCoeff
    ) {
        alpha = _alpha % BN254_R;
        beta = _beta % BN254_R;
        gamma = _gamma % BN254_R;
        delta = _delta % BN254_R;
        icBase = _icBase % BN254_R;
        icCoeff = _icCoeff % BN254_R;
    }

    // 由公共输入计算 L(即 vk_x),对应真实 verifier 里 IC[0] + sum(input_i * IC[i])。
    function computeL(uint256 publicInput) public view returns (uint256) {
        return addmod(icBase, mulmod(icCoeff, publicInput % BN254_R, BN254_R), BN254_R);
    }

    /*
     * 核心校验(指数域),对应真实配对乘积等式:
     *     e(A,B) == e(alpha,beta) * e(L,gamma) * e(C,delta)
     * 指数域形式:
     *     A*B == alpha*beta + L*gamma + C*delta   (mod r)
     */
    function verify(
        uint256 A,
        uint256 B,
        uint256 C,
        uint256 publicInput
    ) public view returns (bool) {
        uint256 L = computeL(publicInput);

        uint256 lhs = mulmod(A % BN254_R, B % BN254_R, BN254_R);

        uint256 rhs = mulmod(alpha, beta, BN254_R);
        rhs = addmod(rhs, mulmod(L, gamma, BN254_R), BN254_R);
        rhs = addmod(rhs, mulmod(C % BN254_R, delta, BN254_R), BN254_R);

        return lhs == rhs;
    }
}
