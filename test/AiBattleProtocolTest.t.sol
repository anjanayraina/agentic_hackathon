// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/Token/AiAgentToken.sol";
import "../src/AiBattleProtocol.sol";

contract AIBattleProtocolTest is Test {
    AIAgentToken token;
    AIBattleProtocol protocol;

    // Pre–defined addresses for the four agents and a staker.
    address agent1 = address(0x1);
    address agent2 = address(0x2);
    address agent3 = address(0x3);
    address agent4 = address(0x4);
    address staker = address(0x5);

    function setUp() public {
        // Deploy the token contract.
        token = new AIAgentToken();

        // Fund the staker with tokens (transfer from deployer to staker).
        token.transfer(staker, 1000 * 1e18);

        // Choose starting positions such that agent1 and agent2 are adjacent.
        // For example: agent1 at (0,0), agent2 at (0,1), agent3 at (10,10), agent4 at (15,15)
        address[4] memory agentsArr = [agent1, agent2, agent3, agent4];
        string[4] memory names = ["Scootles", "Purrlock Paws", "Sir Gullihop", "Wanderleaf"];
        uint[4] memory startX = [uint(0), 0, 10, 15];
        uint[4] memory startY = [uint(0), 1, 10, 15];

        // Deploy the protocol contract.
        protocol = new AIBattleProtocol(IERC20(token), agentsArr, names, startX, startY);

        // Have the staker approve the protocol contract to spend tokens.
        vm.prank(staker);
        token.approve(address(protocol), 1000 * 1e18);
    }

    function testMove() public {
        // Agent1 (at (0,0)) moves by (1,0) to (1,0).
        vm.prank(agent1);
        protocol.move(1, 0);

        // Retrieve agent1's data.
        (string memory name, address addr, uint x, uint y, uint availableAfter, bool alive, address alliance) = protocol.agents(agent1);
        assertEq(x, 1, "Agent1 x-coordinate should be 1");
        assertEq(y, 0, "Agent1 y-coordinate should be 0");
    }

    function testStake() public {
        // staker deposits 100 tokens for agent1.
        uint stakeAmount = 100 * 1e18;
        vm.prank(staker);
        protocol.stakeForAgent(agent1, stakeAmount);

        // Check underlying vault balances.
        uint underlying = protocol.totalStaked(agent1);
        uint shares = protocol.totalShares(agent1);
        assertEq(underlying, stakeAmount, "Underlying tokens for agent1 should be 100 tokens");
        // For the first deposit, shares minted equal the deposit amount.
        assertEq(shares, stakeAmount, "Vault shares for agent1 should equal the deposit amount");
    }

    function testWithdraw() public {
        // Deposit 100 tokens for agent1.
        uint depositAmount = 100 * 1e18;
        vm.prank(staker);
        protocol.stakeForAgent(agent1, depositAmount);

        // Get the staker's shares for agent1.
        uint shares = protocol.stakerShares(agent1, staker);
        // Now withdraw all shares.
        vm.prank(staker);
        protocol.withdraw(agent1, shares);

        // After withdrawal, the vault's underlying balance and total shares should be 0.
        uint underlying = protocol.totalStaked(agent1);
        uint totalShares = protocol.totalShares(agent1);
        assertEq(underlying, 0, "Underlying tokens for agent1 should be 0 after withdrawal");
        assertEq(totalShares, 0, "Total vault shares for agent1 should be 0 after withdrawal");
        // The staker's share balance should also be 0.
        uint stakerShareBalance = protocol.stakerShares(agent1, staker);
        assertEq(stakerShareBalance, 0, "Staker's share balance should be 0 after withdrawal");
    }

    function testBattle() public {
        // staker deposits tokens for agent1 and agent2.
        uint depositAmount1 = 100 * 1e18;
        uint depositAmount2 = 50 * 1e18;
        vm.prank(staker);
        protocol.stakeForAgent(agent1, depositAmount1);
        vm.prank(staker);
        protocol.stakeForAgent(agent2, depositAmount2);

        // Agent1 challenges agent2 (agents are adjacent per starting positions).
        vm.prank(agent1);
        protocol.challengeBattle(agent2);

        // Agent2 accepts the battle.
        vm.prank(agent2);
        protocol.acceptBattle(agent1);

        // The sum of underlying tokens for agent1 and agent2 should remain constant.
        uint underlying1 = protocol.totalStaked(agent1);
        uint underlying2 = protocol.totalStaked(agent2);
        assertEq(underlying1 + underlying2, depositAmount1 + depositAmount2, "Total underlying tokens should remain constant after battle");
    }

    function testAlliance() public {
        // Agent1 and agent2 propose an alliance.
        vm.prank(agent1);
        protocol.proposeAlliance(agent2);
        vm.prank(agent2);
        protocol.proposeAlliance(agent1);

        // Check that the alliance is formed.
        ( , , , , , , address alliance1) = protocol.agents(agent1);
        ( , , , , , , address alliance2) = protocol.agents(agent2);
        assertEq(alliance1, agent2, "Agent1 should be allied with agent2");
        assertEq(alliance2, agent1, "Agent2 should be allied with agent1");

        // Agent1 breaks the alliance.
        vm.prank(agent1);
        protocol.breakAlliance();
        ( , , , , , , alliance1) = protocol.agents(agent1);
        ( , , , , , , alliance2) = protocol.agents(agent2);
        assertEq(alliance1, address(0), "Agent1 alliance should be cleared");
        assertEq(alliance2, address(0), "Agent2 alliance should be cleared");
    }
}
