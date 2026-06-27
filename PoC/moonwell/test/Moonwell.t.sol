// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// =============================================================================
// Moonwell cbETH 预言机配置错误 PoC（MIP-X43，2026-02-15）
//
// 根因：cbETH/USD 本应 = (cbETH/ETH 兑换率) × (ETH/USD)。
//       上线 Chainlink OEV wrapper 时，复合预言机喂价漏掉了 ETH/USD 一段，
//       只返回 cbETH/ETH（≈1.06），把一个“无量纲的兑换比率”当成了“美元价”，
//       导致 cbETH 被错价为 ~$1.06 而非 ~$2330，差约 2000 倍。
//       清算人据此以约 $1 的代价夺走 1 个 cbETH，给协议留下坏账。
//
// 不依赖 forge-std：用 external 测试函数 + require 断言。
// =============================================================================

// -----------------------------------------------------------------------------
// 一段“原始喂价源”抽象：返回一个带 8 位小数（Chainlink 风格）的整数报价。
// -----------------------------------------------------------------------------
contract PriceFeed {
    int256 public answer;       // 报价，8 位小数
    constructor(int256 a) { answer = a; }
    function latestAnswer() external view returns (int256) { return answer; }
}

// -----------------------------------------------------------------------------
// 正确实现的复合预言机：cbETH/USD = (cbETH/ETH) × (ETH/USD)
// cbETH/ETH 用 18 位小数表示兑换率（1.06e18 ≈ 1.06）。
// ETH/USD  用 8  位小数表示美元价（2200e8 ≈ $2200）。
// 输出统一为 8 位小数的 USD 价。
// -----------------------------------------------------------------------------
contract CompositeOracleCorrect {
    PriceFeed public cbEthPerEthFeed; // 18 位小数兑换率
    PriceFeed public ethUsdFeed;      // 8  位小数美元价

    constructor(PriceFeed _cbEthPerEth, PriceFeed _ethUsd) {
        cbEthPerEthFeed = _cbEthPerEth;
        ethUsdFeed = _ethUsd;
    }

    // 正确：两段相乘，再用 1e18 归一化兑换率的小数位 -> 得到 8 位小数 USD 价
    function getCbEthUsdPrice() external view returns (uint256) {
        uint256 cbEthPerEth = uint256(cbEthPerEthFeed.latestAnswer()); // 1e18 精度
        uint256 ethUsd      = uint256(ethUsdFeed.latestAnswer());      // 1e8 精度
        return (cbEthPerEth * ethUsd) / 1e18;                          // -> 1e8 精度 USD
    }
}

// -----------------------------------------------------------------------------
// “漏配版”复合预言机（MIP-X43 的 bug）：
// 只取了 cbETH/ETH 这一段，漏乘 ETH/USD。
// 把 1.06e18 的兑换率缩放成 8 位小数后，当成“$1.06 的美元价”返回。
// -----------------------------------------------------------------------------
contract CompositeOracleBuggy {
    PriceFeed public cbEthPerEthFeed; // 18 位小数兑换率
    PriceFeed public ethUsdFeed;      // 配置里存在，但派生公式忘了用它

    constructor(PriceFeed _cbEthPerEth, PriceFeed _ethUsd) {
        cbEthPerEthFeed = _cbEthPerEth;
        ethUsdFeed = _ethUsd; // 漏配：下面的公式根本没有引用它
    }

    // BUG：直接把 cbETH/ETH 兑换率（18 位）缩放成 8 位当 USD 价，漏乘 ethUsd。
    function getCbEthUsdPrice() external view returns (uint256) {
        uint256 cbEthPerEth = uint256(cbEthPerEthFeed.latestAnswer()); // 1e18 精度
        // 漏掉 “ * ethUsd / 1e18”，只做了一次精度缩放
        return cbEthPerEth / 1e10; // 1e18 -> 1e8，结果 ≈ 1.06e8 当成 $1.06
    }
}

// -----------------------------------------------------------------------------
// 极简借贷市场：用某个预言机给 cbETH 抵押品计价，演示清算掠夺。
// -----------------------------------------------------------------------------
contract MiniLendingMarket {
    address public oracle;                       // 计价用的预言机
    mapping(address => uint256) public cbEthCollateral; // 抵押的 cbETH (1e18)
    mapping(address => uint256) public usdDebt;         // 借出的 USD 债务 (1e8)

    constructor(address _oracle) { oracle = _oracle; }

    // 抵押品的美元价值 = cbETH 数量 × cbETH/USD 价
    function collateralUsdValue(address user) public view returns (uint256) {
        uint256 px = CompositeOracleCorrect(oracle).getCbEthUsdPrice(); // 1e8 精度 USD/枚
        // cbEth 1e18 * px 1e8 / 1e18 = USD 价值 1e8 精度
        return (cbEthCollateral[user] * px) / 1e18;
    }

    function deposit(address user, uint256 cbEthAmount) external {
        cbEthCollateral[user] += cbEthAmount;
    }

    function borrow(address user, uint256 usdAmount) external {
        usdDebt[user] += usdAmount;
    }

    // 清算：当抵押美元价值 < 债务时允许清算。
    // 清算人偿还 repayUsd，按当前（错误）预言机价折算夺取等值 cbETH。
    function liquidate(address borrower, address /*liquidator*/, uint256 repayUsd)
        external
        returns (uint256 seizedCbEth)
    {
        require(collateralUsdValue(borrower) < usdDebt[borrower], "healthy: cannot liquidate");
        uint256 px = CompositeOracleCorrect(oracle).getCbEthUsdPrice(); // 错价时这里也是错价
        require(px > 0, "bad price");
        // repayUsd(1e8) 折成 cbETH(1e18)：repayUsd * 1e18 / px
        seizedCbEth = (repayUsd * 1e18) / px;
        if (seizedCbEth > cbEthCollateral[borrower]) {
            seizedCbEth = cbEthCollateral[borrower];
        }
        cbEthCollateral[borrower] -= seizedCbEth;
        usdDebt[borrower] -= repayUsd;
        // (在真实事件中 cbETH 转给清算人；此处用返回值表示掠夺量)
    }
}

// =============================================================================
// 测试合约
// =============================================================================
contract MoonwellOracleTest {
    // 喂价输入（与报告一致的量级）
    int256 constant CBETH_PER_ETH = 1.06e18;  // cbETH/ETH ≈ 1.06（18 位小数）
    int256 constant ETH_USD       = 2200e8;   // ETH/USD  ≈ $2200（8 位小数）

    // ---------------------------------------------------------------------
    // 测试 1：正确价 vs 漏配价，二者相差约 2000 倍
    // ---------------------------------------------------------------------
    function testPriceMisconfigGap() external {
        PriceFeed cbEthPerEth = new PriceFeed(CBETH_PER_ETH);
        PriceFeed ethUsd      = new PriceFeed(ETH_USD);

        CompositeOracleCorrect correct = new CompositeOracleCorrect(cbEthPerEth, ethUsd);
        CompositeOracleBuggy   buggy   = new CompositeOracleBuggy(cbEthPerEth, ethUsd);

        uint256 correctPx = correct.getCbEthUsdPrice(); // 期望 ≈ 2332e8（$2332）
        uint256 buggyPx   = buggy.getCbEthUsdPrice();   // 期望 ≈ 1.06e8（$1.06）

        // 正确价：1.06 * 2200 = 2332 USD（8 位小数 -> 2332e8）
        require(correctPx == 2332e8, "correct price must be $2332 (1e8)");

        // 漏配价：仅 cbETH/ETH ≈ 1.06 USD（8 位小数 -> 1.06e8）
        require(buggyPx == 1.06e8, "buggy price must be ~$1.06 (1e8)");

        // 二者差约 2000 倍：2332 / 1.06 ≈ 2200x（同数量级，远超 1000x）
        uint256 ratio = correctPx / buggyPx;
        require(ratio == 2200, "ratio must be ~2200x");
        require(ratio > 1000, "gap must exceed three orders of magnitude threshold");

        // 健全性：漏掉一段价格组合 -> 美元价掉到 $1 量级（不可能的 cbETH 报价）
        require(buggyPx < 2e8, "buggy price collapsed to ~$1 magnitude");
        require(correctPx > 2000e8, "correct price is in the ~$2000+ range");
    }

    // ---------------------------------------------------------------------
    // 测试 2：在“正确价”预言机下，健康头寸无法被清算（基线对照）
    // ---------------------------------------------------------------------
    function testHealthyUnderCorrectOracle() external {
        PriceFeed cbEthPerEth = new PriceFeed(CBETH_PER_ETH);
        PriceFeed ethUsd      = new PriceFeed(ETH_USD);
        CompositeOracleCorrect correct = new CompositeOracleCorrect(cbEthPerEth, ethUsd);

        MiniLendingMarket market = new MiniLendingMarket(address(correct));
        address borrower = address(0xB0B);

        // 抵押 1 cbETH（真实价值 ≈ $2332），借出 $1000
        market.deposit(borrower, 1e18);
        market.borrow(borrower, 1000e8);

        // 正确价下抵押价值 $2332 > 债务 $1000 -> 健康
        uint256 collValue = market.collateralUsdValue(borrower);
        require(collValue == 2332e8, "collateral worth ~$2332 under correct oracle");

        // 尝试清算应当 revert（健康头寸不可清算）
        bool reverted;
        try market.liquidate(borrower, address(0xA77ACC), 1e8) returns (uint256) {
            reverted = false;
        } catch {
            reverted = true;
        }
        require(reverted, "healthy position must NOT be liquidatable");
    }

    // ---------------------------------------------------------------------
    // 测试 3：在“漏配价”预言机下，attacker 用约 $1 夺走 1 cbETH（坏账）
    // ---------------------------------------------------------------------
    function testLiquidationUnderBuggyOracle() external {
        PriceFeed cbEthPerEth = new PriceFeed(CBETH_PER_ETH);
        PriceFeed ethUsd      = new PriceFeed(ETH_USD);
        CompositeOracleBuggy buggy = new CompositeOracleBuggy(cbEthPerEth, ethUsd);

        // 市场被接到漏配预言机（事件里就是路由换成了错误派生公式）
        MiniLendingMarket market = new MiniLendingMarket(address(buggy));
        address borrower   = address(0xB0B);
        address attacker   = address(0xA77ACC);

        // 借款人抵押 1 cbETH（真实价值 ≈ $2332），借出 $1000（真实下完全健康）
        market.deposit(borrower, 1e18);
        market.borrow(borrower, 1000e8);

        // 漏配价下，抵押被错算为 1 × $1.06 = $1.06 << 债务 $1000 -> 判定可清算
        uint256 buggyCollValue = market.collateralUsdValue(borrower);
        require(buggyCollValue == 1.06e8, "collateral mispriced to ~$1.06");
        require(buggyCollValue < market.usdDebt(borrower), "position falsely underwater");

        // attacker 只偿还 ~$1.06（折算正好夺走 1 cbETH，因为价被压成 $1.06/枚）
        uint256 repayUsd = 1.06e8; // 约 $1
        uint256 seized = market.liquidate(borrower, attacker, repayUsd);

        // attacker 用约 $1 拿走了 1 整枚 cbETH
        require(seized == 1e18, "attacker seized 1 full cbETH");

        // 真实损失：1 cbETH 真值 ≈ $2332，attacker 只付了 ≈ $1.06 -> 坏账 ≈ $2331
        uint256 realValueSeized = 2332e8; // 1 cbETH × 正确价
        require(realValueSeized > repayUsd, "attacker paid far less than real value");
        uint256 badDebt = realValueSeized - repayUsd;
        require(badDebt > 2300e8, "bad debt ~ $2331 per cbETH seized");

        // 强调：差三个数量级 —— 付 $1 量级，夺走 $2000+ 量级的资产
        require(repayUsd < 2e8 && realValueSeized > 2000e8, "paid ~$1, took ~$2000+");
    }
}
