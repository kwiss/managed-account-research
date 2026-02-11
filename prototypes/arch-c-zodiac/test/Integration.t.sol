// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Safe4337RolesModule} from "../src/modules/Safe4337RolesModule.sol";
import {ISafe4337RolesModule} from "../src/interfaces/ISafe4337RolesModule.sol";
import {PackedUserOperation} from "../src/types/PackedUserOperation.sol";
import {MockSafe} from "./mocks/MockSafe.sol";
import {MockRoles} from "./mocks/MockRoles.sol";
import {MockDelay} from "./mocks/MockDelay.sol";

/// @title IntegrationTest - End-to-end test of the full Zodiac pipeline
/// @notice Tests: 4337 -> Safe4337RolesModule -> Roles -> Delay -> Safe
contract IntegrationTest is Test {
    MockSafe public safe;
    MockRoles public roles;
    MockDelay public delay;
    Safe4337RolesModule public module;

    address public entryPoint = address(0xE1);

    // Operator
    uint256 internal operatorPk = 0xA11CE;
    address internal operator;
    uint16 internal constant ROLE_KEY = 1;

    // DeFi target (simulated)
    address public defiTarget = address(0xCAFE);
    bytes4 public defiSelector = bytes4(keccak256("deposit(uint256)"));

    // Timelock params
    uint256 public constant COOLDOWN = 1 hours;
    uint256 public constant EXPIRATION = 7 days;

    function setUp() public {
        operator = vm.addr(operatorPk);

        // 1. Deploy all components
        safe = new MockSafe();
        delay = new MockDelay(address(safe));
        roles = new MockRoles();

        // Constructor no longer takes delayModule (M-04)
        module = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(roles)
        );

        // 2. Configure module chain
        // Enable modules on Safe: Delay is enabled so it can call Safe.execTransactionFromModule
        safe.enableModule(address(delay));
        // Enable Roles module on Delay so Roles can queue txs through Delay
        delay.enableModule(address(roles));
        // Configure Roles to forward to Delay
        roles.setTargetModule(address(delay));

        // Configure Delay cooldown and expiration
        delay.setTxCooldown(COOLDOWN);
        delay.setTxExpiration(EXPIRATION);

        // 3. Register operator with role (validUntil=0 means no time bound)
        vm.prank(address(safe));
        module.addOperator(operator, ROLE_KEY, 0);

        // 4. Set up permissions in Roles: allow operator's role to call defiTarget.deposit
        roles.setPermission(ROLE_KEY, defiTarget, defiSelector, true);
    }

    /// @notice Full happy path: validate -> execute -> queue -> warp -> execute from queue
    function test_fullPipeline_happyPath() public {
        // 4. Operator signs UserOp
        bytes memory innerData = abi.encodeWithSelector(defiSelector, 1000);
        bytes memory execCalldata = abi.encodeWithSelector(
            module.executeUserOp.selector,
            defiTarget,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata);

        // 5. Validate UserOp (succeeds)
        vm.startPrank(entryPoint);
        uint256 validationResult = module.validateUserOp(userOp, userOpHash, 0);
        // H-03: result now packs validUntil; check authorizer bits (bottom 20 bytes) == 0
        assertEq(uint160(validationResult), 0, "Validation should succeed (authorizer=0)");

        // 6. Execute UserOp — routes through Roles (permission check passes) -> Delay (queued)
        module.executeUserOp(userOp, userOpHash);
        vm.stopPrank();

        // Verify Roles was called
        assertEq(roles.execCount(), 1, "Roles should be called once");
        assertEq(roles.lastExecTo(), defiTarget);

        // Verify tx was queued in Delay
        assertEq(delay.queueNonce(), 1, "One tx should be queued");
        assertEq(delay.txNonce(), 0, "No tx executed yet");

        // 7. Try to execute before cooldown — should revert
        vm.expectRevert(abi.encodeWithSelector(MockDelay.CooldownNotMet.selector, 0));
        delay.executeNextTx(defiTarget, 0, innerData, 0);

        // 8. Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Execute from Delay queue — should succeed and call Safe.execTransactionFromModule
        bool success = delay.executeNextTx(defiTarget, 0, innerData, 0);
        assertTrue(success, "Delay execution should succeed");

        // Verify Safe received the final execution
        assertEq(safe.lastExecTo(), defiTarget);
        assertEq(safe.lastExecData(), innerData);
        assertEq(safe.execFromModuleCount(), 1, "Safe should execute once");
        assertEq(delay.txNonce(), 1, "Delay nonce should advance");
    }

    /// @notice Owner cancels a queued transaction via Delay.setTxNonce
    function test_ownerCancellation() public {
        // Queue a transaction
        bytes memory innerData = abi.encodeWithSelector(defiSelector, 1000);
        bytes memory execCalldata = abi.encodeWithSelector(
            module.executeUserOp.selector,
            defiTarget,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata);

        vm.startPrank(entryPoint);
        module.validateUserOp(userOp, userOpHash, 0);
        module.executeUserOp(userOp, userOpHash);
        vm.stopPrank();

        assertEq(delay.queueNonce(), 1, "One tx queued");

        // 9. Owner cancels via Delay.setTxNonce (advances nonce past the queued tx)
        delay.setTxNonce(1);

        assertEq(delay.txNonce(), 1, "Nonce should be advanced");

        // 10. Warp past cooldown — but tx is cancelled (nonce advanced past it)
        vm.warp(block.timestamp + COOLDOWN + 1);

        // The execute should fail because txNonce (1) == queueNonce (1) — no tx to execute
        vm.expectRevert(abi.encodeWithSelector(MockDelay.TxNotQueued.selector, 1));
        delay.executeNextTx(defiTarget, 0, innerData, 0);

        // Safe should not have executed
        assertEq(safe.execFromModuleCount(), 0, "Safe should not execute cancelled tx");
    }

    /// @notice Roles rejects unauthorized target/selector
    function test_rolesRejectsUnauthorizedCall() public {
        address unauthorizedTarget = address(0xBAD);
        bytes4 unauthorizedSelector = bytes4(keccak256("steal()"));
        bytes memory innerData = abi.encodeWithSelector(unauthorizedSelector);

        bytes memory execCalldata = abi.encodeWithSelector(
            module.executeUserOp.selector,
            unauthorizedTarget,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata);

        vm.startPrank(entryPoint);
        module.validateUserOp(userOp, userOpHash, 0);

        // Roles should reject — unauthorized target/selector
        vm.expectRevert(
            abi.encodeWithSelector(MockRoles.PermissionDenied.selector, ROLE_KEY, unauthorizedTarget, unauthorizedSelector)
        );
        module.executeUserOp(userOp, userOpHash);
        vm.stopPrank();

        // Nothing should be queued in Delay
        assertEq(delay.queueNonce(), 0, "No tx should be queued");
    }

    /// @notice Unregistered operator cannot validate
    function test_unregisteredOperatorCannotValidate() public {
        uint256 unknownPk = 0xDEAD;
        bytes memory innerData = abi.encodeWithSelector(defiSelector, 100);
        bytes memory execCalldata = abi.encodeWithSelector(
            module.executeUserOp.selector,
            defiTarget,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(unknownPk, execCalldata);

        vm.prank(entryPoint);
        uint256 result = module.validateUserOp(userOp, userOpHash, 0);
        assertEq(result, 1, "Unregistered operator should fail validation");
    }

    /// @notice Multiple operations queued and executed in order
    function test_multipleOpsQueuedAndExecuted() public {
        // Queue two operations
        for (uint256 i = 0; i < 2; i++) {
            bytes memory innerData = abi.encodeWithSelector(defiSelector, 100 * (i + 1));
            bytes memory execCalldata = abi.encodeWithSelector(
                module.executeUserOp.selector,
                defiTarget,
                uint256(0),
                innerData
            );

            (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(
                operatorPk,
                abi.encodePacked(execCalldata, i) // make unique for different hash
            );
            // Need to use proper calldata for the module
            userOp.callData = execCalldata;

            vm.startPrank(entryPoint);
            module.validateUserOp(userOp, userOpHash, 0);
            module.executeUserOp(userOp, userOpHash);
            vm.stopPrank();
        }

        assertEq(delay.queueNonce(), 2, "Two txs should be queued");

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Execute first
        bytes memory firstData = abi.encodeWithSelector(defiSelector, 100);
        delay.executeNextTx(defiTarget, 0, firstData, 0);
        assertEq(delay.txNonce(), 1);

        // Execute second
        bytes memory secondData = abi.encodeWithSelector(defiSelector, 200);
        delay.executeNextTx(defiTarget, 0, secondData, 0);
        assertEq(delay.txNonce(), 2);

        assertEq(safe.execFromModuleCount(), 2, "Safe should execute both");
    }

    /// @notice Transaction expires after expiration period
    function test_txExpiresAfterExpiration() public {
        bytes memory innerData = abi.encodeWithSelector(defiSelector, 1000);
        bytes memory execCalldata = abi.encodeWithSelector(
            module.executeUserOp.selector,
            defiTarget,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata);

        vm.startPrank(entryPoint);
        module.validateUserOp(userOp, userOpHash, 0);
        module.executeUserOp(userOp, userOpHash);
        vm.stopPrank();

        // Warp past cooldown + expiration
        vm.warp(block.timestamp + COOLDOWN + EXPIRATION + 1);

        vm.expectRevert(abi.encodeWithSelector(MockDelay.TxExpired.selector, 0));
        delay.executeNextTx(defiTarget, 0, innerData, 0);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _createSignedUserOpWithCalldata(uint256 pk, bytes memory callData_)
        internal
        view
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        userOp = PackedUserOperation({
            sender: address(module),
            nonce: 0,
            initCode: "",
            callData: callData_,
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });

        userOpHash = keccak256(abi.encode("userOpHash", block.timestamp, callData_));

        // H-01: Sign the raw userOpHash (no eth_sign prefix)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
    }
}
