// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13 <0.9.0;

interface Vm {
    function envAddress(string calldata name) external view returns (address);
    function envUint(string calldata name) external view returns (uint256);
    function envBytes(string calldata name) external view returns (bytes memory);
    function envBytes32(string calldata name) external view returns (bytes32);
    function envOr(string calldata name, bytes calldata defaultValue)
        external
        view
        returns (bytes memory);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function chainId(uint256 newChainId) external;
    function etch(address target, bytes calldata code) external;
    function toString(uint256 value) external pure returns (string memory);
    function skip(bool skipTest) external;
    function prank(address sender) external;
    function assume(bool condition) external;
}

/// @dev Small, vendored compatibility surface used by the offline protected checks.
abstract contract Test {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function assertGt(uint256 left, uint256 right, string memory message) internal pure {
        require(left > right, message);
    }

    function assertLe(uint256 left, uint256 right, string memory message) internal pure {
        require(left <= right, message);
    }
}
