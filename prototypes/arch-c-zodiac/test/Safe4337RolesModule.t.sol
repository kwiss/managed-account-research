// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Safe4337RolesModule} from "../src/modules/Safe4337RolesModule.sol";
import {ISafe4337RolesModule} from "../src/interfaces/ISafe4337RolesModule.sol";
import {PackedUserOperation} from "../src/types/PackedUserOperation.sol";
import {MockSafe} from "./mocks/MockSafe.sol";
import {MockRoles} from "./mocks/MockRoles.sol";

contract Safe4337RolesModuleTest is Test {
    Safe4337RolesModule public module;
    MockSafe public safe;

    address public entryPoint = address(0xE1);
    address public rolesModule = address(0xA1);

    // Operator keypair
    uint256 internal operatorPk = 0xA11CE;
    address internal operator;

    uint16 internal constant ROLE_KEY = 1;

    function setUp() public {
        operator = vm.addr(operatorPk);

        safe = new MockSafe();
        module = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            rolesModule
        );

        // Register operator via Safe (validUntil=0 means no time bound)
        vm.prank(address(safe));
        module.addOperator(operator, ROLE_KEY, 0);
    }

    // ─── Operator Management ─────────────────────────────────────────

    function test_addOperator_succeeds_when_called_from_safe() public {
        address newOperator = address(0xBEEF);

        vm.prank(address(safe));
        module.addOperator(newOperator, 2, 0);

        (address op, uint16 roleKey, bool active, uint48 validUntil) = module.operators(newOperator);
        assertEq(op, newOperator);
        assertEq(roleKey, 2);
        assertTrue(active);
        assertEq(validUntil, 0);
    }

    function test_addOperator_emits_event() public {
        address newOperator = address(0xBEEF);

        vm.expectEmit(true, false, false, true);
        emit ISafe4337RolesModule.OperatorAdded(newOperator, 2, 0);

        vm.prank(address(safe));
        module.addOperator(newOperator, 2, 0);
    }

    function test_addOperator_reverts_when_called_from_non_safe() public {
        vm.expectRevert(Safe4337RolesModule.OnlySafe.selector);
        module.addOperator(address(0xBEEF), 2, 0);
    }

    function test_addOperator_reverts_for_zero_address() public {
        vm.prank(address(safe));
        vm.expectRevert(Safe4337RolesModule.ZeroAddress.selector);
        module.addOperator(address(0), 1, 0);
    }

    function test_addOperator_reverts_if_already_registered() public {
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(Safe4337RolesModule.OperatorAlreadyExists.selector, operator));
        module.addOperator(operator, 2, 0);
    }

    function test_removeOperator_succeeds_and_deactivates() public {
        vm.prank(address(safe));
        module.removeOperator(operator);

        (, , bool active,) = module.operators(operator);
        assertFalse(active);
    }

    function test_removeOperator_emits_event() public {
        vm.expectEmit(true, false, false, false);
        emit ISafe4337RolesModule.OperatorRemoved(operator);

        vm.prank(address(safe));
        module.removeOperator(operator);
    }

    function test_removeOperator_reverts_for_non_safe() public {
        vm.expectRevert(Safe4337RolesModule.OnlySafe.selector);
        module.removeOperator(operator);
    }

    function test_removeOperator_reverts_for_inactive_operator() public {
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(ISafe4337RolesModule.UnauthorizedOperator.selector, address(0xDEAD)));
        module.removeOperator(address(0xDEAD));
    }

    // ─── Validation ──────────────────────────────────────────────────

    function test_validateUserOp_returns_success_for_valid_operator() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        vm.prank(entryPoint);
        uint256 result = module.validateUserOp(userOp, userOpHash, 0);

        // H-03: Return value now includes validUntil packed per ERC-4337 spec
        // For validUntil=0, we use type(uint48).max => validUntil = 0xFFFFFFFFFFFF
        // validationData = 0 (authorizer) | (validUntil << 160) | (validAfter << 208)
        // With validAfter=0, validUntil=type(uint48).max:
        uint48 expectedUntil = type(uint48).max;
        uint256 expected = uint256(expectedUntil) << 160;
        assertEq(result, expected);
    }

    function test_validateUserOp_emits_event() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        vm.expectEmit(true, true, false, false);
        emit ISafe4337RolesModule.UserOpValidated(operator, userOpHash);

        vm.prank(entryPoint);
        module.validateUserOp(userOp, userOpHash, 0);
    }

    function test_validateUserOp_returns_1_for_unregistered_operator() public {
        uint256 unknownPk = 0xDEAD;
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(unknownPk);

        vm.prank(entryPoint);
        uint256 result = module.validateUserOp(userOp, userOpHash, 0);

        assertEq(result, 1); // SIG_VALIDATION_FAILED
    }

    function test_validateUserOp_returns_1_for_invalid_signature() public {
        bytes32 userOpHash = keccak256("test");
        PackedUserOperation memory userOp = _createEmptyUserOp();
        // Invalid signature — wrong length
        userOp.signature = hex"deadbeef";

        vm.prank(entryPoint);
        uint256 result = module.validateUserOp(userOp, userOpHash, 0);

        assertEq(result, 1); // SIG_VALIDATION_FAILED
    }

    function test_validateUserOp_returns_1_for_removed_operator() public {
        // Remove the operator first
        vm.prank(address(safe));
        module.removeOperator(operator);

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        vm.prank(entryPoint);
        uint256 result = module.validateUserOp(userOp, userOpHash, 0);

        assertEq(result, 1); // SIG_VALIDATION_FAILED
    }

    function test_validateUserOp_reverts_for_non_entrypoint() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        vm.expectRevert(Safe4337RolesModule.OnlyEntryPoint.selector);
        module.validateUserOp(userOp, userOpHash, 0);
    }

    function test_validateUserOp_prefunds_entrypoint() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        // Fund the module
        vm.deal(address(module), 1 ether);

        uint256 entryPointBalBefore = entryPoint.balance;

        vm.prank(entryPoint);
        module.validateUserOp(userOp, userOpHash, 0.5 ether);

        assertEq(entryPoint.balance, entryPointBalBefore + 0.5 ether);
    }

    // ─── H-03: validUntil ─────────────────────────────────────────────

    function test_validateUserOp_packs_validUntil_from_config() public {
        // Register operator with a specific validUntil
        address timedOperator = vm.addr(0xBEEF1);
        uint48 validUntil = uint48(block.timestamp + 1 hours);

        vm.prank(address(safe));
        module.addOperator(timedOperator, ROLE_KEY, validUntil);

        // Sign a UserOp as timedOperator
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(0xBEEF1);

        vm.prank(entryPoint);
        uint256 result = module.validateUserOp(userOp, userOpHash, 0);

        // validationData = authorizer(0) | (validUntil << 160) | (validAfter(0) << 208)
        uint256 expected = uint256(validUntil) << 160;
        assertEq(result, expected);
    }

    // ─── H-02: Cross-chain replay protection ──────────────────────────

    function test_validateUserOp_reverts_on_chain_id_mismatch() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        // Change chain ID
        vm.chainId(999);

        vm.prank(entryPoint);
        vm.expectRevert(ISafe4337RolesModule.ChainIdMismatch.selector);
        module.validateUserOp(userOp, userOpHash, 0);
    }

    // ─── C-01: Transient storage clearing ─────────────────────────────

    function test_executeUserOp_reverts_on_hash_mismatch() public {
        MockRoles mockRoles = new MockRoles();
        address target = address(0xCAFE);
        bytes4 selector = bytes4(keccak256("doSomething(uint256)"));
        bytes memory innerData = abi.encodeWithSelector(selector, 42);

        mockRoles.setPermission(ROLE_KEY, target, selector, true);

        Safe4337RolesModule mod = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(mockRoles)
        );

        vm.prank(address(safe));
        mod.addOperator(operator, ROLE_KEY, 0);

        // Create two different UserOps
        bytes memory execCalldata = abi.encodeWithSelector(
            mod.executeUserOp.selector,
            target,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata, address(mod));

        // Validate with one hash
        vm.startPrank(entryPoint);
        mod.validateUserOp(userOp, userOpHash, 0);

        // Try to execute with a different hash — should revert
        bytes32 wrongHash = keccak256("wrong");
        vm.expectRevert(ISafe4337RolesModule.UserOpHashMismatch.selector);
        mod.executeUserOp(userOp, wrongHash);
        vm.stopPrank();
    }

    function test_executeUserOp_clears_transient_storage() public {
        MockRoles mockRoles = new MockRoles();
        address target = address(0xCAFE);
        bytes4 selector = bytes4(keccak256("doSomething(uint256)"));
        bytes memory innerData = abi.encodeWithSelector(selector, 42);

        mockRoles.setPermission(ROLE_KEY, target, selector, true);

        Safe4337RolesModule mod = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(mockRoles)
        );

        vm.prank(address(safe));
        mod.addOperator(operator, ROLE_KEY, 0);

        bytes memory execCalldata = abi.encodeWithSelector(
            mod.executeUserOp.selector,
            target,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata, address(mod));

        vm.startPrank(entryPoint);
        mod.validateUserOp(userOp, userOpHash, 0);
        mod.executeUserOp(userOp, userOpHash);

        // Attempt to execute again — should revert because transient storage is cleared
        vm.expectRevert(ISafe4337RolesModule.UserOpHashMismatch.selector);
        mod.executeUserOp(userOp, userOpHash);
        vm.stopPrank();
    }

    // ─── Execution Routing ─────────────────────────────────────────────

    function test_executeUserOp_routes_to_roles_module() public {
        // Deploy a real MockRoles
        MockRoles mockRoles = new MockRoles();
        address target = address(0xCAFE);
        bytes4 selector = bytes4(keccak256("doSomething(uint256)"));
        bytes memory innerData = abi.encodeWithSelector(selector, 42);

        // Allow the function in MockRoles for ROLE_KEY
        mockRoles.setPermission(ROLE_KEY, target, selector, true);

        // Create module with MockRoles (no delayModule param)
        Safe4337RolesModule mod = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(mockRoles)
        );

        // Register operator
        vm.prank(address(safe));
        mod.addOperator(operator, ROLE_KEY, 0);

        // Create UserOp with execution calldata
        bytes memory execCalldata = abi.encodeWithSelector(
            mod.executeUserOp.selector,
            target,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata, address(mod));

        // Validate then execute (same tx = transient storage works)
        vm.startPrank(entryPoint);
        mod.validateUserOp(userOp, userOpHash, 0);
        mod.executeUserOp(userOp, userOpHash);
        vm.stopPrank();

        // Verify Roles was called with correct parameters
        assertEq(mockRoles.lastExecTo(), target);
        assertEq(mockRoles.lastExecValue(), 0);
        assertEq(mockRoles.lastExecData(), innerData);
        assertEq(mockRoles.lastExecRoleKey(), ROLE_KEY);
        assertEq(mockRoles.execCount(), 1);
    }

    function test_executeUserOp_uses_correct_roleKey() public {
        MockRoles mockRoles = new MockRoles();
        address target = address(0xCAFE);
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));
        bytes memory innerData = abi.encodeWithSelector(selector, address(0x1), 100);

        uint16 customRoleKey = 42;
        mockRoles.setPermission(customRoleKey, target, selector, true);

        Safe4337RolesModule mod = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(mockRoles)
        );

        // Register operator with custom role key
        vm.prank(address(safe));
        mod.addOperator(operator, customRoleKey, 0);

        bytes memory execCalldata = abi.encodeWithSelector(
            mod.executeUserOp.selector,
            target,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata, address(mod));

        vm.startPrank(entryPoint);
        mod.validateUserOp(userOp, userOpHash, 0);
        mod.executeUserOp(userOp, userOpHash);
        vm.stopPrank();

        assertEq(mockRoles.lastExecRoleKey(), customRoleKey);
    }

    function test_executeUserOp_reverts_when_roles_rejects() public {
        MockRoles mockRoles = new MockRoles();
        address target = address(0xCAFE);
        bytes4 selector = bytes4(keccak256("forbidden()"));
        bytes memory innerData = abi.encodeWithSelector(selector);

        // Do NOT set permission — Roles should reject

        Safe4337RolesModule mod = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(mockRoles)
        );

        vm.prank(address(safe));
        mod.addOperator(operator, ROLE_KEY, 0);

        bytes memory execCalldata = abi.encodeWithSelector(
            mod.executeUserOp.selector,
            target,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata, address(mod));

        vm.startPrank(entryPoint);
        mod.validateUserOp(userOp, userOpHash, 0);

        // Should revert because the target/selector is not allowed in MockRoles
        vm.expectRevert(abi.encodeWithSelector(MockRoles.PermissionDenied.selector, ROLE_KEY, target, selector));
        mod.executeUserOp(userOp, userOpHash);
        vm.stopPrank();
    }

    function test_executeUserOp_emits_event() public {
        MockRoles mockRoles = new MockRoles();
        address target = address(0xCAFE);
        bytes4 selector = bytes4(keccak256("doSomething(uint256)"));
        bytes memory innerData = abi.encodeWithSelector(selector, 42);

        mockRoles.setPermission(ROLE_KEY, target, selector, true);

        Safe4337RolesModule mod = new Safe4337RolesModule(
            address(safe),
            entryPoint,
            address(mockRoles)
        );

        vm.prank(address(safe));
        mod.addOperator(operator, ROLE_KEY, 0);

        bytes memory execCalldata = abi.encodeWithSelector(
            mod.executeUserOp.selector,
            target,
            uint256(0),
            innerData
        );

        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOpWithCalldata(operatorPk, execCalldata, address(mod));

        vm.startPrank(entryPoint);
        mod.validateUserOp(userOp, userOpHash, 0);

        vm.expectEmit(true, true, false, false);
        emit ISafe4337RolesModule.UserOpExecuted(operator, userOpHash);
        mod.executeUserOp(userOp, userOpHash);
        vm.stopPrank();
    }

    function test_executeUserOp_reverts_for_non_entrypoint() public {
        (PackedUserOperation memory userOp, bytes32 userOpHash) = _createSignedUserOp(operatorPk);

        vm.expectRevert(Safe4337RolesModule.OnlyEntryPoint.selector);
        module.executeUserOp(userOp, userOpHash);
    }

    // ─── M-01: Constructor zero address validation ──────────────────

    function test_constructor_reverts_for_zero_rolesModule() public {
        vm.expectRevert(Safe4337RolesModule.ZeroAddress.selector);
        new Safe4337RolesModule(address(safe), entryPoint, address(0));
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _createEmptyUserOp() internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(module),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: ""
        });
    }

    function _createSignedUserOp(uint256 pk)
        internal
        view
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        userOp = _createEmptyUserOp();
        userOpHash = keccak256(abi.encode("userOpHash", block.timestamp));

        // H-01: Sign the raw userOpHash (no eth_sign prefix)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, userOpHash);
        userOp.signature = abi.encodePacked(r, s, v);
    }

    function _createSignedUserOpWithCalldata(uint256 pk, bytes memory callData_, address sender_)
        internal
        view
        returns (PackedUserOperation memory userOp, bytes32 userOpHash)
    {
        userOp = PackedUserOperation({
            sender: sender_,
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
