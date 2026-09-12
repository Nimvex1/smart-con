// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DAOGovernanceToken} from "../contracts/DAOGovernanceToken.sol";
import {EnterpriseDAO} from "../contracts/EnterpriseDAO.sol";
import {DAOTreasuryExecutionEngine} from "../contracts/DAOTreasuryExecutionEngine.sol";

/// @dev Records calls so proposal execution effects are observable.
contract CallTarget {
    uint256 public flag;
    uint256 public lastNativeReceived;

    event Invoked(uint256 nativeValue, bytes data);

    function setFlag(uint256 v) external payable {
        flag = v;
        lastNativeReceived = msg.value;
        emit Invoked(msg.value, msg.data);
    }

    receive() external payable {
        lastNativeReceived = msg.value;
        emit Invoked(msg.value, "");
    }
}

contract EnterpriseDAOTest is Test {
    DAOGovernanceToken internal token;
    TimelockController internal timelock;
    EnterpriseDAO internal governor;
    DAOTreasuryExecutionEngine internal treasury;
    CallTarget internal target;

    address internal proposer = makeAddr("proposer");
    address internal voter1 = makeAddr("voter1");
    address internal voter2 = makeAddr("voter2");
    address internal guardian = makeAddr("guardian");
    address internal rando = makeAddr("rando");
    address internal lateBuyer = makeAddr("lateBuyer");

    uint256 internal constant SUPPLY = 1_000_000e18;
    uint48 internal constant VOTING_DELAY = 1;
    uint32 internal constant VOTING_PERIOD = 5;
    uint256 internal constant THRESHOLD = 100e18;
    uint256 internal constant MIN_THRESHOLD = 1e18;
    uint256 internal constant MAX_THRESHOLD = 1_000_000e18;

    // With SUPPLY = 1e24 between low (5e23) and high (2e24):
    // effective bps = 400 + 600 * (1e24 - 5e23) / (2e24 - 5e23) = 600 bps
    uint256 internal constant QUORUM_MIN_BPS = 400;
    uint256 internal constant QUORUM_MAX_BPS = 1000;
    uint256 internal constant QUORUM_LOW = 5e23;
    uint256 internal constant QUORUM_HIGH = 2e24;

    // Proposal artifacts, retained because OZ 5.1 queue/execute/cancel take
    // the full (targets, values, calldatas, descriptionHash) argument set.
    address[] internal pTargets;
    uint256[] internal pValues;
    bytes[] internal pCalldatas;
    bytes32 internal pDescriptionHash;

    function setUp() public {
        token = new DAOGovernanceToken("Enterprise DAO Token", "EDAO", address(this), SUPPLY);
        token.transfer(proposer, 400_000e18);
        token.transfer(voter1, 350_000e18);
        token.transfer(voter2, 250_000e18);

        vm.prank(proposer);
        token.delegate(proposer);
        vm.prank(voter1);
        token.delegate(voter1);
        vm.prank(voter2);
        token.delegate(voter2);

        address[] memory noProposers = new address[](0);
        address[] memory openExecutors = new address[](1);
        openExecutors[0] = address(0); // permissionless timelock execution
        timelock = new TimelockController(1 days, noProposers, openExecutors, address(this));

        treasury = new DAOTreasuryExecutionEngine(address(timelock), guardian);
        governor = _deployGovernor(QUORUM_MIN_BPS, QUORUM_MAX_BPS, QUORUM_LOW, QUORUM_HIGH);

        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));

        target = new CallTarget();

        // Ensure all delegation checkpoints are in the past relative to later snapshots.
        vm.roll(block.number + 1);
    }

    function _deployGovernor(uint256 quorumMinBps, uint256 quorumMaxBps, uint256 quorumLow, uint256 quorumHigh)
        internal
        returns (EnterpriseDAO)
    {
        EnterpriseDAO.GovernorConfig memory cfg = EnterpriseDAO.GovernorConfig({
            name: "Enterprise DAO",
            token: IVotes(address(token)),
            timelock: timelock,
            votingDelayBlocks: VOTING_DELAY,
            votingPeriodBlocks: VOTING_PERIOD,
            proposalThreshold: THRESHOLD,
            quorumMinBps: quorumMinBps,
            quorumMaxBps: quorumMaxBps,
            quorumLowSupplyThreshold: quorumLow,
            quorumHighSupplyThreshold: quorumHigh,
            minProposalThreshold: MIN_THRESHOLD,
            maxProposalThreshold: MAX_THRESHOLD
        });
        return new EnterpriseDAO(cfg);
    }

    /// @dev Proposes a single-target call and caches the artifacts for queue/execute/cancel.
    function _propose(EnterpriseDAO gov, address callTarget, bytes memory callData, string memory description)
        internal
        returns (uint256 proposalId)
    {
        pTargets = new address[](1);
        pValues = new uint256[](1);
        pCalldatas = new bytes[](1);
        pTargets[0] = callTarget;
        pValues[0] = 0;
        pCalldatas[0] = callData;
        pDescriptionHash = keccak256(bytes(description));

        vm.prank(proposer);
        return gov.propose(pTargets, pValues, pCalldatas, description);
    }

    function _proposeSetFlag(EnterpriseDAO gov, uint256 flagValue, string memory description)
        internal
        returns (uint256)
    {
        return _propose(gov, address(target), abi.encodeCall(CallTarget.setFlag, (flagValue)), description);
    }

    function _voteAndQueue(EnterpriseDAO gov, uint256 proposalId) internal {
        vm.roll(block.number + 2); // past voting delay
        vm.prank(voter1);
        gov.castVote(proposalId, 1); // 35% of supply
        vm.roll(block.number + 10); // past voting period
        gov.queue(pTargets, pValues, pCalldatas, pDescriptionHash);
    }

    function _passAndExecute(EnterpriseDAO gov, uint256 proposalId) internal {
        _voteAndQueue(gov, proposalId);
        vm.warp(block.timestamp + 1 days + 1); // past timelock delay
        gov.execute(pTargets, pValues, pCalldatas, pDescriptionHash);
    }

    // ------------------------------------------------------------------
    // Proposal lifecycle
    // ------------------------------------------------------------------

    function test_ProposalLifecycle() public {
        uint256 proposalId = _proposeSetFlag(governor, 42, "set flag to 42");
        assertEq(
            uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending), "fresh proposal is pending"
        );

        _passAndExecute(governor, proposalId);

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        assertEq(target.flag(), 42, "proposal execution must reach the target");
    }

    function test_ProposalDefeatedWhenQuorumNotMet() public {
        uint256 proposalId = _proposeSetFlag(governor, 1, "nobody votes");

        vm.roll(block.number + 12); // past voting period, zero votes cast
        assertEq(
            uint256(governor.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "zero participation must defeat the proposal"
        );

        vm.expectRevert(); // cannot queue a defeated proposal
        governor.queue(pTargets, pValues, pCalldatas, pDescriptionHash);
    }

    function test_CancelProposalByProposer() public {
        uint256 proposalId = _proposeSetFlag(governor, 7, "cancel me");
        vm.prank(proposer);
        governor.cancel(pTargets, pValues, pCalldatas, pDescriptionHash);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_ExecuteBeforeTimelockDelayReverts() public {
        uint256 proposalId = _proposeSetFlag(governor, 42, "too early");

        _voteAndQueue(governor, proposalId);

        // Operation id as the timelock sees it: hashOperationBatch(..., predecessor=0,
        // salt = governor address (truncated) XOR descriptionHash).
        bytes32 operationId = timelock.hashOperationBatch(
            pTargets, pValues, pCalldatas, bytes32(0), bytes20(address(governor)) ^ pDescriptionHash
        );
        // "Ready" is operation state bit 2; executing before eta reports it as expected.
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector, operationId, bytes32(uint256(4))
            )
        );
        governor.execute(pTargets, pValues, pCalldatas, pDescriptionHash);
    }

    // ------------------------------------------------------------------
    // Snapshot safety
    // ------------------------------------------------------------------

    function test_VotesAcquiredAfterSnapshotIgnored() public {
        // 50% quorum: voter1 (35%) + lateBuyer (25%, acquired after the snapshot) would
        // reach 60% if voting power were read live, but snapshot safety must ignore it.
        EnterpriseDAO gov = _deployGovernor(5000, 5000, 0, 0);

        uint256 proposalId = _proposeSetFlag(gov, 5, "late acquisition must not count");
        vm.roll(block.number + 2); // snapshot passed

        // lateBuyer acquires 25% of the supply AFTER the proposal snapshot.
        vm.prank(voter2);
        token.transfer(lateBuyer, 250_000e18);
        vm.prank(lateBuyer);
        token.delegate(lateBuyer);

        vm.prank(voter1);
        gov.castVote(proposalId, 1);
        vm.prank(lateBuyer);
        gov.castVote(proposalId, 1); // zero weight at the snapshot

        vm.roll(block.number + 10);
        assertEq(
            uint256(gov.state(proposalId)),
            uint256(IGovernor.ProposalState.Defeated),
            "votes acquired after the snapshot must not count"
        );
    }

    // ------------------------------------------------------------------
    // Dynamic quorum
    // ------------------------------------------------------------------

    function test_QuorumLinearRampAllRegimes() public {
        uint256 timepoint = block.number - 1;

        // Supply below the low threshold -> minimum fraction.
        EnterpriseDAO govMin = _deployGovernor(400, 1000, 2e24, 8e24);
        assertEq(
            govMin.quorum(timepoint),
            Math.mulDiv(SUPPLY, 400, 10_000),
            "supply below low threshold must use the minimum fraction"
        );

        // Supply above the high threshold -> maximum fraction.
        EnterpriseDAO govMax = _deployGovernor(400, 1000, 1e22, 5e23);
        assertEq(
            govMax.quorum(timepoint),
            Math.mulDiv(SUPPLY, 1000, 10_000),
            "supply above high threshold must use the maximum fraction"
        );

        // Supply between thresholds -> linear interpolation.
        EnterpriseDAO govMid = _deployGovernor(400, 1000, 5e23, 2e24);
        assertEq(govMid.quorum(timepoint), Math.mulDiv(SUPPLY, 600, 10_000), "mid-supply must interpolate to 600 bps");
    }

    function test_QuorumFractionRampBoundaries() public {
        EnterpriseDAO gov = _deployGovernor(400, 1000, 5e23, 2e24);

        assertEq(gov.quorumFractionAtSupply(0), 400, "zero supply must clamp to min");
        assertEq(gov.quorumFractionAtSupply(5e23), 400, "low threshold must clamp to min");
        assertEq(gov.quorumFractionAtSupply(2e24), 1000, "high threshold must clamp to max");
        assertEq(gov.quorumFractionAtSupply(type(uint256).max), 1000, "huge supply must clamp to max");

        // Exactly one third into the ramp: 400 + 600 / 3 = 600.
        uint256 oneThird = 5e23 + (2e24 - 5e23) / 3;
        assertEq(gov.quorumFractionAtSupply(oneThird), 600, "interpolation must be linear");
    }

    function test_ConstructorValidatesBounds() public {
        vm.expectRevert(EnterpriseDAO.InvalidQuorumBounds.selector);
        _deployGovernor(1001, 1000, 0, 1); // min > max

        vm.expectRevert(EnterpriseDAO.InvalidQuorumBounds.selector);
        _deployGovernor(400, 10_001, 0, 1); // max above denominator

        vm.expectRevert(EnterpriseDAO.InvalidQuorumBounds.selector);
        _deployGovernor(400, 1000, 10e24, 5e24); // low > high

        vm.expectRevert(EnterpriseDAO.InvalidProposalThresholdBounds.selector);
        _deployGovernorWithThresholds(THRESHOLD, 2_000e18, 1_000e18); // min > max

        vm.expectRevert(EnterpriseDAO.ProposalThresholdOutOfBounds.selector);
        _deployGovernorWithThresholds(50e18, 1e18, 1_000_000e18); // below min bound
    }

    function _deployGovernorWithThresholds(uint256 initialThreshold, uint256 minThreshold, uint256 maxThreshold)
        internal
        returns (EnterpriseDAO)
    {
        EnterpriseDAO.GovernorConfig memory cfg = EnterpriseDAO.GovernorConfig({
            name: "Enterprise DAO",
            token: IVotes(address(token)),
            timelock: timelock,
            votingDelayBlocks: VOTING_DELAY,
            votingPeriodBlocks: VOTING_PERIOD,
            proposalThreshold: initialThreshold,
            quorumMinBps: QUORUM_MIN_BPS,
            quorumMaxBps: QUORUM_MAX_BPS,
            quorumLowSupplyThreshold: QUORUM_LOW,
            quorumHighSupplyThreshold: QUORUM_HIGH,
            minProposalThreshold: minThreshold,
            maxProposalThreshold: maxThreshold
        });
        return new EnterpriseDAO(cfg);
    }

    // ------------------------------------------------------------------
    // Governance-controlled parameters
    // ------------------------------------------------------------------

    function test_GovernanceUpdatesThresholdWithinBounds() public {
        assertEq(governor.proposalThreshold(), THRESHOLD);

        uint256 proposalId = _propose(
            governor,
            address(governor),
            abi.encodeCall(EnterpriseDAO.setProposalThreshold, (500e18)),
            "raise proposal threshold"
        );

        _passAndExecute(governor, proposalId);

        assertEq(governor.proposalThreshold(), 500e18, "governance must move the threshold");
    }

    function test_ThresholdBoundsEnforcedDuringExecution() public {
        uint256 proposalId = _propose(
            governor,
            address(governor),
            abi.encodeCall(EnterpriseDAO.setProposalThreshold, (2_000_000e18)), // > max
            "out of bounds"
        );

        _voteAndQueue(governor, proposalId);
        vm.warp(block.timestamp + 1 days + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                EnterpriseDAO.ProposalThresholdOutOfBounds.selector, 2_000_000e18, MIN_THRESHOLD, MAX_THRESHOLD
            )
        );
        governor.execute(pTargets, pValues, pCalldatas, pDescriptionHash);
    }

    function test_DirectThresholdCallRejected() public {
        // The OZ 5.x onlyGovernance guard whitelists calls pushed through proposal
        // execution; a direct call from anyone (even the executor) must fail.
        vm.prank(rando);
        vm.expectRevert();
        governor.setProposalThreshold(500e18);
    }

    // ------------------------------------------------------------------
    // Full stack: Governor -> Timelock -> Treasury
    // ------------------------------------------------------------------

    function test_FullGovernanceToTreasuryFlow() public {
        bytes memory innerCalldata = abi.encodeCall(CallTarget.setFlag, (uint256(7)));
        bytes memory treasuryCall = abi.encodeCall(
            DAOTreasuryExecutionEngine.approvePackage,
            (address(target), uint256(0), innerCalldata, treasury.TIER_LOW(), uint48(0), bytes32(0))
        );

        uint256 proposalId = _propose(governor, address(treasury), treasuryCall, "schedule treasury package");

        _passAndExecute(governor, proposalId);

        // The timelock (as treasury GOVERNANCE_ROLE) scheduled the package.
        bytes32 packageId = treasury.packageHash(address(target), 0, innerCalldata, treasury.TIER_LOW(), 1);
        assertTrue(treasury.packageExists(packageId), "timelock must have scheduled the package");

        // TIER_LOW quarantine is 1 day; execution remains permissionless afterwards.
        vm.warp(block.timestamp + 1 days + 1);
        treasury.executePackage(packageId);
        assertEq(target.flag(), 7, "end-to-end governance execution must reach the target");
    }
}
