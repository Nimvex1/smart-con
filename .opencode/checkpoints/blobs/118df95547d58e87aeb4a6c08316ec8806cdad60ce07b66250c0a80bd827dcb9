// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DAOGovernanceToken} from "../contracts/DAOGovernanceToken.sol";

contract DAOGovernanceTokenTest is Test {
    DAOGovernanceToken internal token;

    uint256 internal constant OWNER_PK = 0xA11CE;
    address internal owner;
    address internal spender = makeAddr("spender");
    address internal other = makeAddr("other");

    uint256 internal constant INITIAL_SUPPLY = 1_000_000e18;

    function setUp() public {
        owner = vm.addr(OWNER_PK);
        token = new DAOGovernanceToken("Enterprise DAO Token", "EDAO", owner, INITIAL_SUPPLY);
    }

    function test_InitialSupplyMintedToRecipient() public {
        assertEq(token.name(), "Enterprise DAO Token");
        assertEq(token.symbol(), "EDAO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY);
    }

    function test_ZeroRecipientConstructorReverts() public {
        vm.expectRevert(DAOGovernanceToken.InvalidInitialRecipient.selector);
        new DAOGovernanceToken("T", "T", address(0), 1e18);
    }

    function test_PermitGrantsAllowanceAndConsumesNonce() public {
        uint256 value = 1_000e18;
        uint256 deadline = type(uint256).max;
        uint256 initialNonce = token.nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                initialNonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, digest);

        token.permit(owner, spender, value, deadline, v, r, s);

        assertEq(token.allowance(owner, spender), value, "permit must set allowance");
        assertEq(token.nonces(owner), initialNonce + 1, "permit must consume a nonce");

        vm.prank(spender);
        token.transferFrom(owner, other, value);
        assertEq(token.balanceOf(other), value, "spender must be able to pull funds");
    }

    function test_DelegationCreatesCheckpoints() public {
        assertEq(token.getVotes(owner), 0, "no votes before delegation");
        vm.prank(owner);
        token.delegate(owner);
        assertEq(token.getVotes(owner), INITIAL_SUPPLY, "self-delegation activates votes");

        vm.roll(block.number + 1);
        assertEq(
            token.getPastVotes(owner, block.number - 1),
            INITIAL_SUPPLY,
            "historical votes must reflect the delegation checkpoint"
        );
    }

    function test_TransferMovesHistoricalVotingPower() public {
        vm.prank(owner);
        token.delegate(owner);
        uint256 delegationBlock = block.number;

        vm.roll(block.number + 1);
        vm.prank(owner);
        token.transfer(other, 100e18);
        vm.roll(block.number + 1);

        assertEq(
            token.getPastVotes(owner, delegationBlock),
            INITIAL_SUPPLY,
            "pre-transfer snapshot must keep full voting power"
        );
        assertEq(token.getVotes(owner), INITIAL_SUPPLY - 100e18, "current votes must drop");
        assertEq(token.getVotes(other), 0, "recipient has no votes until it delegates");
        assertEq(token.getPastTotalSupply(block.number - 1), INITIAL_SUPPLY, "transfers must not change total supply");
    }

    function test_BurnReducesSupplyAndVotes() public {
        vm.prank(owner);
        token.delegate(owner);
        vm.roll(block.number + 1);

        vm.prank(owner);
        token.burn(10_000e18);

        assertEq(token.totalSupply(), INITIAL_SUPPLY - 10_000e18);
        assertEq(token.balanceOf(owner), INITIAL_SUPPLY - 10_000e18);

        vm.roll(block.number + 1);
        assertEq(
            token.getPastTotalSupply(block.number - 1),
            INITIAL_SUPPLY - 10_000e18,
            "historical supply must record the burn"
        );
    }
}
