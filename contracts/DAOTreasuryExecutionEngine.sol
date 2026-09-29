// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DAOTreasuryExecutionEngine
/// @notice Multi-asset treasury with governance-approved, delayed execution packages.
/// @dev The TimelockController should hold governance authority over this contract.
///      Every package binds target/value/calldata/tier/nonce into an immutable package id.
///      Execution is permissionless after the package's tier delay, improving liveness.
///
///      Guardian power is deliberately time-bound: a guardian may cancel a package only
///      while it is still in quarantine (before its `executeAfter` timepoint). Once the
///      quarantine window has elapsed, cancellation is a governance-only decision, so a
///      compromised guardian cannot permanently suppress execution of approved packages.
///
///      Risk limits are deliberately NOT governance-exclusive. Every control that bounds
///      the blast radius of a hostile governor -- the tier delay ladder, the per-tier
///      native value caps, the destination allowlist and the native reserve floor -- is
///      mutable by governance, so on its own it constrains nothing: a single governance
///      batch could otherwise zero the delay, uncap the value, disable the allowlist and
///      drain the treasury in one transaction. Two mechanisms fix that:
///
///      1. `minTierDelay` is `immutable`. No account, however many keys are compromised,
///         can set a tier delay below it. This is the unconditional last line of defence.
///      2. Loosening any risk limit (delay decrease within the floor, cap increase, tier
///         enable, allowlist disable/removal, reserve floor decrease) requires
///         `RISK_LIMITER_ROLE`. Tightening requires `GOVERNANCE_ROLE` and nothing else, so
///         an incident can still be contained without waiting for the limiter. The two
///         roles are deliberately NOT stacked: a single account holding both would be
///         equivalent to the single-key design this replaces.
///
///      The limiter must be a key independent of the governor (a separate security
///      council). Compromising it alone lets an attacker raise the caps and lift the
///      allowlist, but not schedule anything -- governance is still required to approve a
///      package, and `minTierDelay` still applies. Compromising governance alone lets an
///      attacker tighten or schedule, but not remove a single risk limit. Both keys are
///      required to dismantle the constraints, and even then the delay floor holds.
contract DAOTreasuryExecutionEngine is AccessControl, Pausable, ReentrancyGuard, ERC721Holder, ERC1155Holder {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /// @notice Co-signature required to LOOSEN any risk limit. Deliberately a separate
    ///         role from GOVERNANCE_ROLE so a captured governor cannot relax its own
    ///         constraints. Holding this role grants no ability to schedule or execute.
    bytes32 public constant RISK_LIMITER_ROLE = keccak256("RISK_LIMITER_ROLE");

    uint8 public constant TIER_LOW = 0;
    uint8 public constant TIER_MEDIUM = 1;
    uint8 public constant TIER_HIGH = 2;
    uint8 public constant TIER_CRITICAL = 3;
    uint8 public constant MAX_TIER = TIER_CRITICAL;

    /// @notice Upper bound for any tier delay. A quarantine longer than a year is
    ///         nonsensical for this system and would risk `uint48` truncation abuse.
    uint48 public constant MAX_TIER_DELAY = 365 days;

    /// @notice Lower bound for any tier delay, fixed at construction. This is the
    ///         unconditional last line of defence: it is `immutable`, so no governance
    ///         proposal and no co-signature can remove or shorten it. Only the deployer,
    ///         once, at construction, chooses it -- and it must be non-zero.
    uint48 public immutable minTierDelay;

    /// @notice Maximum scheduling horizon: `expiresAt` must fall within this window of
    ///         approval, so governance cannot park a live package for a decade ahead and
    ///         fire it against a treasury whose governance has since changed.
    uint48 public constant MAX_PACKAGE_EXPIRY = 365 days;

    struct TierConfig {
        uint48 delay;
        uint256 maxNativeValue;
        bool enabled;
    }

    /// @dev Field order packs `executeAfter`, `tier`, `executed` and `cancelled` into one
    ///      storage slot. `data` is wiped after execution to refund gas and keep state lean.
    ///      `expiresAt` bounds the execution window: expired packages can never execute.
    ///      `predecessor` enforces ordering: a package can only execute once its
    ///      predecessor has executed.
    struct Package {
        address target;
        uint256 value;
        bytes data;
        uint48 executeAfter;
        uint8 tier;
        bool executed;
        bool cancelled;
        uint256 nonce;
        uint48 expiresAt;
        bytes32 predecessor;
    }

    mapping(uint8 tier => TierConfig config) public tierConfig;
    mapping(bytes32 packageId => Package package_) private _packages;
    uint256 public nextPackageNonce = 1;

    /// @notice Optional destination allowlist. When enabled, packages may only target
    ///         allowlisted addresses. Toggle and list are governance-controlled.
    bool public targetAllowlistEnabled;
    mapping(address allowed => bool isAllowed) public targetAllowlist;

    /// @notice Optional per-asset reserve floor REFERENCES.
    /// @dev NOT ENFORCED ON-CHAIN. The treasury executes arbitrary target calldata and
    ///      cannot generically parse it to learn which tokens a call moves, so this
    ///      mapping is a published value for off-chain monitoring only. Unlike
    ///      `nativeReserveFloor`, no execution path ever reads it. A governance package
    ///      calling `token.transfer(...)` on a target contract is entirely unaffected.
    uint256 public nativeReserveFloor;
    mapping(IERC20 token => uint256 floor) public erc20ReserveFloorReferences;

    event PackageApprovedV2(
        bytes32 indexed packageId,
        address indexed target,
        uint256 value,
        uint8 indexed tier,
        uint256 nonce,
        uint48 executeAfter,
        uint48 expiresAt,
        bytes32 predecessor,
        bytes32 dataHash
    );
    event PackageExecuted(bytes32 indexed packageId, address indexed target, uint256 value, bytes returnData);
    event PackagesBatchExecuted(uint256 count);
    event PackageCancelled(bytes32 indexed packageId, address indexed caller);
    event PackageExpired(bytes32 indexed packageId);
    event TierConfigured(uint8 indexed tier, uint48 delay, uint256 maxNativeValue, bool enabled);
    event TreasuryPaused(address indexed guardian);
    event TreasuryUnpaused(address indexed governance);
    event NativeDeposited(address indexed sender, uint256 value);
    event ERC20Deposited(address indexed sender, address token, uint256 amount);
    event ERC721Deposited(address indexed sender, address token, uint256 tokenId);
    event ERC1155Deposited(address indexed sender, address token, uint256 indexed tokenId, uint256 amount);
    event TargetAllowlistToggled(bool enabled);
    event TargetAllowlistUpdated(address indexed target, bool allowed);
    event ReserveFloorsConfigured(uint256 nativeFloor);
    event ERC20ReserveFloorReferenceSet(address indexed token, uint256 floor);

    error InvalidTier(uint8 tier);
    error TierDisabled(uint8 tier);
    error TierDelayTooLong(uint48 delay, uint48 maximum);
    error TierDelayTooShort(uint48 delay, uint48 minimum);
    error RiskChangeRequiresLimiter(address caller);
    error CallerNotGovernanceOrLimiter(address caller);
    error NativeValueTooHigh(uint256 supplied, uint256 maximum);
    error InvalidTarget();
    error TargetNotAllowed(address target);
    error InvalidZeroAmount();
    error PackageNotFound(bytes32 packageId);
    error PackageNotReady(bytes32 packageId, uint48 executeAfter);
    error PackageAlreadyFinalized(bytes32 packageId);
    error PackageExpiredError(bytes32 packageId, uint48 expiresAt);
    error PackageNotExpired(bytes32 packageId, uint48 expiresAt);
    error PredecessorNotExecuted(bytes32 packageId, bytes32 predecessor);
    error PredecessorFinalized(bytes32 predecessor);
    error ExpiryWindowTooShort(uint48 executeAfter, uint48 expiresAt);
    error ExpiryWindowTooLong(uint48 maximum, uint48 supplied);
    error UnexpectedMsgValue(uint256 supplied);
    error ExecutionFailed(bytes32 packageId, bytes reason);
    error GuardianCancelWindowClosed(bytes32 packageId, uint48 executeAfter);
    error CallerNotGovernanceOrGuardian(address caller);
    error ReserveFloorBreached(uint256 balance, uint256 floor);

    constructor(address timelockExecutor, address guardian, address riskLimiter, uint48 minTierDelay_) {
        if (timelockExecutor == address(0) || guardian == address(0) || riskLimiter == address(0)) {
            revert InvalidTarget();
        }
        if (minTierDelay_ == 0) revert TierDelayTooShort(minTierDelay_, 1);

        minTierDelay = minTierDelay_;

        // Self-administered after construction: any subsequent role change must be done
        // through a governance-approved package targeting this contract.
        _grantRole(DEFAULT_ADMIN_ROLE, address(this));
        // Governance controls governance/guardian membership; the treasury remains the
        // emergency admin root so role changes themselves are governance-mediated.
        _setRoleAdmin(GOVERNANCE_ROLE, GOVERNANCE_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, GOVERNANCE_ROLE);
        // The limiter's own membership is governance-managed, but loosening a risk limit
        // still needs the limiter to sign, so governance cannot appoint itself as one.
        _setRoleAdmin(RISK_LIMITER_ROLE, GOVERNANCE_ROLE);
        _grantRole(GOVERNANCE_ROLE, timelockExecutor);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(RISK_LIMITER_ROLE, riskLimiter);

        // Shipped defaults are lifted to `minTierDelay` rather than reverting, so a DAO
        // may choose a stricter floor than the defaults without re-deriving them.
        _configureTier(TIER_LOW, _atLeastMin(1 days), 250 ether, true);
        _configureTier(TIER_MEDIUM, _atLeastMin(3 days), 100 ether, true);
        _configureTier(TIER_HIGH, _atLeastMin(7 days), 25 ether, true);
        _configureTier(TIER_CRITICAL, _atLeastMin(14 days), 5 ether, true);
    }

    /// @notice Accepts direct native transfers and records them for off-chain accounting.
    /// @dev Forced sends (e.g. selfdestruct) bypass this hook; treat `ethBalance` as the
    ///      source of truth for on-chain value.
    receive() external payable {
        emit NativeDeposited(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------

    /// @notice Deposit ERC20 tokens using allowance-based transfer.
    function depositERC20(IERC20 token, uint256 amount) external whenNotPaused {
        if (amount == 0) revert InvalidZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit ERC20Deposited(msg.sender, address(token), amount);
    }

    /// @notice Deposit an ERC721 into the treasury.
    function depositERC721(IERC721 token, uint256 tokenId) external whenNotPaused {
        token.safeTransferFrom(msg.sender, address(this), tokenId);
        emit ERC721Deposited(msg.sender, address(token), tokenId);
    }

    /// @notice Deposit an ERC1155 token batch slot into the treasury.
    function depositERC1155(IERC1155 token, uint256 tokenId, uint256 amount, bytes calldata data)
        external
        whenNotPaused
    {
        if (amount == 0) revert InvalidZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), tokenId, amount, data);
        emit ERC1155Deposited(msg.sender, address(token), tokenId, amount);
    }

    // ------------------------------------------------------------------
    // Package scheduling and execution
    // ------------------------------------------------------------------

    /// @notice Governance schedules an exact calldata package. No arbitrary caller can create one.
    /// @dev Deliberately NOT `whenNotPaused`: guardians pause execution, not scheduling, so
    ///      governance can keep preparing packages during an incident.
    ///      `expiresAt` bounds the execution window (after it, the package is dead);
    ///      0 means "no expiry". `predecessor` is another package that must execute first.
    function approvePackage(
        address target,
        uint256 value,
        bytes calldata data,
        uint8 tier,
        uint48 expiresAt,
        bytes32 predecessor
    ) external onlyRole(GOVERNANCE_ROLE) returns (bytes32 packageId) {
        if (target == address(0)) revert InvalidTarget();
        if (tier > MAX_TIER) revert InvalidTier(tier);
        if (targetAllowlistEnabled && !targetAllowlist[target]) revert TargetNotAllowed(target);

        TierConfig memory config = tierConfig[tier];
        if (!config.enabled) revert TierDisabled(tier);
        if (value > config.maxNativeValue) revert NativeValueTooHigh(value, config.maxNativeValue);

        uint48 executeAfter = uint48(block.timestamp + config.delay);
        if (expiresAt != 0) {
            if (expiresAt <= executeAfter) revert ExpiryWindowTooShort(executeAfter, expiresAt);
            uint48 horizon = uint48(block.timestamp + MAX_PACKAGE_EXPIRY);
            if (expiresAt > horizon) revert ExpiryWindowTooLong(horizon, expiresAt);
        }

        // A predecessor must exist and still be executable. Rejecting finalized
        // predecessors is what stops a successor from being created that can never run:
        // execution requires `pred.executed`, which a cancelled or already-executed
        // package never satisfies. Cycles remain impossible because `predecessor` must
        // already exist and nonces strictly increase, so a package can only reference
        // an older one.
        if (predecessor != bytes32(0)) {
            Package storage pred = _packages[predecessor];
            if (pred.target == address(0)) revert PackageNotFound(predecessor);
            if (pred.cancelled || pred.executed) revert PredecessorFinalized(predecessor);
        }

        uint256 nonce = nextPackageNonce++;
        packageId = keccak256(abi.encode(address(this), target, value, keccak256(data), tier, nonce));
        _packages[packageId] = Package({
            target: target,
            value: value,
            data: data,
            executeAfter: executeAfter,
            tier: tier,
            executed: false,
            cancelled: false,
            nonce: nonce,
            expiresAt: expiresAt,
            predecessor: predecessor
        });

        bytes32 dataHash = keccak256(data);
        emit PackageApprovedV2(packageId, target, value, tier, nonce, executeAfter, expiresAt, predecessor, dataHash);
    }

    /// @notice Finalize a package that can no longer run: anyone can call, keeps state clean.
    /// @dev Two independent conditions qualify. Either the package's execution window has
    ///      closed, or its predecessor was cancelled -- in which case the package can never
    ///      execute (`_executePackage` requires `pred.executed`) and, when it has no
    ///      `expiresAt`, no other permissionless path could ever finalize it. A merely
    ///      *pending* predecessor does not qualify: that package may still run in order.
    function closeExpiredPackage(bytes32 packageId) external {
        Package storage package_ = _packages[packageId];
        if (package_.target == address(0)) revert PackageNotFound(packageId);
        if (package_.executed || package_.cancelled) revert PackageAlreadyFinalized(packageId);

        bool windowClosed = package_.expiresAt != 0 && block.timestamp >= package_.expiresAt;
        bool predecessorCancelled = package_.predecessor != bytes32(0) && _packages[package_.predecessor].cancelled;
        if (!windowClosed && !predecessorCancelled) {
            revert PackageNotExpired(packageId, package_.expiresAt);
        }

        package_.cancelled = true; // finalized as cancelled; never executable
        emit PackageExpired(packageId);
    }

    /// @notice Execute a governance-approved package after its quarantine delay.
    /// @dev Permissionless execution prevents a dead executor from permanently locking
    ///      ready funds. Payable (with an explicit rejection of attached value) so that
    ///      accidental ETH is refunded with a named error instead of a bare revert.
    function executePackage(bytes32 packageId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes memory returnData)
    {
        if (msg.value != 0) revert UnexpectedMsgValue(msg.value);
        return _executePackage(packageId);
    }

    /// @notice Execute several ready packages atomically in one transaction.
    /// @dev Reverts roll back the whole batch, so observers never see a partial run.
    function executePackages(bytes32[] calldata packageIds)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes[] memory results)
    {
        if (msg.value != 0) revert UnexpectedMsgValue(msg.value);

        uint256 count = packageIds.length;
        results = new bytes[](count);
        for (uint256 i = 0; i < count; ++i) {
            results[i] = _executePackage(packageIds[i]);
        }

        emit PackagesBatchExecuted(count);
    }

    /// @dev Shared engine for single and batch execution.
    function _executePackage(bytes32 packageId) private returns (bytes memory returnData) {
        Package storage package_ = _packages[packageId];
        if (package_.target == address(0)) revert PackageNotFound(packageId);
        if (package_.executed || package_.cancelled) revert PackageAlreadyFinalized(packageId);
        if (block.timestamp < package_.executeAfter) {
            revert PackageNotReady(packageId, package_.executeAfter);
        }
        if (package_.expiresAt != 0 && block.timestamp >= package_.expiresAt) {
            revert PackageExpiredError(packageId, package_.expiresAt);
        }
        if (package_.predecessor != bytes32(0)) {
            Package storage pred = _packages[package_.predecessor];
            if (!pred.executed) revert PredecessorNotExecuted(packageId, package_.predecessor);
        }
        if (package_.value > 0) {
            uint256 balance = address(this).balance;
            if (balance < package_.value || balance - package_.value < nativeReserveFloor) {
                revert ReserveFloorBreached(balance, nativeReserveFloor);
            }
        }

        // Checks-effects-interactions. A revert from the external call rolls the status
        // change back; the treasury itself always supplies the native value.
        package_.executed = true;

        (bool success, bytes memory data_) = package_.target.call{value: package_.value}(package_.data);
        if (!success) revert ExecutionFailed(packageId, data_);

        // Wipe the calldata payload after success: refunds gas, keeps long-term state lean.
        // Metadata (target, value, tier, nonce, executeAfter, flags) is retained.
        delete package_.data;

        emit PackageExecuted(packageId, package_.target, package_.value, data_);
        return data_;
    }

    /// @notice Cancel a package: guardians only during quarantine, governance at any time.
    /// @dev Guardian cancellation is restricted to the window before `executeAfter`, so a
    ///      compromised guardian cannot suppress approved packages indefinitely. Governance
    ///      (the timelock path, typically a multi-day process) retains unlimited cancellation.
    function cancelPackage(bytes32 packageId) external {
        Package storage package_ = _packages[packageId];
        if (package_.target == address(0)) revert PackageNotFound(packageId);
        if (package_.executed || package_.cancelled) revert PackageAlreadyFinalized(packageId);

        bool isGovernance = hasRole(GOVERNANCE_ROLE, msg.sender);
        bool isGuardian = hasRole(GUARDIAN_ROLE, msg.sender);

        if (!isGovernance && !isGuardian) {
            revert CallerNotGovernanceOrGuardian(msg.sender);
        }
        if (!isGovernance && block.timestamp >= package_.executeAfter) {
            revert GuardianCancelWindowClosed(packageId, package_.executeAfter);
        }

        package_.cancelled = true;
        emit PackageCancelled(packageId, msg.sender);
    }

    // ------------------------------------------------------------------
    // Emergency controls
    // ------------------------------------------------------------------

    /// @notice Emergency circuit breaker for funds execution.
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
        emit TreasuryPaused(msg.sender);
    }

    /// @notice Unpausing requires governance, not the emergency guardian.
    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
        emit TreasuryUnpaused(msg.sender);
    }

    /// @notice Reconfigure execution tiers. Delays are bounded on both sides by the
    ///         immutable `minTierDelay` and by `MAX_TIER_DELAY`.
    /// @dev Authority is split so neither role can do both halves on its own:
    ///      loosening (shorter delay, larger cap, re-enabling a disabled tier) requires
    ///      RISK_LIMITER_ROLE; tightening requires GOVERNANCE_ROLE. Guardians and every
    ///      other account are rejected outright.
    function configureTier(uint8 tier, uint48 delay, uint256 maxNativeValue, bool enabled) external {
        TierConfig memory current = tierConfig[tier];
        _authorizeRiskChange(
            delay < current.delay || maxNativeValue > current.maxNativeValue || (enabled && !current.enabled)
        );
        _configureTier(tier, delay, maxNativeValue, enabled);
    }

    // ------------------------------------------------------------------
    // Destination allowlist and reserve floors (governance-only)
    // ------------------------------------------------------------------

    /// @notice Enable/disable the destination allowlist. When enabled, only allowlisted
    ///         targets may receive packages.
    /// @dev Disabling loosens containment and therefore requires RISK_LIMITER_ROLE;
    ///      enabling it is a tightening and governance-only.
    function setTargetAllowlistEnabled(bool enabled) external {
        _authorizeRiskChange(!enabled && targetAllowlistEnabled);
        targetAllowlistEnabled = enabled;
        emit TargetAllowlistToggled(enabled);
    }

    /// @notice Add or remove an address from the destination allowlist.
    /// @dev Removing a listed destination loosens containment and requires the limiter.
    function setTargetAllowed(address target, bool allowed) external {
        _authorizeRiskChange(!allowed && targetAllowlist[target]);
        if (target == address(0)) revert InvalidTarget();
        targetAllowlist[target] = allowed;
        emit TargetAllowlistUpdated(target, allowed);
    }

    /// @notice Set the minimum native balance the treasury must retain after any package
    ///         execution. Zero disables the check. This floor IS enforced on-chain, in
    ///         `_executePackage`, for packages that forward native value.
    /// @dev Lowering it loosens a risk limit and requires the risk limiter.
    function setNativeReserveFloor(uint256 floor) external {
        _authorizeRiskChange(floor < nativeReserveFloor);
        nativeReserveFloor = floor;
        emit ReserveFloorsConfigured(floor);
    }

    /// @notice Publish a per-token ERC20 balance floor REFERENCE for off-chain monitoring.
    /// @dev NOT an on-chain control. The treasury executes arbitrary target calldata and
    ///      cannot determine which tokens a given call moves, so nothing in the execution
    ///      path reads this mapping. It exists so monitoring can compare observed balances
    ///      against a published threshold. Do not treat it as a spend limit. See SECURITY.md.
    function setERC20ReserveFloorReference(IERC20 token, uint256 floor) external onlyRole(GOVERNANCE_ROLE) {
        if (address(token) == address(0)) revert InvalidTarget();
        erc20ReserveFloorReferences[token] = floor;
        emit ERC20ReserveFloorReferenceSet(address(token), floor);
    }

    // ------------------------------------------------------------------
    // Introspection
    // ------------------------------------------------------------------

    function getPackage(bytes32 packageId) external view returns (Package memory) {
        Package memory package_ = _packages[packageId];
        if (package_.target == address(0)) revert PackageNotFound(packageId);
        return package_;
    }

    function packageExists(bytes32 packageId) external view returns (bool) {
        return _packages[packageId].target != address(0);
    }

    function packageHash(address target, uint256 value, bytes calldata data, uint8 tier, uint256 nonce)
        external
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(address(this), target, value, keccak256(data), tier, nonce));
    }

    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function erc20Balance(IERC20 token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _configureTier(uint8 tier, uint48 delay, uint256 maxNativeValue, bool enabled) internal {
        if (tier > MAX_TIER) revert InvalidTier(tier);
        if (delay > MAX_TIER_DELAY) revert TierDelayTooLong(delay, MAX_TIER_DELAY);
        // Unconditional: no caller, however many roles it holds, may go below the floor.
        if (delay < minTierDelay) revert TierDelayTooShort(delay, minTierDelay);
        tierConfig[tier] = TierConfig({delay: delay, maxNativeValue: maxNativeValue, enabled: enabled});
        emit TierConfigured(tier, delay, maxNativeValue, enabled);
    }

    /// @dev Split authority for risk-limit reconfiguration. Loosening is reserved to
    ///      RISK_LIMITER_ROLE, tightening to GOVERNANCE_ROLE. Because the roles are not
    ///      stacked, no single compromised key can both schedule a package and remove the
    ///      limits that package must respect. `minTierDelay` is enforced separately in
    ///      `_configureTier` and is not reachable from either path.
    function _authorizeRiskChange(bool loosening) private view {
        if (loosening) {
            if (!hasRole(RISK_LIMITER_ROLE, msg.sender)) revert RiskChangeRequiresLimiter(msg.sender);
        } else if (!hasRole(GOVERNANCE_ROLE, msg.sender) && !hasRole(RISK_LIMITER_ROLE, msg.sender)) {
            revert CallerNotGovernanceOrLimiter(msg.sender);
        }
    }

    function _atLeastMin(uint48 delay) private view returns (uint48) {
        return delay < minTierDelay ? minTierDelay : delay;
    }

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl, ERC1155Holder) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
