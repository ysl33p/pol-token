// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import {PolygonEcosystemToken} from "src/PolygonEcosystemToken.sol";
import {DefaultEmissionManager} from "src/DefaultEmissionManager.sol";
import {PolygonMigration} from "src/PolygonMigration.sol";
import {ERC20PresetMinterPauser} from "openzeppelin-contracts/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";
import {ProxyAdmin, TransparentUpgradeableProxy} from "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {Test} from "forge-std/Test.sol";

contract DefaultEmissionManagerTest is Test {
    error InvalidAddress();

    ERC20PresetMinterPauser public matic;
    PolygonEcosystemToken public polygon;
    PolygonMigration public migration;
    address public treasury;
    address public governance;
    address public stakeManager;
    DefaultEmissionManager public emissionManager;
    DefaultEmissionManager public emissionManagerImplementation;

    // precision accuracy due to log2 approximation is up to the first 5 digits
    uint256 private constant _MAX_PRECISION_DELTA = 1e13;

    string[] internal inputs = new string[](4);

    function setUp() external {
        treasury = makeAddr("treasury");
        stakeManager = makeAddr("stakeManager");
        governance = makeAddr("governance");
        emissionManagerImplementation = new DefaultEmissionManager();
        ProxyAdmin admin = new ProxyAdmin();
        emissionManager = DefaultEmissionManager(
            address(new TransparentUpgradeableProxy(address(emissionManagerImplementation), address(admin), ""))
        );
        matic = new ERC20PresetMinterPauser("Matic Token", "MATIC");
        migration = PolygonMigration(
            address(new TransparentUpgradeableProxy(address(new PolygonMigration()), address(admin), ""))
        );
        migration.initialize(address(matic));
        polygon = new PolygonEcosystemToken(address(migration), address(emissionManager), governance);
        migration.setPolygonToken(address(polygon)); // deployer sets token
        migration.transferOwnership(governance);
        vm.prank(governance);
        migration.acceptOwnership();
        emissionManager.initialize(address(polygon), address(migration), stakeManager, treasury, governance);
        // POL being emissionary, while MATIC having a constant supply,
        // the requirement of unmigrating POL to MATIC for StakeManager on each mint
        // is satisfied by a one-time transfer of MATIC to the migration contract
        // from POS bridge
        // note: this requirement will be changed in the future after the hub's launch
        matic.mint(address(migration), 3_000_000_000e18);

        inputs[0] = "node";
        inputs[1] = "test/util/calc.js";
    }

    function testRevert_Initialize() external {
        vm.expectRevert("Initializable: contract is already initialized");
        emissionManager.initialize(address(0), address(0), address(0), address(0), address(0));
    }

    function test_Deployment() external {
        assertEq(address(emissionManager.token()), address(polygon));
        assertEq(emissionManager.stakeManager(), stakeManager);
        assertEq(emissionManager.treasury(), treasury);
        assertEq(emissionManager.owner(), governance);
        assertEq(polygon.allowance(address(emissionManager), address(migration)), type(uint256).max);
        assertEq(emissionManager.START_SUPPLY(), 10_000_000_000e18);
        assertEq(polygon.totalSupply(), 10_000_000_000e18);
    }

    function test_InvalidDeployment(uint160 seed) external {
        address[5] memory params = [
            makeAddr("polygon"),
            makeAddr("migration"),
            makeAddr("stakeManager"),
            makeAddr("treasury"),
            makeAddr("governance")
        ];

        address proxy = address(new TransparentUpgradeableProxy(address(new DefaultEmissionManager()), msg.sender, ""));

        vm.prank(address(seed));
        vm.expectRevert();
        DefaultEmissionManager(proxy).initialize(params[0], params[1], params[2], params[3], params[4]);

        params[seed % params.length] = address(0); // any one is zero addr

        vm.expectRevert(InvalidAddress.selector);
        DefaultEmissionManager(proxy).initialize(params[0], params[1], params[2], params[3], params[4]);
    }

    function test_ImplementationCannotBeInitialized() external {
        vm.expectRevert("Initializable: contract is already initialized");
        DefaultEmissionManager(address(emissionManagerImplementation)).initialize(
            address(0),
            address(0),
            address(0),
            address(0),
            address(0)
        );
        vm.expectRevert("Initializable: contract is already initialized");
        DefaultEmissionManager(address(emissionManager)).initialize(
            address(0),
            address(0),
            address(0),
            address(0),
            address(0)
        );
    }

    function test_Mint() external {
        emissionManager.mint();
        // timeElapsed is zero, so no minting
        assertEq(polygon.balanceOf(stakeManager), 0);
        assertEq(matic.balanceOf(stakeManager), 0);
        assertEq(polygon.balanceOf(treasury), 0);
    }

    function test_MintDelay(uint128 delay) external {
        vm.assume(delay <= 10 * 365 days);

        uint256 initialTotalSupply = polygon.totalSupply();

        skip(delay);

        emissionManager.mint();

        inputs[2] = vm.toString(delay);
        inputs[3] = vm.toString(initialTotalSupply);
        uint256 newSupply = abi.decode(vm.ffi(inputs), (uint256));

        assertApproxEqAbs(newSupply, polygon.totalSupply(), _MAX_PRECISION_DELTA);
        assertEq(matic.balanceOf(stakeManager), (polygon.totalSupply() - initialTotalSupply) / 2);
        assertEq(polygon.balanceOf(stakeManager), 0);
        assertEq(polygon.balanceOf(treasury), (polygon.totalSupply() - initialTotalSupply) / 2);
    }

    function test_MintDelayTwice(uint128 delay) external {
        vm.assume(delay <= 5 * 365 days && delay > 0);

        uint256 initialTotalSupply = polygon.totalSupply();

        skip(delay);
        emissionManager.mint();

        inputs[2] = vm.toString(delay);
        inputs[3] = vm.toString(initialTotalSupply);
        uint256 newSupply = abi.decode(vm.ffi(inputs), (uint256));

        assertApproxEqAbs(newSupply, polygon.totalSupply(), _MAX_PRECISION_DELTA);
        uint256 balance = (polygon.totalSupply() - initialTotalSupply) / 2;
        assertEq(matic.balanceOf(stakeManager), balance);
        assertEq(polygon.balanceOf(stakeManager), 0);
        assertEq(polygon.balanceOf(treasury), balance);

        initialTotalSupply = polygon.totalSupply(); // for the new run
        skip(delay);
        emissionManager.mint();

        inputs[2] = vm.toString(delay * 2);
        inputs[3] = vm.toString(initialTotalSupply);
        newSupply = abi.decode(vm.ffi(inputs), (uint256));

        assertApproxEqAbs(newSupply, polygon.totalSupply(), _MAX_PRECISION_DELTA);
        balance += (polygon.totalSupply() - initialTotalSupply) / 2;
        assertEq(matic.balanceOf(stakeManager), balance);
        assertEq(polygon.balanceOf(stakeManager), 0);
        assertEq(polygon.balanceOf(treasury), balance);
    }

    function test_MintDelayAfterNCycles(uint128 delay, uint8 cycles) external {
        vm.assume(delay * uint256(cycles) <= 10 * 365 days && delay > 0 && cycles < 30);

        uint256 balance;

        for (uint256 cycle; cycle < cycles; cycle++) {
            uint256 initialTotalSupply = polygon.totalSupply();

            skip(delay);
            emissionManager.mint();

            inputs[2] = vm.toString(delay * (cycle + 1));
            inputs[3] = vm.toString(initialTotalSupply);
            uint256 newSupply = abi.decode(vm.ffi(inputs), (uint256));

            assertApproxEqAbs(newSupply, polygon.totalSupply(), _MAX_PRECISION_DELTA);
            balance += (polygon.totalSupply() - initialTotalSupply) / 2;
            assertEq(matic.balanceOf(stakeManager), balance);
            assertEq(polygon.balanceOf(stakeManager), 0);
            assertEq(polygon.balanceOf(treasury), balance);
        }
    }
}