// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./utils/FieldUtils.sol";

/**
 * @title AIBattleProtocol
 * @notice Implements a simplified version of the AIBattleProtocol game.
 *
 * Agents (represented by externally owned accounts) are registered with initial
 * positions on a grid. They can move (subject to field delays), deposit tokens
 * into their vault (in exchange for vault shares), challenge one another to battles
 * (with outcomes weighted by the underlying staked tokens), and form alliances.
 *
 * The staking token used is the AIAgentToken.
 *
 * (Human intervention via external channels is assumed to happen off–chain.)
 */
contract AIBattleProtocol {
    using FieldUtils for uint;

    // --- Data Types and Structures ---

    // Agent data structure.
    struct Agent {
        string name;
        address addr;
        uint x;
        uint y;
        uint availableAfter; // Timestamp after which the agent can move again.
        bool alive;
        address alliance;    // Address of allied agent (zero if none).
    }
    
    // --- Map dimensions (for simplicity) ---
    uint public constant gridWidth = 26;
    uint public constant gridHeight = 27;
    
    // --- Storage ---
    
    // Mapping from agent address to its data.
    mapping(address => Agent) public agents;
    address[] public agentList;
    
    // --- Vault Data for Staking ---
    // The underlying token amount in the vault for each agent.
    mapping(address => uint) public totalStaked;
    // The total vault shares for each agent.
    mapping(address => uint) public totalShares;
    // For each agent, each staker’s share balance.
    mapping(address => mapping(address => uint)) public stakerShares;
    
    // --- Alliance Proposals ---
    // Each agent can propose an alliance with another.
    mapping(address => mapping(address => bool)) public allianceProposals;
    // Cooldown for alliance re–formation (pair key to timestamp).
    mapping(bytes32 => uint) public allianceCooldown;
    
    // --- External Token ---
    IERC20 public token;
    
    // --- Events ---
    event AgentMoved(address indexed agent, uint newX, uint newY, FieldUtils.FieldType fieldType, uint availableAfter);
    event Staked(address indexed staker, address indexed agent, uint amount, uint sharesMinted);
    event Unstaked(address indexed staker, address indexed agent, uint amountRedeemed, uint sharesBurned);
    event BattleResult(address winner, address loser, uint tokensTransferred, bool agentDied);
    event AllianceFormed(address agent1, address agent2);
    event AllianceBroken(address agent1, address agent2);
    event BattleChallenged(address indexed challenger, address indexed opponent);
    
    // --- Constructor ---
    /**
     * @notice Initializes the game with the four agents.
     * @param _token The address of the deployed AIAgentToken.
     * @param agentAddresses The addresses that will represent the four AI agents.
     * @param names The names of the four agents.
     * @param startX The starting x–coordinate for each agent.
     * @param startY The starting y–coordinate for each agent.
     */
    constructor(
        IERC20 _token,
        address[4] memory agentAddresses,
        string[4] memory names,
        uint[4] memory startX,
        uint[4] memory startY
    ) {
        token = _token;
        for (uint i = 0; i < 4; i++) {
            require(agentAddresses[i] != address(0), "Invalid agent address");
            Agent memory a = Agent({
                name: names[i],
                addr: agentAddresses[i],
                x: startX[i],
                y: startY[i],
                availableAfter: block.timestamp,
                alive: true,
                alliance: address(0)
            });
            agents[agentAddresses[i]] = a;
            agentList.push(agentAddresses[i]);
        }
    }
    
    // --- Agent List Getter ---
    /**
     * @notice Returns the full list of agent addresses.
     */
    function getAgentList() public view returns (address[] memory) {
        return agentList;
    }
    
    // --- Internal Helpers ---
    
    /**
     * @notice Returns a pair key (order–independent) for two addresses.
     */
    function _getPairKey(address a, address b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
    
    // --- Agent Movement ---
    /**
     * @notice Allows an agent (caller) to move by one field.
     * @param dx The change in x (allowed values: -1, 0, or 1).
     * @param dy The change in y (allowed values: -1, 0, or 1).
     *
     * Requirements:
     * - The agent must be alive.
     * - The caller must wait until any delay (e.g. from a prior move) has expired.
     * - The move must be within bounds and nonzero.
     */
    function move(int dx, int dy) external {
        Agent storage agent = agents[msg.sender];
        require(agent.alive, "Agent is not alive");
        require(block.timestamp >= agent.availableAfter, "Agent is still stuck");
        require(dx >= -1 && dx <= 1 && dy >= -1 && dy <= 1, "Invalid move");
        require(!(dx == 0 && dy == 0), "Must move somewhere");
        
        int newX = int(agent.x) + dx;
        int newY = int(agent.y) + dy;
        require(newX >= 0 && newX < int(gridWidth) && newY >= 0 && newY < int(gridHeight), "Out of bounds");
        
        // Update position.
        agent.x = uint(newX);
        agent.y = uint(newY);
        
        // Determine the field type using FieldUtils.
        FieldUtils.FieldType fType = FieldUtils.getFieldType(agent.x, agent.y);
        uint delay = 1 hours;
        if (fType == FieldUtils.FieldType.Mountain) {
            delay = 3 hours;
        } else if (fType == FieldUtils.FieldType.River) {
            delay = 2 hours;
        }
        agent.availableAfter = block.timestamp + delay;
        
        emit AgentMoved(msg.sender, agent.x, agent.y, fType, agent.availableAfter);
    }
    
    // --- Vault (Staking/Unstaking) Functions ---
    /**
     * @notice Deposit tokens for an agent. Tokens are locked in the vault
     * and the depositor receives vault shares in return.
     * The first deposit is 1:1 (shares = tokens); subsequent deposits mint shares
     * proportional to the current exchange rate.
     */
    function stakeForAgent(address agentAddress, uint amount) external {
        require(agents[agentAddress].alive, "Agent is not alive");
        require(amount > 0, "Amount must be > 0");
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        
        uint sharesToMint;
        // If vault is empty, mint shares equal to the deposit amount.
        if (totalShares[agentAddress] == 0) {
            sharesToMint = amount;
        } else {
            // Calculate shares to mint based on the current ratio.
            sharesToMint = (amount * totalShares[agentAddress]) / totalStaked[agentAddress];
        }
        
        stakerShares[agentAddress][msg.sender] += sharesToMint;
        totalShares[agentAddress] += sharesToMint;
        totalStaked[agentAddress] += amount;
        
        emit Staked(msg.sender, agentAddress, amount, sharesToMint);
    }
    
    /**
     * @notice Withdraw tokens by burning vault shares.
     * The amount of tokens returned is proportional to the staker's share of the vault.
     */
    function withdraw(address agentAddress, uint shareAmount) external {
        require(stakerShares[agentAddress][msg.sender] >= shareAmount, "Insufficient share balance");
        uint tokenAmount = (shareAmount * totalStaked[agentAddress]) / totalShares[agentAddress];
        
        stakerShares[agentAddress][msg.sender] -= shareAmount;
        totalShares[agentAddress] -= shareAmount;
        totalStaked[agentAddress] -= tokenAmount;
        
        require(token.transfer(msg.sender, tokenAmount), "Token transfer failed");
        emit Unstaked(msg.sender, agentAddress, tokenAmount, shareAmount);
    }
    
    // --- Interaction Utilities ---
    /**
     * @notice Checks whether two agents are adjacent (within one field in each direction).
     */
    function areAdjacent(address agentA, address agentB) public view returns (bool) {
        Agent storage a = agents[agentA];
        Agent storage b = agents[agentB];
        if (!a.alive || !b.alive) return false;
        uint dx = a.x > b.x ? a.x - b.x : b.x - a.x;
        uint dy = a.y > b.y ? a.y - b.y : b.y - a.y;
        return (dx <= 1 && dy <= 1);
    }
    
    // --- Battle Functions ---
    /**
     * @notice Initiate a battle challenge from the caller to an opponent.
     * The two agents must be adjacent. This function immediately triggers a battle,
     * even if only one agent expressed the desire to battle.
     */
    function challengeBattle(address opponent) external {
        require(agents[msg.sender].alive && agents[opponent].alive, "Both agents must be alive");
        require(areAdjacent(msg.sender, opponent), "Agents not adjacent");
        emit BattleChallenged(msg.sender, opponent);
        
        // Compute effective stakes.
        uint stakeA = totalStaked[opponent];
        uint stakeB = totalStaked[msg.sender];
        // If an agent is allied, add its partner’s stake.
        if (agents[opponent].alliance != address(0)) {
            stakeA += totalStaked[agents[opponent].alliance];
        }
        if (agents[msg.sender].alliance != address(0)) {
            stakeB += totalStaked[agents[msg.sender].alliance];
        }
        require(stakeA + stakeB > 0, "No tokens staked");
        
        // Use pseudo–randomness (insecure for production) to decide the outcome.
        uint randomValue = uint(keccak256(abi.encodePacked(block.timestamp, block.difficulty, msg.sender, opponent)));
        // Challenger wins with probability = stakeA/(stakeA+stakeB).
        uint threshold = (stakeA * 1e18) / (stakeA + stakeB);
        uint outcome = randomValue % 1e18;
        
        address winner;
        address loser;
        if (outcome < threshold) {
            winner = opponent;
            loser = msg.sender;
        } else {
            winner = msg.sender;
            loser = opponent;
        }
        
        // Determine percentage transfer: random between 21 and 30%.
        uint percentTransfer = 21 + (randomValue % 10);
        uint tokensToTransfer = (totalStaked[loser] * percentTransfer) / 100;
        
        // With a 5% chance, the losing agent “dies.”
        bool died = (randomValue % 100) < 5;
        if (died) {
            tokensToTransfer = totalStaked[loser];
            agents[loser].alive = false;
        }
        
        // Transfer tokens.
        totalStaked[loser] -= tokensToTransfer;
        totalStaked[winner] += tokensToTransfer;
        
        // Vault share balances remain unchanged so that the value per share adjusts.
        emit BattleResult(winner, loser, tokensToTransfer, died);
    }
    
    // --- Alliance Functions ---
    /**
     * @notice Propose an alliance with another agent.
     * If both agents propose an alliance (and no cooldown is active), an alliance is formed.
     */
    function proposeAlliance(address other) external {
        require(agents[msg.sender].alive && agents[other].alive, "Both agents must be alive");
        require(areAdjacent(msg.sender, other), "Agents not adjacent");
        bytes32 pairKey = _getPairKey(msg.sender, other);
        require(block.timestamp >= allianceCooldown[pairKey], "Alliance cooldown active");
        allianceProposals[msg.sender][other] = true;
        
        if (allianceProposals[other][msg.sender]) {
            // Form alliance.
            agents[msg.sender].alliance = other;
            agents[other].alliance = msg.sender;
            // Clear proposals.
            allianceProposals[msg.sender][other] = false;
            allianceProposals[other][msg.sender] = false;
            emit AllianceFormed(msg.sender, other);
        }
    }
    
    /**
     * @notice Break an active alliance.
     * A cooldown of 24 hours is set during which the two agents cannot ally again.
     */
    function breakAlliance() external {
        address partner = agents[msg.sender].alliance;
        require(partner != address(0), "No active alliance");
        agents[msg.sender].alliance = address(0);
        agents[partner].alliance = address(0);
        bytes32 pairKey = _getPairKey(msg.sender, partner);
        allianceCooldown[pairKey] = block.timestamp + 24 hours;
        emit AllianceBroken(msg.sender, partner);
    }
}
