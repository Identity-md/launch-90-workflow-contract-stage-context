// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pledge} from "../src/Pledge.sol";
import {HabitPledge, IERC20} from "../src/HabitPledge.sol";

interface Vm {
    function prank(address sender) external;
    function startPrank(address sender) external;
    function warp(uint256 timestamp) external;
    function expectRevert(bytes4 selector) external;
}

contract HabitPledgeTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ALICE = address(0xA11CE);
    address private constant BENEFICIARY = address(0xBEEF);
    Pledge private token;
    HabitPledge private habit;

    function setUp() public {
        token = new Pledge();
        habit = new HabitPledge(address(token));
        token.transfer(ALICE, 1_000 ether);
        vm.prank(ALICE);
        token.approve(address(habit), type(uint256).max);
    }

    function testTokenHasFixedSupplyAndStandardTransfers() public view {
        _assertEq(token.totalSupply(), 1_000_000_000 ether);
        _assertEq(token.balanceOf(address(this)), token.totalSupply() - 1_000 ether);
        _assertEq(token.decimals(), 18);
    }

    function testAllCheckInsReturnEntireStakeAtEndBoundary() public {
        uint256 id = _create(4, 400 ether);
        HabitPledge.Commitment memory pledge = habit.getPledge(id);
        for (uint256 week; week < 4; ++week) {
            vm.warp(uint256(pledge.startTime) + week * 7 days);
            vm.prank(ALICE);
            habit.checkIn(id);
        }

        vm.warp(habit.endTime(id));
        habit.withdraw(id);
        _assertEq(token.balanceOf(ALICE), 1_000 ether);
        _assertEq(token.balanceOf(BENEFICIARY), 0);
        _assertEq(token.balanceOf(address(habit)), 0);
    }

    function testMissedWeeksForfeitExactSlicesAndConserveFunds() public {
        uint256 id = _create(4, 400 ether);
        HabitPledge.Commitment memory pledge = habit.getPledge(id);
        vm.prank(ALICE);
        habit.checkIn(id);
        vm.warp(uint256(pledge.startTime) + 2 * 7 days);
        vm.prank(ALICE);
        habit.checkIn(id);

        vm.warp(habit.endTime(id));
        habit.withdraw(id);
        _assertEq(token.balanceOf(ALICE), 800 ether);
        _assertEq(token.balanceOf(BENEFICIARY), 200 ether);
        _assertEq(token.balanceOf(address(habit)), 0);
    }

    function testRejectsInvalidCreationParametersAndWrongAmounts() public {
        vm.startPrank(ALICE);
        vm.expectRevert(HabitPledge.InvalidWeeks.selector);
        habit.createPledge("goal", 0, BENEFICIARY, 100 ether);
        vm.expectRevert(HabitPledge.InvalidBeneficiary.selector);
        habit.createPledge("goal", 2, ALICE, 100 ether);
        vm.expectRevert(HabitPledge.InvalidStake.selector);
        habit.createPledge("goal", 3, BENEFICIARY, 100 ether);
        vm.expectRevert(HabitPledge.EmptyGoal.selector);
        habit.createPledge("", 2, BENEFICIARY, 100 ether);
    }

    function testOnlyPledgerChecksInAndOnlyOncePerWindow() public {
        uint256 id = _create(2, 100 ether);
        vm.expectRevert(HabitPledge.Unauthorized.selector);
        habit.checkIn(id);
        vm.prank(ALICE);
        habit.checkIn(id);
        vm.prank(ALICE);
        vm.expectRevert(HabitPledge.AlreadyCheckedIn.selector);
        habit.checkIn(id);
    }

    function testTimingBoundariesAndEarlySettlement() public {
        uint256 id = _create(2, 100 ether);
        HabitPledge.Commitment memory pledge = habit.getPledge(id);
        vm.warp(uint256(pledge.startTime) + 7 days - 1);
        vm.prank(ALICE);
        habit.checkIn(id);
        vm.warp(uint256(pledge.startTime) + 7 days);
        vm.prank(ALICE);
        habit.checkIn(id);
        vm.expectRevert(HabitPledge.PledgeActive.selector);
        habit.withdraw(id);
        vm.warp(habit.endTime(id));
        vm.prank(ALICE);
        vm.expectRevert(HabitPledge.PledgeEnded.selector);
        habit.checkIn(id);
        habit.withdraw(id);
        vm.expectRevert(HabitPledge.AlreadySettled.selector);
        habit.withdraw(id);
    }

    function testFalseReturningTransferRevertsCreationWithoutAllocatingId() public {
        FalseToken falseToken = new FalseToken();
        HabitPledge target = new HabitPledge(address(falseToken));
        vm.expectRevert(HabitPledge.TransferFailed.selector);
        target.createPledge("goal", 1, BENEFICIARY, 1);
        _assertEq(target.nextPledgeId(), 0);
    }

    function testMaliciousTokenCannotReenterCreation() public {
        ReentrantToken malicious = new ReentrantToken();
        HabitPledge target = new HabitPledge(address(malicious));
        malicious.setTarget(
            address(target),
            abi.encodeCall(HabitPledge.createPledge, ("nested", uint8(1), BENEFICIARY, uint256(1)))
        );
        target.createPledge("outer", 1, BENEFICIARY, 1);
        _assertEq(malicious.callbackError(), HabitPledge.Reentrancy.selector);
        _assertEq(target.nextPledgeId(), 1);
    }

    function testSettlementTransferFailureRollsBackAndCanBeRetried() public {
        ToggleToken toggleToken = new ToggleToken();
        HabitPledge target = new HabitPledge(address(toggleToken));
        uint256 id = target.createPledge("goal", 1, BENEFICIARY, 1);
        vm.warp(target.endTime(id));
        toggleToken.setFail(true);
        vm.expectRevert(HabitPledge.TransferFailed.selector);
        target.withdraw(id);
        require(!target.getPledge(id).settled, "settlement was not rolled back");
        toggleToken.setFail(false);
        target.withdraw(id);
        require(target.getPledge(id).settled, "retry did not settle");
    }

    function _create(uint8 weeksCount, uint256 amount) private returns (uint256 id) {
        vm.prank(ALICE);
        id = habit.createPledge("Ship something useful", weeksCount, BENEFICIARY, amount);
    }

    function _assertEq(uint256 left, uint256 right) private pure {
        require(left == right, "not equal");
    }

    function _assertEq(bytes4 left, bytes4 right) private pure {
        require(left == right, "not equal");
    }
}

contract FalseToken is IERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}

contract ToggleToken is IERC20 {
    bool private fail;

    function setFail(bool value) external {
        fail = value;
    }

    function transfer(address, uint256) external view returns (bool) {
        return !fail;
    }

    function transferFrom(address, address, uint256) external view returns (bool) {
        return !fail;
    }
}

contract ReentrantToken is IERC20 {
    address private target;
    bytes private callback;
    bytes4 public callbackError;

    function setTarget(address target_, bytes calldata callback_) external {
        target = target_;
        callback = callback_;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        (bool ok, bytes memory data) = target.call(callback);
        require(!ok, "reentry unexpectedly succeeded");
        if (data.length >= 4) {
            callbackError = bytes4(data);
        }
        return true;
    }
}
