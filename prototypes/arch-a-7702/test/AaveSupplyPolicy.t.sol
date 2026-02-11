// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AaveSupplyPolicy} from "../src/policies/AaveSupplyPolicy.sol";

contract AaveSupplyPolicyTest is Test {
    AaveSupplyPolicy policy;

    address account = makeAddr("account");
    address target = makeAddr("aavePool");

    address constant USDC = address(0x2222);
    address constant DAI = address(0x3333);
    address constant UNKNOWN = address(0x9999);

    uint256 constant MAX_PER_TX = 10_000e6; // 10k USDC
    uint256 constant DAILY_LIMIT = 50_000e6; // 50k USDC

    // Aave V3 supply(address,uint256,address,uint16) selector
    bytes4 constant SUPPLY_SELECTOR = 0x617ba037;

    function setUp() public {
        policy = new AaveSupplyPolicy();

        address[] memory assets = new address[](2);
        assets[0] = USDC;
        assets[1] = DAI;

        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            allowedAssets: assets,
            requiredOnBehalfOf: account,
            maxSupplyPerTx: MAX_PER_TX,
            dailySupplyLimit: DAILY_LIMIT
        });

        // [C-01] Must call initializePolicy as the account itself
        vm.prank(account);
        policy.initializePolicy(account, config);
    }

    function _encodeSupply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(SUPPLY_SELECTOR, asset, amount, onBehalfOf, referralCode);
    }

    // ──────────────────── Valid Supply ────────────────────

    function test_validSupply() public {
        bytes memory data = _encodeSupply(USDC, 5000e6, account, 0);
        uint256 result = policy.checkAction(bytes32(0), account, target, 0, data);
        assertEq(result, 0);
    }

    // ──────────────────── Wrong Asset ────────────────────

    function test_wrongAsset_reverts() public {
        bytes memory data = _encodeSupply(UNKNOWN, 5000e6, account, 0);
        vm.expectRevert(
            abi.encodeWithSelector(AaveSupplyPolicy.AssetNotAllowed.selector, UNKNOWN)
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Wrong onBehalfOf ────────────────────

    function test_wrongOnBehalfOf_reverts() public {
        address attacker = makeAddr("attacker");
        bytes memory data = _encodeSupply(USDC, 5000e6, attacker, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveSupplyPolicy.InvalidOnBehalfOf.selector, attacker, account
            )
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Exceeds Per-Tx Limit ────────────────────

    function test_exceedsPerTxLimit_reverts() public {
        bytes memory data = _encodeSupply(USDC, MAX_PER_TX + 1, account, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveSupplyPolicy.ExceedsMaxSupplyPerTx.selector, MAX_PER_TX + 1, MAX_PER_TX
            )
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Exceeds Daily Limit ────────────────────

    function test_exceedsDailyLimit_reverts() public {
        // 5 successful supplies of 10k each = 50k (at limit)
        for (uint256 i; i < 5; ++i) {
            bytes memory data = _encodeSupply(USDC, MAX_PER_TX, account, 0);
            policy.checkAction(bytes32(0), account, target, 0, data);
        }
        assertEq(policy.getDailySupplyUsed(account), DAILY_LIMIT);

        // Next supply should fail
        bytes memory data = _encodeSupply(USDC, 1, account, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AaveSupplyPolicy.DailySupplyLimitExceeded.selector,
                DAILY_LIMIT + 1,
                DAILY_LIMIT
            )
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── ETH Value Not Allowed ────────────────────

    function test_ethValueNotAllowed_reverts() public {
        bytes memory data = _encodeSupply(USDC, 5000e6, account, 0);
        vm.expectRevert(AaveSupplyPolicy.NoEthValueAllowed.selector);
        policy.checkAction(bytes32(0), account, target, 1 ether, data);
    }

    // ──────────────────── Security Fix: C-01 Access Control ────────────────────

    function test_initializePolicy_onlyAccount() public {
        AaveSupplyPolicy freshPolicy = new AaveSupplyPolicy();
        address attacker = makeAddr("attacker");

        address[] memory assets = new address[](1);
        assets[0] = USDC;

        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            allowedAssets: assets,
            requiredOnBehalfOf: attacker,
            maxSupplyPerTx: type(uint256).max,
            dailySupplyLimit: type(uint256).max
        });

        vm.prank(attacker);
        vm.expectRevert(AaveSupplyPolicy.OnlyAccount.selector);
        freshPolicy.initializePolicy(account, config);
    }

    function test_initializePolicy_alreadyInitialized_reverts() public {
        address[] memory assets = new address[](1);
        assets[0] = USDC;

        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            allowedAssets: assets,
            requiredOnBehalfOf: account,
            maxSupplyPerTx: MAX_PER_TX,
            dailySupplyLimit: DAILY_LIMIT
        });

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AaveSupplyPolicy.AlreadyInitialized.selector, account));
        policy.initializePolicy(account, config);
    }
}
