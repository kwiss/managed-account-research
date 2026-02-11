// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ManagedAccountSafeFactory, ISafeProxyFactory, ISafe7579Launchpad} from
    "../src/factory/ManagedAccountSafeFactory.sol";

/// @dev Mock SafeProxyFactory that returns deterministic proxy creation code
contract MockSafeProxyFactory {
    bytes public constant PROXY_CREATION_CODE = hex"6080604052";

    function createProxyWithNonce(address, bytes memory, uint256) external pure returns (address) {
        return address(0); // not used in these tests
    }

    function proxyCreationCode() external pure returns (bytes memory) {
        return PROXY_CREATION_CODE;
    }
}

/// @dev Mock Safe7579Launchpad that returns encoded init data
contract MockSafe7579Launchpad {
    function getInitCode(
        address safe7579,
        address ownableValidator,
        bytes memory ownableValidatorInitData,
        ISafe7579Launchpad.ModuleInit[] memory executors,
        ISafe7579Launchpad.ModuleInit[] memory,
        ISafe7579Launchpad.ModuleInit[] memory hooks,
        address[] memory,
        uint8
    ) external pure returns (bytes memory) {
        // Return a deterministic encoding of the key params for testing
        return abi.encode(safe7579, ownableValidator, ownableValidatorInitData, executors.length, hooks.length);
    }
}

contract ManagedAccountSafeFactoryTest is Test {
    ManagedAccountSafeFactory public factory;
    MockSafeProxyFactory public mockProxyFactory;
    MockSafe7579Launchpad public mockLaunchpad;

    address public safeSingleton = address(0x1);
    address public safe7579Addr = address(0x2);
    address public smartSessionAddr = address(0x3);
    address public hookMultiplexerAddr = address(0x4);
    address public timelockHookAddr = address(0x5);
    address public ownableValidatorAddr = address(0x6);

    function setUp() public {
        mockProxyFactory = new MockSafeProxyFactory();
        mockLaunchpad = new MockSafe7579Launchpad();

        factory = new ManagedAccountSafeFactory(
            safeSingleton,
            safe7579Addr,
            address(mockLaunchpad),
            address(mockProxyFactory),
            smartSessionAddr,
            hookMultiplexerAddr,
            timelockHookAddr,
            ownableValidatorAddr
        );
    }

    function _buildDefaultParams() internal pure returns (ManagedAccountSafeFactory.DeploymentParams memory) {
        address[] memory owners = new address[](2);
        owners[0] = address(0x10);
        owners[1] = address(0x11);

        ManagedAccountSafeFactory.ImmediateSelector[] memory immediateSelectors =
            new ManagedAccountSafeFactory.ImmediateSelector[](0);

        return ManagedAccountSafeFactory.DeploymentParams({
            owners: owners,
            threshold: 1,
            timelockCooldown: 1 hours,
            timelockExpiration: 24 hours,
            immediateSelectors: immediateSelectors,
            salt: bytes32(uint256(42))
        });
    }

    // ─── Test: Constructor ───────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(factory.safeSingleton(), safeSingleton);
        assertEq(factory.safe7579(), safe7579Addr);
        assertEq(factory.safe7579Launchpad(), address(mockLaunchpad));
        assertEq(factory.safeProxyFactory(), address(mockProxyFactory));
        assertEq(factory.smartSession(), smartSessionAddr);
        assertEq(factory.hookMultiplexer(), hookMultiplexerAddr);
        assertEq(factory.timelockHook(), timelockHookAddr);
        assertEq(factory.ownableValidator(), ownableValidatorAddr);
    }

    // ─── Test: getInitCode ───────────────────────────────────────────────────

    function test_getInitCode_returnsValidBytes() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();

        bytes memory initCode = factory.getInitCode(params);

        // initCode should start with the proxy factory address (20 bytes)
        assertTrue(initCode.length > 20);

        // First 20 bytes = proxy factory address
        address extractedFactory;
        assembly {
            extractedFactory := shr(96, mload(add(initCode, 32)))
        }
        assertEq(extractedFactory, address(mockProxyFactory));
    }

    function test_getInitCode_revert_noOwners() public {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();
        params.owners = new address[](0);

        vm.expectRevert(ManagedAccountSafeFactory.InvalidParams.selector);
        factory.getInitCode(params);
    }

    function test_getInitCode_revert_zeroThreshold() public {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();
        params.threshold = 0;

        vm.expectRevert(ManagedAccountSafeFactory.InvalidParams.selector);
        factory.getInitCode(params);
    }

    function test_getInitCode_revert_thresholdExceedsOwners() public {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();
        params.threshold = 5; // only 2 owners

        vm.expectRevert(ManagedAccountSafeFactory.InvalidParams.selector);
        factory.getInitCode(params);
    }

    // ─── Test: getSetupCalldata ──────────────────────────────────────────────

    function test_getSetupCalldata_returnsNonEmpty() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();

        bytes memory setupCalldata = factory.getSetupCalldata(params);
        assertTrue(setupCalldata.length > 0);
    }

    function test_getSetupCalldata_encodesModules() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();

        bytes memory setupCalldata = factory.getSetupCalldata(params);

        // The mock launchpad returns abi.encode(safe7579, ownableValidator, initData, executorCount, hookCount)
        (address decodedSafe7579, address decodedValidator,,, uint256 hookCount) =
            abi.decode(setupCalldata, (address, address, bytes, uint256, uint256));

        assertEq(decodedSafe7579, safe7579Addr);
        assertEq(decodedValidator, ownableValidatorAddr);
        assertEq(hookCount, 1); // HookMultiPlexer
    }

    // ─── Test: predictAddress ────────────────────────────────────────────────

    function test_predictAddress_returnsDeterministicAddress() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params = _buildDefaultParams();

        address predicted = factory.predictAddress(params);
        assertTrue(predicted != address(0));
    }

    function test_predictAddress_sameParamsSameAddress() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params1 = _buildDefaultParams();
        ManagedAccountSafeFactory.DeploymentParams memory params2 = _buildDefaultParams();

        address predicted1 = factory.predictAddress(params1);
        address predicted2 = factory.predictAddress(params2);

        assertEq(predicted1, predicted2);
    }

    function test_predictAddress_differentSaltDifferentAddress() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params1 = _buildDefaultParams();
        ManagedAccountSafeFactory.DeploymentParams memory params2 = _buildDefaultParams();
        params2.salt = bytes32(uint256(99));

        address predicted1 = factory.predictAddress(params1);
        address predicted2 = factory.predictAddress(params2);

        assertTrue(predicted1 != predicted2);
    }

    function test_predictAddress_differentOwnersDifferentAddress() public view {
        ManagedAccountSafeFactory.DeploymentParams memory params1 = _buildDefaultParams();
        ManagedAccountSafeFactory.DeploymentParams memory params2 = _buildDefaultParams();

        address[] memory differentOwners = new address[](1);
        differentOwners[0] = address(0x99);
        params2.owners = differentOwners;

        address predicted1 = factory.predictAddress(params1);
        address predicted2 = factory.predictAddress(params2);

        assertTrue(predicted1 != predicted2);
    }
}
