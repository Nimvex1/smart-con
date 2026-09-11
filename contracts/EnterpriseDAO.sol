// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title EnterpriseDAO
/// @notice Modular Governor with snapshot-safe linear dynamic quorum and TimelockController execution.
/// @dev Voting is block-based because DAOGovernanceToken uses the default ERC-6372 block clock.
///      The quorum fraction linearly ramps between an immutable minimum and maximum (in basis
///      points) as the token's historical total supply grows between two immutable supply
///      thresholds, mirroring the "dynamic quorum" popularised by Nouns DAO style systems:
///      when supply is small, participation is scarce, so the quorum fraction is lowered;
///      as supply grows, the required fraction climbs toward its ceiling.
contract EnterpriseDAO is Governor, GovernorSettings, GovernorCountingSimple, GovernorVotes, GovernorTimelockControl {
    /// @notice Full construction parameters, packed to keep the constructor stack-safe
    ///         without requiring `via_ir` compilation.
    /// @custom:member name Governor registry name (e.g. "Enterprise DAO").
    /// @custom:member token Governance token implementing IVotes (ERC20Votes).
    /// @custom:member timelock TimelockController that executes approved proposals.
    /// @custom:member votingDelayBlocks Blocks between proposal creation and vote start.
    /// @custom:member votingPeriodBlocks Blocks during which voting is open.
    /// @custom:member proposalThreshold Token votes required to create a proposal.
    /// @custom:member quorumMinBps Minimum quorum fraction, in basis points of total supply.
    /// @custom:member quorumMaxBps Maximum quorum fraction, in basis points of total supply.
    /// @custom:member quorumLowSupplyThreshold Supply at or below which the fraction is minimal.
    /// @custom:member quorumHighSupplyThreshold Supply at or above which the fraction is maximal.
    /// @custom:member minProposalThreshold Governance-adjustable lower threshold bound.
    /// @custom:member maxProposalThreshold Governance-adjustable upper threshold bound.
    struct GovernorConfig {
        string name;
        IVotes token;
        TimelockController timelock;
        uint48 votingDelayBlocks;
        uint32 votingPeriodBlocks;
        uint256 proposalThreshold;
        uint256 quorumMinBps;
        uint256 quorumMaxBps;
        uint256 quorumLowSupplyThreshold;
        uint256 quorumHighSupplyThreshold;
        uint256 minProposalThreshold;
        uint256 maxProposalThreshold;
    }

    /// @notice Basis point denominator shared by all quorum parameters (100% == 10_000).
    uint256 public constant QUORUM_DENOMINATOR = 10_000;

    uint256 public immutable dynamicQuorumMinBps;
    uint256 public immutable dynamicQuorumMaxBps;
    uint256 public immutable quorumLowSupplyThreshold;
    uint256 public immutable quorumHighSupplyThreshold;

    uint256 public immutable minimumProposalThreshold;
    uint256 public immutable maximumProposalThreshold;

    error InvalidQuorumBounds();
    error InvalidProposalThresholdBounds();
    error ProposalThresholdOutOfBounds(uint256 requested, uint256 minimum, uint256 maximum);

    constructor(GovernorConfig memory config)
        Governor(config.name)
        GovernorSettings(config.votingDelayBlocks, config.votingPeriodBlocks, config.proposalThreshold)
        GovernorVotes(config.token)
        GovernorTimelockControl(config.timelock)
    {
        if (
            config.quorumMinBps > config.quorumMaxBps || config.quorumMaxBps > QUORUM_DENOMINATOR
                || config.quorumLowSupplyThreshold > config.quorumHighSupplyThreshold
        ) {
            revert InvalidQuorumBounds();
        }
        if (config.minProposalThreshold > config.maxProposalThreshold) {
            revert InvalidProposalThresholdBounds();
        }
        if (
            config.proposalThreshold < config.minProposalThreshold
                || config.proposalThreshold > config.maxProposalThreshold
        ) {
            revert ProposalThresholdOutOfBounds(
                config.proposalThreshold, config.minProposalThreshold, config.maxProposalThreshold
            );
        }

        dynamicQuorumMinBps = config.quorumMinBps;
        dynamicQuorumMaxBps = config.quorumMaxBps;
        quorumLowSupplyThreshold = config.quorumLowSupplyThreshold;
        quorumHighSupplyThreshold = config.quorumHighSupplyThreshold;
        minimumProposalThreshold = config.minProposalThreshold;
        maximumProposalThreshold = config.maxProposalThreshold;
    }

    /// @notice Quorum required for a proposal snapshot at `timepoint`, in vote weight.
    /// @dev Snapshot-safe: reads historical total supply at `timepoint` (never the current
    ///      supply), so post-snapshot token movements cannot move the goalposts of a live
    ///      vote. The fraction itself is interpolated by `quorumFractionAtSupply`.
    function quorum(uint256 timepoint) public view override returns (uint256) {
        uint256 snapshotSupply = token().getPastTotalSupply(timepoint);
        uint256 effectiveBps = quorumFractionAtSupply(snapshotSupply);
        return Math.mulDiv(snapshotSupply, effectiveBps, QUORUM_DENOMINATOR);
    }

    /// @notice Effective quorum fraction (basis points) for a given total supply.
    /// @dev Linear ramp:
    ///      - supply <= low threshold  ->  quorumMinBps
    ///      - supply >= high threshold ->  quorumMaxBps
    ///      - otherwise                ->  min + (max - min) * (supply - low) / (high - low)
    ///      When low == high the middle branch is unreachable and the ramp degenerates to a
    ///      step function, which remains safe.
    function quorumFractionAtSupply(uint256 totalSupply) public view returns (uint256) {
        if (totalSupply <= quorumLowSupplyThreshold) {
            return dynamicQuorumMinBps;
        }
        if (totalSupply >= quorumHighSupplyThreshold) {
            return dynamicQuorumMaxBps;
        }
        return dynamicQuorumMinBps
            + Math.mulDiv(
            dynamicQuorumMaxBps - dynamicQuorumMinBps,
            totalSupply - quorumLowSupplyThreshold,
            quorumHighSupplyThreshold - quorumLowSupplyThreshold
        );
    }

    /// @notice Quorum denominator kept for tooling compatibility (Tally and friends).
    function quorumDenominator() public view returns (uint256) {
        return QUORUM_DENOMINATOR;
    }

    /// @notice Governance-adjustable proposal threshold, clamped to immutable bounds.
    /// @dev Re-applies `onlyGovernance` (Solidity overrides do not inherit parent modifiers),
    ///      but deliberately routes to the internal `_setProposalThreshold` rather than
    ///      `super.setProposalThreshold`: the parent public function carries its own
    ///      `onlyGovernance` modifier, and running the whitelist deque check twice drains
    ///      the deque and reverts during legitimate proposal execution.
    function setProposalThreshold(uint256 newProposalThreshold) public override(GovernorSettings) onlyGovernance {
        if (newProposalThreshold < minimumProposalThreshold || newProposalThreshold > maximumProposalThreshold) {
            revert ProposalThresholdOutOfBounds(
                newProposalThreshold, minimumProposalThreshold, maximumProposalThreshold
            );
        }
        _setProposalThreshold(newProposalThreshold);
    }

    // ------------------------------------------------------------------
    // Linearisation glue: required explicit overrides.
    // ------------------------------------------------------------------

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function clock() public view override(Governor, GovernorVotes) returns (uint48) {
        return super.clock();
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public view override(Governor, GovernorVotes) returns (string memory) {
        return super.CLOCK_MODE();
    }

    function _getVotes(address account, uint256 timepoint, bytes memory params)
        internal
        view
        override(Governor, GovernorVotes)
        returns (uint256)
    {
        return super._getVotes(account, timepoint, params);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId) public view override(Governor) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
