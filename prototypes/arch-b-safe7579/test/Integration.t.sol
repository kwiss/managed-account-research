// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ManagedAccountTimelockHook} from "../src/hooks/ManagedAccountTimelockHook.sol";
import {IManagedAccountTimelockHook} from "../src/hooks/IManagedAccountTimelockHook.sol";
import {HookMultiPlexer} from "../src/hooks/HookMultiPlexer.sol";
import {UniswapSwapPolicy} from "../src/policies/UniswapSwapPolicy.sol";
import {AaveSupplyPolicy} from "../src/policies/AaveSupplyPolicy.sol";
import {ApprovalPolicy} from "../src/policies/ApprovalPolicy.sol";
import {ManagedAccountSafeFactory, ISafe7579Launchpad} from
    "../src/factory/ManagedAccountSafeFactory.sol";

/// @dev Mock Safe for integration testing — also serves as the account (msg.sender)
contract IntegrationMockSafe {
    mapping(address => bool) public owners;

    constructor(address[] memory _owners) {
        for (uint256 i = 0; i < _owners.length; i++) {
            owners[_owners[i]] = true;
        }
    }

    function isOwner(address owner) external view returns (bool) {
        return owners[owner];
    }
}

/// @dev Mock SafeProxyFactory for integration testing
contract IntegrationMockSafeProxyFactory {
    function createProxyWithNonce(address, bytes memory, uint256) external pure returns (address) {
        return address(0);
    }

    function proxyCreationCode() external pure returns (bytes memory) {
        return hex"6080604052";
    }
}

/// @dev Mock Safe7579Launchpad for integration testing
contract IntegrationMockSafe7579Launchpad {
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
        return abi.encode(safe7579, ownableValidator, ownableValidatorInitData, executors.length, hooks.length);
    }
}

/// @title IntegrationTest
/// @notice End-to-end integration test simulating the complete Safe + 7579 delegation flow
contract IntegrationTest is Test {
    // ─── Contracts ───────────────────────────────────────────────────────────

    ManagedAccountTimelockHook public timelockHook;
    HookMultiPlexer public hookMultiplexer;
    UniswapSwapPolicy public swapPolicy;
    AaveSupplyPolicy public supplyPolicy;
    ApprovalPolicy public approvalPolicy;
    ManagedAccountSafeFactory public factory;
    IntegrationMockSafe public mockSafe;

    // ─── Addresses ───────────────────────────────────────────────────────────

    address public owner1 = address(0x10);
    address public owner2 = address(0x11);
    address public operator = address(0x20);
    address public account; // simulates the Safe account — now IS the mockSafe

    address public uniRouter = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public aavePool = address(0xAA7E);
    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint256 public constant COOLDOWN = 1 hours;
    uint256 public constant EXPIRATION = 24 hours;

    bytes4 public constant EXECUTE_SELECTOR = bytes4(keccak256("execute(bytes32,bytes)"));
    bytes4 public constant SWAP_SELECTOR =
        bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"));
    bytes4 public constant SUPPLY_SELECTOR = bytes4(keccak256("supply(address,uint256,address,uint16)"));
    bytes4 public constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));

    function setUp() public {
        // 1. Deploy all contracts
        timelockHook = new ManagedAccountTimelockHook();
        hookMultiplexer = new HookMultiPlexer();
        swapPolicy = new UniswapSwapPolicy();
        supplyPolicy = new AaveSupplyPolicy();
        approvalPolicy = new ApprovalPolicy();

        // Deploy mock infrastructure
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;
        mockSafe = new IntegrationMockSafe(owners);

        IntegrationMockSafeProxyFactory mockProxyFactory = new IntegrationMockSafeProxyFactory();
        IntegrationMockSafe7579Launchpad mockLaunchpad = new IntegrationMockSafe7579Launchpad();

        factory = new ManagedAccountSafeFactory(
            address(0x1), // safeSingleton
            address(0x2), // safe7579
            address(mockLaunchpad),
            address(mockProxyFactory),
            address(0x3), // smartSession
            address(hookMultiplexer),
            address(timelockHook),
            address(0x6) // ownableValidator
        );

        // Use the mockSafe as the account so isOwner works properly
        // (safeAccount = msg.sender = account in the new design)
        account = address(mockSafe);

        // 2. Configure timelock on mock Safe
        // H-02/M-05: onInstall now only takes (cooldown, expiration), uses msg.sender as safeAccount
        vm.prank(account);
        timelockHook.onInstall(abi.encode(COOLDOWN, EXPIRATION));

        // 3. Install HookMultiPlexer with TimelockHook as sub-hook
        address[] memory initialHooks = new address[](1);
        initialHooks[0] = address(timelockHook);
        vm.prank(account);
        hookMultiplexer.onInstall(abi.encode(initialHooks));

        // 4. Configure policies
        vm.startPrank(account);

        // Swap policy: WETH -> USDC via Uniswap, recipient must be account, max 10 ETH/day
        swapPolicy.setSwapConfig(
            uniRouter,
            UniswapSwapPolicy.SwapConfig({
                tokenIn: weth,
                tokenOut: usdc,
                recipient: account,
                feeTier: 3000,
                maxDailyVolume: 10 ether,
                active: true
            })
        );

        // Supply policy: USDC to Aave, onBehalfOf must be account, max 1M USDC/day
        supplyPolicy.setSupplyConfig(
            aavePool,
            AaveSupplyPolicy.SupplyConfig({asset: usdc, onBehalfOf: account, maxDailyVolume: 1_000_000e6, active: true})
        );

        // Approval policy: USDC approved for Aave pool, max 500K
        approvalPolicy.setApprovalConfig(
            usdc, ApprovalPolicy.ApprovalConfig({spender: aavePool, maxAmount: 500_000e6, active: true})
        );

        // Set immediate selector: approve(address,uint256) on USDC bypasses timelock
        timelockHook.setImmediateSelector(usdc, APPROVE_SELECTOR, true);

        vm.stopPrank();
    }

    // ─── Helper ──────────────────────────────────────────────────────────────

    function _buildExecuteCalldata(address target, uint256 value, bytes memory callData)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 mode = bytes32(0);
        bytes memory executionCalldata = abi.encodePacked(target, value, callData);
        return abi.encodeWithSelector(EXECUTE_SELECTOR, mode, executionCalldata);
    }

    // ─── Test 1: Deploy all contracts successfully ───────────────────────────

    function test_integration_allContractsDeployed() public view {
        assertTrue(address(timelockHook) != address(0));
        assertTrue(address(hookMultiplexer) != address(0));
        assertTrue(address(swapPolicy) != address(0));
        assertTrue(address(supplyPolicy) != address(0));
        assertTrue(address(approvalPolicy) != address(0));
        assertTrue(address(factory) != address(0));
    }

    // ─── Test 2: Factory generates initCode ──────────────────────────────────

    function test_integration_factoryGeneratesInitCode() public view {
        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;

        ManagedAccountSafeFactory.ImmediateSelector[] memory immSels =
            new ManagedAccountSafeFactory.ImmediateSelector[](1);
        immSels[0] = ManagedAccountSafeFactory.ImmediateSelector({target: usdc, selector: APPROVE_SELECTOR});

        ManagedAccountSafeFactory.DeploymentParams memory params = ManagedAccountSafeFactory.DeploymentParams({
            owners: owners,
            threshold: 1,
            timelockCooldown: COOLDOWN,
            timelockExpiration: EXPIRATION,
            immediateSelectors: immSels,
            salt: bytes32(uint256(1))
        });

        bytes memory initCode = factory.getInitCode(params);
        assertTrue(initCode.length > 20);

        address predicted = factory.predictAddress(params);
        assertTrue(predicted != address(0));
    }

    // ─── Test 3: Configure timelock on mock Safe ─────────────────────────────

    function test_integration_timelockConfigured() public view {
        IManagedAccountTimelockHook.TimelockConfig memory config = timelockHook.getTimelockConfig(account);
        assertEq(config.cooldown, COOLDOWN);
        assertEq(config.expiration, EXPIRATION);
        // safeAccount is now msg.sender (= account = mockSafe)
        assertEq(config.safeAccount, account);
    }

    function test_integration_hookMultiplexerConfigured() public view {
        address[] memory hooks = hookMultiplexer.getHooks(account);
        assertEq(hooks.length, 1);
        assertEq(hooks[0], address(timelockHook));
    }

    // ─── Test 4: Owner bypass ────────────────────────────────────────────────

    function test_integration_ownerBypass() public {
        bytes memory swapCalldata = abi.encodeWithSelector(SWAP_SELECTOR, weth, usdc, uint24(3000), account, 1 ether, 0, 0);
        bytes memory msgData = _buildExecuteCalldata(uniRouter, 0, swapCalldata);

        // Owner can execute immediately through the timelock hook
        vm.prank(account);
        bytes memory hookData = timelockHook.preCheck(owner1, 0, msgData);
        // Owner bypass returns abi.encode(false) -- no postCheck needed
        assertEq(abi.decode(hookData, (bool)), false);

        // Also test owner2 bypass
        vm.prank(account);
        bytes memory hookData2 = timelockHook.preCheck(owner2, 0, msgData);
        assertEq(abi.decode(hookData2, (bool)), false);
    }

    // ─── Test 5: Operator queue + execute flow ──────────────────────────────

    function test_integration_operatorQueueAndExecute() public {
        bytes memory swapCalldata = abi.encodeWithSelector(SWAP_SELECTOR, weth, usdc, uint24(3000), account, 1 ether, 0, 0);
        bytes memory msgData = _buildExecuteCalldata(uniRouter, 0, swapCalldata);

        // H-03: Use abi.encode
        bytes32 opHash = keccak256(abi.encode(account, operator, msgData));

        // Step 1: Queue the operation (C-01: must be operator or account)
        vm.prank(operator);
        timelockHook.queueOperation(account, operator, msgData);

        // Step 2: Verify it's queued
        IManagedAccountTimelockHook.QueuedOperation memory op = timelockHook.getQueuedOperation(account, opHash);
        assertEq(op.queuedAt, block.timestamp);
        assertFalse(op.consumed);

        // Step 3: Operator can't execute yet (cooldown)
        vm.prank(account);
        vm.expectRevert();
        timelockHook.preCheck(operator, 0, msgData);

        // Step 4: Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Step 5: Operator can now execute
        vm.prank(account);
        bytes memory hookData = timelockHook.preCheck(operator, 0, msgData);
        assertEq(abi.decode(hookData, (bool)), true);

        // Step 6: Verify consumed
        op = timelockHook.getQueuedOperation(account, opHash);
        assertTrue(op.consumed);

        // Step 7: Validate the swap via policy (H-01: must be called as account)
        vm.prank(account);
        assertTrue(swapPolicy.checkAction(account, uniRouter, 0, swapCalldata));
    }

    // ─── Test 6: Owner cancel flow ──────────────────────────────────────────

    function test_integration_ownerCancelsOperation() public {
        bytes memory swapCalldata = abi.encodeWithSelector(SWAP_SELECTOR, weth, usdc, uint24(3000), account, 1 ether, 0, 0);
        bytes memory msgData = _buildExecuteCalldata(uniRouter, 0, swapCalldata);
        bytes32 opHash = keccak256(abi.encode(account, operator, msgData));

        // Queue (C-01: as operator)
        vm.prank(operator);
        timelockHook.queueOperation(account, operator, msgData);

        // Owner cancels (C-02: pass msgSender = owner1)
        vm.prank(account);
        timelockHook.cancelExecution(owner1, opHash);

        // Verify cancelled
        IManagedAccountTimelockHook.QueuedOperation memory op = timelockHook.getQueuedOperation(account, opHash);
        assertTrue(op.consumed);

        // Operator can't execute after cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IManagedAccountTimelockHook.OperationNotFound.selector, opHash));
        timelockHook.preCheck(operator, 0, msgData);
    }

    // ─── Test 7: Immediate selector bypass ──────────────────────────────────

    function test_integration_immediateSelectorBypass() public {
        // approve(address,uint256) on USDC was set as immediate in setUp
        bytes memory approveCalldata = abi.encodeWithSelector(APPROVE_SELECTOR, aavePool, 100_000e6);
        bytes memory msgData = _buildExecuteCalldata(usdc, 0, approveCalldata);

        // Operator can execute immediately (no queueing needed)
        vm.prank(account);
        bytes memory hookData = timelockHook.preCheck(operator, 0, msgData);
        assertEq(abi.decode(hookData, (bool)), false); // bypass returns false hookData

        // Also validate via approval policy (view, no access control needed)
        assertTrue(approvalPolicy.checkAction(account, usdc, 0, approveCalldata));
    }

    // ─── Test 8: Full DeFi flow -- approve + supply ──────────────────────────

    function test_integration_fullDefiFlow() public {
        // Step 1: Approve USDC for Aave (immediate -- bypasses timelock)
        bytes memory approveCalldata = abi.encodeWithSelector(APPROVE_SELECTOR, aavePool, 100_000e6);
        bytes memory approveMsgData = _buildExecuteCalldata(usdc, 0, approveCalldata);

        vm.prank(account);
        timelockHook.preCheck(operator, 0, approveMsgData); // immediate, no revert

        // Validate approval (view, no access control)
        assertTrue(approvalPolicy.checkAction(account, usdc, 0, approveCalldata));

        // Step 2: Supply USDC to Aave (requires timelock)
        bytes memory supplyCalldata = abi.encodeWithSelector(SUPPLY_SELECTOR, usdc, 100_000e6, account, uint16(0));
        bytes memory supplyMsgData = _buildExecuteCalldata(aavePool, 0, supplyCalldata);

        // Queue (C-01: as operator)
        vm.prank(operator);
        timelockHook.queueOperation(account, operator, supplyMsgData);

        // Wait for cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Execute
        vm.prank(account);
        bytes memory hookData = timelockHook.preCheck(operator, 0, supplyMsgData);
        assertEq(abi.decode(hookData, (bool)), true);

        // Validate supply (H-01: must call as account)
        vm.prank(account);
        assertTrue(supplyPolicy.checkAction(account, aavePool, 0, supplyCalldata));
    }

    // ─── Test 9: Policy rejects invalid operation ────────────────────────────

    function test_integration_policyRejectsInvalidSwap() public {
        // Try swapping wrong token
        address wrongToken = address(0xBAD);
        bytes memory badSwapCalldata =
            abi.encodeWithSelector(SWAP_SELECTOR, wrongToken, usdc, uint24(3000), account, 1 ether, 0, 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UniswapSwapPolicy.InvalidTokenIn.selector, wrongToken, weth));
        swapPolicy.checkAction(account, uniRouter, 0, badSwapCalldata);
    }

    // ─── Test 10: Expired operation handling ─────────────────────────────────

    function test_integration_expiredOperation() public {
        bytes memory swapCalldata = abi.encodeWithSelector(SWAP_SELECTOR, weth, usdc, uint24(3000), account, 1 ether, 0, 0);
        bytes memory msgData = _buildExecuteCalldata(uniRouter, 0, swapCalldata);
        bytes32 opHash = keccak256(abi.encode(account, operator, msgData));

        uint256 queueTime = block.timestamp;
        vm.prank(operator);
        timelockHook.queueOperation(account, operator, msgData);

        // Warp past cooldown + expiration
        vm.warp(queueTime + COOLDOWN + EXPIRATION + 1);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationExpired.selector, opHash, queueTime + COOLDOWN + EXPIRATION
            )
        );
        timelockHook.preCheck(operator, 0, msgData);
    }
}
