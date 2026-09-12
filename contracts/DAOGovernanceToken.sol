// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title DAOGovernanceToken
/// @notice Fixed-supply ERC20 governance token with EIP-2612 permits and historical vote
///         checkpoints. Supply is minted exactly once, in the constructor, to a bootstrap
///         recipient; there is no owner, no mint function and no snapshot function by design.
/// @dev ERC20Votes records checkpoints on delegation/transfers/mints/burns, so the Governor
///      reads historical voting power at proposal snapshot timepoints; current balances are
///      never consulted for an active vote. Permits and vote-checkpointing share the same
///      nonce namespace through the `nonces` override below (per EIP-2612 + ERC-6372).
contract DAOGovernanceToken is ERC20, ERC20Permit, ERC20Votes, ERC20Burnable {
    error InvalidInitialRecipient();

    constructor(string memory name_, string memory symbol_, address initialRecipient, uint256 initialSupply)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        if (initialRecipient == address(0)) revert InvalidInitialRecipient();
        _mint(initialRecipient, initialSupply);
    }

    /// @dev Resolve the ERC20/ERC20Votes state-update collision (checkpoint on every move).
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @dev Resolve the ERC20Permit/Nonces nonce collision so permits and delegations
    ///      consume the same counter without clobbering each other.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
