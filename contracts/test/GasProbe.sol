// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @dev Test helper: measures the gas a view call uses in a single execution (eth_call),
///      instead of eth_estimateGas, which runs the call several times.
contract GasProbe {
    function measure(address target, bytes calldata data) external view returns (uint256 used, bool ok) {
        uint256 before = gasleft();
        (ok,) = target.staticcall(data);
        used = before - gasleft();
    }
}
