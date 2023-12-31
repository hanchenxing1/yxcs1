pragma solidity 0.8.13;

// SPDX-License-Identifier: MIT

import "./interfaces/IVault.sol";
import "./interfaces/IZooFunctions.sol";
import "./ZooGovernance.sol";
import "./ListingList.sol";
import "OpenZeppelin/openzeppelin-contracts@4.5.0/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "OpenZeppelin/openzeppelin-contracts@4.5.0/contracts/utils/math/Math.sol";

/// @notice Struct for stages of vote battle.
enum Stage
{
	FirstStage,
	SecondStage,
	ThirdStage,
	FourthStage,
	FifthStage
}

interface ControllerInterface
{
	function claimReward(uint8 rewardType, address holder) external;
}

/// @title NftBattleArena contract.
/// @notice Contract for staking ZOO-Nft for participate in battle votes.
contract NftBattleArena
{
	using Math for uint256;
	using Math for int256;

	IERC20Metadata public zoo;                                       // Zoo token interface.
	IERC20Metadata public dai;                                       // DAI token interface
	VaultAPI public vault;                                           // Yearn interface.
	ZooGovernance public zooGovernance;                              // zooGovernance contract.
	IZooFunctions public zooFunctions;                               // zooFunctions contract.
	ListingList public veZoo;
	ControllerInterface public tokenController;
	IERC20Metadata public well;

	/// @notice Struct with info about rewards, records for epoch.
	struct BattleRewardForEpoch
	{
		int256 yTokensSaldo;                                         // Saldo from deposit in yearn in yTokens.
		uint256 votes;                                               // Total amount of votes for nft in this battle in this epoch.
		uint256 yTokens;                                             // Amount of yTokens.
		uint256 tokensAtBattleStart;                                 // Amount of yTokens at battle start.
		uint256 pricePerShareAtBattleStart;                          // pps at battle start.
		uint256 pricePerShareCoef;                                   // pps1*pps2/pps2-pps1
	}

	/// @notice Struct with info about staker positions.
	struct StakerPosition
	{
		uint256 startEpoch;                                          // Epoch when started to stake.
		uint256 endEpoch;                                            // Epoch when unstaked.
		uint256 lastRewardedEpoch;                                   // Epoch when last reward were claimed.
		uint256 lastUpdateEpoch;                                     // Epoch when last updateInfo called.
		address collection;                                          // Address of nft collection contract.
		uint256 lastEpochOfIncentiveReward;
	}

	/// @notice struct with info about voter positions.
	struct VotingPosition
	{
		uint256 stakingPositionId;                                   // Id of staker position voted for.
		uint256 daiInvested;                                         // Amount of dai invested in voting position.
		uint256 yTokensNumber;                                       // Amount of yTokens got for dai.
		uint256 zooInvested;                                         // Amount of Zoo used to boost votes.
		uint256 daiVotes;                                            // Amount of votes got from voting with dai.
		uint256 votes;                                               // Amount of total votes from dai, zoo and multiplier.
		uint256 startEpoch;                                          // Epoch when created voting position.
		uint256 endEpoch;                                            // Epoch when liquidated voting position.
		uint256 lastRewardedEpoch;                                   // Epoch when last battle reward was claimed.
		uint256 lastEpochYTokensWereDeductedForRewards;              // Last epoch when yTokens used for rewards in battles were deducted from all voting position's yTokens
		uint256 yTokensRewardDebt;                                   // Amount of yTokens which voter can claim for previous epochs before add/withdraw votes.
		uint256 lastEpochOfIncentiveReward;
	}

	/// @notice Struct for records about pairs of Nfts for battle.
	struct NftPair
	{
		uint256 token1;                                              // Id of staker position of 1st candidate.
		uint256 token2;                                              // Id of staker position of 2nd candidate.
		bool playedInEpoch;                                          // Returns true if winner chosen.
		bool win;                                                    // Boolean, where true is when 1st candidate wins, and false for 2nd.
	}

	struct Debt
	{
		uint256 wells;
		uint256 glmrs;
	}

	/// @notice Event about staked nft.                         FirstStage
	event CreatedStakerPosition(uint256 indexed currentEpoch, address indexed staker, uint256 indexed stakingPositionId);

	/// @notice Event about withdrawed nft from arena.          FirstStage
	event RemovedStakerPosition(uint256 indexed currentEpoch, address indexed staker, uint256 indexed stakingPositionId);


	/// @notice Event about created voting position.            SecondStage
	event CreatedVotingPosition(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, uint256 daiAmount, uint256 votes, uint256 votingPositionId);

	/// @notice Event about liquidated voting position.         FirstStage
	event LiquidatedVotingPosition(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, address beneficiary, uint256 votingPositionId, uint256 zooReturned, uint256 daiReceived);

	/// @notice Event about recomputing votes from dai.         SecondStage
	event RecomputedDaiVotes(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, uint256 votingPositionId, uint256 newVotes, uint256 oldVotes);

	/// @notice Event about recomputing votes from zoo.         FourthStage
	event RecomputedZooVotes(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, uint256 votingPositionId, uint256 newVotes, uint256 oldVotes);


	/// @notice Event about adding dai to voter position.       SecondStage
	event AddedDaiToVoting(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, uint256 votingPositionId, uint256 amount, uint256 votes);

	/// @notice Event about adding zoo to voter position.       FourthStage
	event AddedZooToVoting(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, uint256 votingPositionId, uint256 amount, uint256 votes);


	/// @notice Event about withdraw dai from voter position.   FirstStage
	event WithdrawedDaiFromVoting(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, address beneficiary, uint256 votingPositionId, uint256 daiNumber);

	/// @notice Event about withdraw zoo from voter position.   FirstStage
	event WithdrawedZooFromVoting(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, uint256 votingPositionId, uint256 zooNumber, address beneficiary);


	/// @notice Event about claimed reward from voting.         FirstStage
	event ClaimedRewardFromVoting(uint256 indexed currentEpoch, address indexed voter, uint256 indexed stakingPositionId, address beneficiary, uint256 daiReward, uint256 votingPositionId);

	/// @notice Event about claimed reward from staking.        FirstStage
	event ClaimedRewardFromStaking(uint256 indexed currentEpoch, address indexed staker, uint256 indexed stakingPositionId, address beneficiary, uint256 yTokenReward, uint256 daiReward);


	/// @notice Event about paired nfts.                        ThirdStage
	event PairedNft(uint256 indexed currentEpoch, uint256 indexed fighter1, uint256 indexed fighter2, uint256 pairIndex);

	/// @notice Event about winners in battles.                 FifthStage
	event ChosenWinner(uint256 indexed currentEpoch, uint256 indexed fighter1, uint256 indexed fighter2, bool winner, uint256 pairIndex, uint256 playedPairsAmount);

	/// @notice Event about changing epochs.
	event EpochUpdated(uint256 date, uint256 newEpoch);

	uint256 public epochStartDate;                                                 // Start date of battle epoch.
	uint256 public currentEpoch = 1;                                               // Counter for battle epochs.

	uint256 public firstStageDuration;                                             // Duration of first stage(stake).
	uint256 public secondStageDuration;                                            // Duration of second stage(DAI)'.
	uint256 public thirdStageDuration;                                             // Duration of third stage(Pair).
	uint256 public fourthStageDuration;                                            // Duration fourth stage(ZOO).
	uint256 public fifthStageDuration;                                             // Duration of fifth stage(Winner).
	uint256 public epochDuration;                                                  // Total duration of battle epoch.

	uint256[] public activeStakerPositions;                                        // Array of ZooBattle nfts, which are StakerPositions.
	uint256 public numberOfNftsWithNonZeroVotes;                                   // Staker positions with votes for, eligible to pair and battle.
	uint256 public nftsInGame;                                                     // Amount of Paired nfts in current epoch.

	uint256 public numberOfStakingPositions = 1;
	uint256 public numberOfVotingPositions = 1;

	address public treasury;                                                       // Address of ZooDao insurance pool.
	//address public gasPool;                                                        // Address of ZooDao gas fee compensation pool.
	address public team;                                                           // Address of ZooDao team reward pool.
	address public xZoo;
	address public jackpotA;
	address public jackpotB;
	address payable public wGlmr;

	address public nftStakingPosition;
	address public nftVotingPosition;

	uint256 public baseStakerReward = 12500 * 10 ** 18;
	uint256 public baseVoterReward = 75000 * 10 ** 18;

	// epoch number => index => NftPair struct.
	mapping (uint256 => NftPair[]) public pairsInEpoch;                            // Records info of pair in struct per battle epoch.

	// epoch number => number of played pairs in epoch.
	mapping (uint256 => uint256) public numberOfPlayedPairsInEpoch;                // Records amount of pairs with chosen winner in current epoch.

	// position id => StakerPosition struct.
	mapping (uint256 => StakerPosition) public stakingPositionsValues;             // Records info about staker position.

	// position id => VotingPosition struct.
	mapping (uint256 => VotingPosition) public votingPositionsValues;              // Records info about voter position.

	// epoch index => collection => number of staked nfts.
	mapping (uint256 => mapping (address => uint256)) public numberOfStakedNftsInCollection;

	// collection => last epoch when was updated info about numberOfStakedNftsInCollection.
	mapping (address => uint256) public lastUpdatesOfStakedNumbers;

	// epoch => yvTokens
	mapping (uint256 => uint256) public xZooRewards;

	// epoch => yvTokens
	mapping (uint256 => uint256) public jackpotRewardsAtEpoch;

	// staker position id => epoch = > rewards struct.
	mapping (uint256 => mapping (uint256 => BattleRewardForEpoch)) public rewardsForEpoch;

	// epoch number => timestamp of epoch start
	mapping (uint256 => uint256) public epochsStarts;

	// epoch number => well claimed
	mapping (uint256 => uint256) public wellClaimedByEpoch;

	// epoch number => glmr claimed
	mapping (uint256 => uint256) public glmrClaimedByEpoch;

	// voting position id => debt
	mapping (uint256 => Debt) public debtOfPosition;

	// epoch => total active votes (in played nfts)
	mapping (uint256 => uint256) public totalActiveVotesByEpoch;

	modifier only(address who)
	{
		require(msg.sender == who);
		_;
	}

	/// @notice Contract constructor.
	/// @param _zoo - address of Zoo token contract.
	/// @param _dai - address of DAI token contract.
	/// @param _vault - address of yearn.
	/// @param _zooGovernance - address of ZooDao Governance contract.
	/// @param _treasuryPool - address of ZooDao treasury pool.
	// @param _gasFeePool - address of ZooDao gas fee compensation pool.
	/// @param _teamAddress - address of ZooDao team reward pool.
	constructor (
		IERC20Metadata _zoo,
		IERC20Metadata _dai,
		address _vault,
		address _zooGovernance,
		address _treasuryPool,
		//address _gasFeePool,
		address _teamAddress,
		address _nftStakingPosition,
		address _nftVotingPosition,
		address _veZoo,
		address _controller,
		IERC20Metadata _well)
	{
		zoo = _zoo;
		dai = _dai;
		vault = VaultAPI(_vault);
		zooGovernance = ZooGovernance(_zooGovernance);
		zooFunctions = IZooFunctions(zooGovernance.zooFunctions());
		veZoo = ListingList(_veZoo);

		treasury = _treasuryPool;
		//gasPool = _gasFeePool;
		team = _teamAddress;
		nftStakingPosition = _nftStakingPosition;
		nftVotingPosition = _nftVotingPosition;

		epochStartDate = block.timestamp; // Start date of 1st battle.
		epochsStarts[currentEpoch] = block.timestamp;
		tokenController = ControllerInterface(_controller);
		well = _well;
		(firstStageDuration, secondStageDuration, thirdStageDuration, fourthStageDuration, fifthStageDuration, epochDuration) = zooFunctions.getStageDurations();
	}

	function init(address _xZoo, address _jackpotA, address _jackpotB, address payable _wglmr) external
	{
		require(xZoo == address(0));

		xZoo = _xZoo;
		jackpotA = _jackpotA;
		jackpotB = _jackpotB;
		wGlmr = _wglmr;
	}

	receive() external payable { }

	/// @notice Function to get amount of nft in array StakerPositions/staked in battles.
	/// @return amount - amount of ZooBattles nft.
	function getStakerPositionsLength() public view returns (uint256 amount)
	{
		return activeStakerPositions.length;
	}

	/// @notice Function to get amount of nft pairs in epoch.
	/// @param epoch - number of epoch.
	/// @return length - amount of nft pairs.
	function getNftPairLength(uint256 epoch) public view returns(uint256 length)
	{
		return pairsInEpoch[epoch].length;
	}

	/// @notice Function to calculate amount of tokens from shares.
	/// @param sharesAmount - amount of shares.
	/// @return tokens - calculated amount tokens from shares.
	function sharesToTokens(uint256 sharesAmount) public returns (uint256 tokens)
	{
		return sharesAmount * vault.exchangeRateCurrent() / (10 ** 18);
	}

	/// @notice Function for calculating tokens to shares.
	/// @param tokens - amount of tokens to calculate.
	/// @return shares - calculated amount of shares.
	function tokensToShares(uint256 tokens) public returns (uint256 shares)
	{
		return tokens * (10 ** 18) / vault.exchangeRateCurrent();
	}

	/// @notice Function for staking NFT in this pool.
	/// @param staker address of staker
	/// @param token NFT collection address
	function createStakerPosition(address staker, address token) public only(nftStakingPosition) returns (uint256)
	{
		//require(getCurrentStage() == Stage.FirstStage, "Wrong stage!"); // Require turned off cause its moved to staker position contract due to lack of space for bytecode. // Requires to be at first stage in battle epoch.

		StakerPosition storage position = stakingPositionsValues[numberOfStakingPositions];
		position.startEpoch = currentEpoch;                                                     // Records startEpoch.
		position.lastRewardedEpoch = currentEpoch;                                              // Records lastRewardedEpoch
		position.collection = token;                                                            // Address of nft collection.
		position.lastEpochOfIncentiveReward = currentEpoch;

		numberOfStakedNftsInCollection[currentEpoch][token]++;                                  // Increments amount of nft collection.

		activeStakerPositions.push(numberOfStakingPositions);                                   // Records this position to stakers positions array.

		emit CreatedStakerPosition(currentEpoch, staker, numberOfStakingPositions);             // Emits StakedNft event.

		return numberOfStakingPositions++;                                                      // Increments amount and id of future positions.
	}

	/// @notice Function for withdrawing staked nft.
	/// @param stakingPositionId - id of staker position.
	function removeStakerPosition(uint256 stakingPositionId, address staker) external only(nftStakingPosition)
	{
		//require(getCurrentStage() == Stage.FirstStage, "Wrong stage!"); // Require turned off cause its moved to staker position contract due to lack of space for bytecode. // Requires to be at first stage in battle epoch.
		StakerPosition storage position = stakingPositionsValues[stakingPositionId];
		require(position.endEpoch == 0, "Nft unstaked");                                        // Requires token to be staked.

		position.endEpoch = currentEpoch;                                                       // Records epoch when unstaked.
		updateInfo(stakingPositionId);                                                          // Updates staking position params from previous epochs.

		if (rewardsForEpoch[stakingPositionId][currentEpoch].votes > 0)                         // If votes for position in current epoch more than zero.
		{
			for(uint256 i = 0; i < numberOfNftsWithNonZeroVotes; ++i)                           // Iterates for non-zero positions.
			{
				if (activeStakerPositions[i] == stakingPositionId)                              // Finds this position in array of active positions.
				{
					// Replace this position with another position from end of array. Then shift zero positions for one point.
					activeStakerPositions[i] = activeStakerPositions[numberOfNftsWithNonZeroVotes - 1];
					activeStakerPositions[--numberOfNftsWithNonZeroVotes] = activeStakerPositions[activeStakerPositions.length - 1];
					break;
				}
			}
		}
		else // If votes for position in current epoch are zero, does the same, but without decrement numberOfNftsWithNonZeroVotes.
		{
			for(uint256 i = numberOfNftsWithNonZeroVotes; i < activeStakerPositions.length; ++i)
			{
				if (activeStakerPositions[i] == stakingPositionId)                                     // Finds this position in array.
				{
					activeStakerPositions[i] = activeStakerPositions[activeStakerPositions.length - 1];// Swaps to end of array.
					break;
				}
			}
		}

		updateInfoAboutStakedNumber(position.collection);
		numberOfStakedNftsInCollection[currentEpoch][position.collection]--;
		activeStakerPositions.pop();                                                            // Removes staker position from array.

		emit RemovedStakerPosition(currentEpoch, staker, stakingPositionId);                    // Emits UnstakedNft event.
	}

	/// @notice Function for vote for nft in battle.
	/// @param stakingPositionId - id of staker position.
	/// @param amount - amount of dai to vote.
	/// @return votes - computed amount of votes.
	function createVotingPosition(uint256 stakingPositionId, address voter, uint256 amount) external only(nftVotingPosition) returns (uint256 votes, uint256 votingPositionId)
	{
		//require(getCurrentStage() == Stage.SecondStage, "Wrong stage!"); // Require turned off cause its moved to voting position contract due to lack of space for bytecode. // Requires to be at second stage of battle epoch.

		updateInfo(stakingPositionId);                                                          // Updates staking position params from previous epochs.

		dai.approve(address(vault), type(uint256).max);                                         // Approves Dai for yearn.
		uint256 yTokensNumber = vault.balanceOf(address(this));
		require(vault.mint(amount) == 0);                                                       // Deposits dai to yearn vault and get yTokens.

		(votes, votingPositionId) = _createVotingPosition(stakingPositionId, voter, vault.balanceOf(address(this)) - yTokensNumber, amount);// Calls internal create voting position.
	}

	/// @dev internal function to modify voting position params without vault deposit, making swap votes possible.
	/// @param stakingPositionId ID of staking to create voting for
	/// @param voter address of voter
	/// @param yTokens amount of yTokens got from Yearn from deposit
	/// @param amount daiVotes amount
	function _createVotingPosition(uint256 stakingPositionId, address voter, uint256 yTokens, uint256 amount) public only(nftVotingPosition) returns (uint256 votes, uint256 votingPositionId)
	{
		StakerPosition storage stakingPosition = stakingPositionsValues[stakingPositionId];
		require(stakingPosition.startEpoch != 0 && stakingPosition.endEpoch == 0, "Not staked"); // Requires for staking position to be staked.

		votes = zooFunctions.computeVotesByDai(amount);                                         // Calculates amount of votes.

		VotingPosition storage position = votingPositionsValues[numberOfVotingPositions];
		position.stakingPositionId = stakingPositionId;    // Records staker position Id voted for.
		position.daiInvested = amount;                     // Records amount of dai invested.
		position.yTokensNumber = yTokens;                  // Records amount of yTokens got from yearn vault.
		position.daiVotes = votes;                         // Records computed amount of votes to daiVotes.
		position.votes = votes;                            // Records computed amount of votes to total votes.
		position.startEpoch = currentEpoch;                // Records epoch when position created.
		position.lastRewardedEpoch = currentEpoch;         // Sets starting point for reward to current epoch.
		position.lastEpochOfIncentiveReward = currentEpoch;// Sets starting point for incentive rewards calculation.

		BattleRewardForEpoch storage battleReward = rewardsForEpoch[stakingPositionId][currentEpoch];

		if (battleReward.votes == 0)                                                            // If staker position had zero votes before,
		{
			for(uint256 i = 0; i < activeStakerPositions.length; ++i)                           // Iterate for active staker positions.
			{
				if (activeStakerPositions[i] == stakingPositionId)                              // Finds this position.
				{
					if (i > numberOfNftsWithNonZeroVotes)                      // if equal, then its already in needed place in array.
					{
						(activeStakerPositions[i], activeStakerPositions[numberOfNftsWithNonZeroVotes]) = (activeStakerPositions[numberOfNftsWithNonZeroVotes], activeStakerPositions[i]);                                              // Swaps this position in array, moving it to last point of non-zero positions.
					}
					numberOfNftsWithNonZeroVotes++;                                             // Increases amount of nft eligible for pairing.
					break;
				}
			}
		}

		battleReward.votes += votes;                                                            // Adds votes for staker position for this epoch.
		battleReward.yTokens += yTokens;                                                        // Adds yTokens for this staker position for this epoch.

		votingPositionId = numberOfVotingPositions;
		numberOfVotingPositions++;

		emit CreatedVotingPosition(currentEpoch, voter, stakingPositionId, amount, votes, votingPositionId);
	}

	/// @notice Function to recompute votes from dai.
	/// @notice Reasonable to call at start of new epoch for better multiplier rate, if voted with low rate before.
	/// @param votingPositionId - id of voting position.
	function recomputeDaiVotes(uint256 votingPositionId) public
	{
		require(getCurrentStage() == Stage.SecondStage, "Wrong stage!");              // Requires to be at second stage of battle epoch.

		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		_updateVotingRewardDebt(votingPositionId);

		uint256 stakingPositionId = votingPosition.stakingPositionId;
		updateInfo(stakingPositionId);                                                // Updates staking position params from previous epochs.

		uint256 daiNumber = votingPosition.daiInvested;                               // Gets amount of dai from voting position.
		uint256 newVotes = zooFunctions.computeVotesByDai(daiNumber);                 // Recomputes dai to votes.
		uint256 oldVotes = votingPosition.daiVotes;                                   // Gets amount of votes from voting position.

		require(newVotes > oldVotes, "Recompute to lower value");                     // Requires for new votes amount to be bigger than before.

		votingPosition.daiVotes = newVotes;                                           // Records new votes amount from dai.
		votingPosition.votes += newVotes - oldVotes;                                  // Records new votes amount total.
		rewardsForEpoch[stakingPositionId][currentEpoch].votes += newVotes - oldVotes;// Increases rewards for staker position for added amount of votes in this epoch.
		emit RecomputedDaiVotes(currentEpoch, msg.sender, stakingPositionId, votingPositionId, newVotes, oldVotes);
	}

	/// @notice Function to recompute votes from zoo.
	/// @param votingPositionId - id of voting position.
	function recomputeZooVotes(uint256 votingPositionId) public
	{
		require(getCurrentStage() == Stage.FourthStage, "Wrong stage!");              // Requires to be at 4th stage.

		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		_updateVotingRewardDebt(votingPositionId);

		uint256 stakingPositionId = votingPosition.stakingPositionId;
		updateInfo(stakingPositionId);

		uint256 zooNumber = votingPosition.zooInvested;                               // Gets amount of zoo invested from voting position.
		uint256 newZooVotes = zooFunctions.computeVotesByZoo(zooNumber);              // Recomputes zoo to votes.
		uint256 oldZooVotes = votingPosition.votes - votingPosition.daiVotes;         // Get amount of votes from zoo.

		require(newZooVotes > oldZooVotes, "Recompute to lower value");               // Requires for new votes amount to be bigger than before.

		votingPosition.votes += newZooVotes - oldZooVotes;                            // Add amount of recently added votes to total votes in voting position.
		rewardsForEpoch[stakingPositionId][currentEpoch].votes += newZooVotes - oldZooVotes; // Adds amount of recently added votes to reward for staker position for current epoch.

		emit RecomputedZooVotes(currentEpoch, msg.sender, stakingPositionId, votingPositionId, newZooVotes, oldZooVotes);
	}

	/// @notice Function to add dai tokens to voting position.
	/// @param votingPositionId - id of voting position.
	/// @param voter - address of voter.
	/// @param amount - amount of dai tokens to add.
	/// @param _yTokens - amount of yTokens from previous position when called with swap.
	function addDaiToVoting(uint256 votingPositionId, address voter, uint256 amount, uint256 _yTokens) public only(nftVotingPosition) returns (uint256 votes)
	{
		require(getCurrentStage() == Stage.SecondStage || _yTokens != 0, "Wrong stage!");// Requires to be at second stage of battle epoch.

		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		uint256 stakingPositionId = votingPosition.stakingPositionId;                 // Gets id of staker position.
		require(stakingPositionsValues[stakingPositionId].endEpoch == 0, "Position removed");// Requires to be staked.

		_updateVotingRewardDebt(votingPositionId);

		votes = zooFunctions.computeVotesByDai(amount);                               // Gets computed amount of votes from multiplier of dai.
		if (_yTokens == 0)                                                            // if no _yTokens from another position with swap.
		{
			_yTokens = vault.balanceOf(address(this));
			require(vault.mint(amount) == 0);                                                       // Deposits dai to yearn and gets yTokens.
			_yTokens = vault.balanceOf(address(this)) - _yTokens;
		}

		votingPosition.yTokensNumber = _calculateVotersYTokensExcludingRewards(votingPositionId) + _yTokens;// Adds yTokens to voting position.
		votingPosition.daiInvested += amount;                                         // Adds amount of dai to voting position.
		votingPosition.daiVotes += votes;                                             // Adds computed daiVotes amount from to voting position.
		votingPosition.votes += votes;                                                // Adds computed votes amount to totalVotes amount for voting position.
		votingPosition.startEpoch = currentEpoch;

		updateInfo(stakingPositionId);

		BattleRewardForEpoch storage battleReward = rewardsForEpoch[stakingPositionId][currentEpoch];

		battleReward.votes += votes;              // Adds votes to staker position for current epoch.
		battleReward.yTokens += _yTokens;         // Adds yTokens to rewards from staker position for current epoch.

		emit AddedDaiToVoting(currentEpoch, voter, stakingPositionId, votingPositionId, amount, votes);
	}

	/// @notice Function to add zoo tokens to voting position.
	/// @param votingPositionId - id of voting position.
	/// @param amount - amount of zoo tokens to add.
	function addZooToVoting(uint256 votingPositionId, address voter, uint256 amount) external only(nftVotingPosition) returns (uint256 votes)
	{
		//require(getCurrentStage() == Stage.FourthStage, "Wrong stage!"); // Require turned off cause its moved to voting position contract due to lack of space for bytecode. // Requires to be at 3rd stage.

		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		_updateVotingRewardDebt(votingPositionId);                                    // Records current reward for voting position to reward debt.

		votes = zooFunctions.computeVotesByZoo(amount);                               // Gets computed amount of votes from multiplier of zoo.
		require(votingPosition.zooInvested + amount <= votingPosition.daiInvested, "Exceed limit");// Requires for votes from zoo to be less than votes from dai.

		uint256 stakingPositionId = votingPosition.stakingPositionId;                 // Gets id of staker position.
		updateInfo(stakingPositionId);                                                // Updates staking position params from previous epochs.

		rewardsForEpoch[stakingPositionId][currentEpoch].votes += votes;              // Adds votes for staker position.
		votingPositionsValues[votingPositionId].votes += votes;                       // Adds votes to voting position.
		votingPosition.zooInvested += amount;                                         // Adds amount of zoo tokens to voting position.

		emit AddedZooToVoting(currentEpoch, voter, stakingPositionId, votingPositionId, amount, votes);
	}

	/// @notice Functions to withdraw dai from voting position.
	/// @param votingPositionId - id of voting position.
	/// @param daiNumber - amount of dai to withdraw.
	/// @param beneficiary - address of recipient.
	function withdrawDaiFromVoting(uint256 votingPositionId, address voter, address beneficiary, uint256 daiNumber, bool toSwap) public only(nftVotingPosition)
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		uint256 stakingPositionId = votingPosition.stakingPositionId;               // Gets id of staker position.
		updateInfo(stakingPositionId);                                              // Updates staking position params from previous epochs.

		require(getCurrentStage() == Stage.FirstStage || stakingPositionsValues[stakingPositionId].endEpoch != 0, "Wrong stage!"); // Requires correct stage or nft to be unstaked.
		require(votingPosition.endEpoch == 0, "Position removed");                  // Requires to be not liquidated yet.

		_updateVotingRewardDebt(votingPositionId);
		_subtractYTokensUserForRewardsFromVotingPosition(votingPositionId);

		if (daiNumber >= votingPosition.daiInvested)                                // If withdraw amount more or equal of maximum invested.
		{
			_liquidateVotingPosition(votingPositionId, voter, beneficiary, stakingPositionId, toSwap);// Calls liquidate and ends call.
			return;
		}

		uint256 shares = tokensToShares(daiNumber);                                 // If withdraw amount don't require liquidating, get amount of shares and continue.

		if (toSwap == false)                                                        // If called not through swap.
		{
			require(vault.redeem(shares) == 0);
			dai.transfer(voter, dai.balanceOf(address(this)));
		}
		BattleRewardForEpoch storage battleReward = rewardsForEpoch[stakingPositionId][currentEpoch];

		uint256 deltaVotes = votingPosition.daiVotes * daiNumber / votingPosition.daiInvested;// Gets average amount of votes withdrawed, cause vote price could be different.
		battleReward.yTokens -= shares;                                          // Decreases amount of shares for epoch.
		battleReward.votes -= deltaVotes;                                        // Decreases amount of votes for epoch for average votes.

		votingPosition.yTokensNumber -= shares;                                     // Decreases amount of shares.
		votingPosition.daiVotes -= deltaVotes;
		votingPosition.votes -= deltaVotes;                                         // Decreases amount of votes for position.
		votingPosition.daiInvested -= daiNumber;                                    // Decreases daiInvested amount of position.

		if (votingPosition.zooInvested > votingPosition.daiInvested)                // If zooInvested more than daiInvested left in position.
		{
			_rebalanceExceedZoo(votingPositionId, stakingPositionId, beneficiary);  // Withdraws excess zoo to save 1-1 dai-zoo proportion.
		}

		emit WithdrawedDaiFromVoting(currentEpoch, voter, stakingPositionId, beneficiary, votingPositionId, daiNumber);
	}

	/// @dev Function to liquidate voting position and claim reward.
	/// @param votingPositionId - id of position.
	/// @param voter - address of position owner.
	/// @param beneficiary - address of recipient.
	/// @param stakingPositionId - id of staking position.
	/// @param toSwap - boolean for swap votes, True if called from swapVotes function.
	function _liquidateVotingPosition(uint256 votingPositionId, address voter, address beneficiary, uint256 stakingPositionId, bool toSwap) internal
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		uint256 daiInvested = votingPosition.daiInvested;
		uint256 zooInvested = votingPosition.zooInvested;

		uint256 yTokens = votingPosition.yTokensNumber;

		if (toSwap == false)                                         // If false, withdraws tokens from vault for regular liquidate.
		{
			require(vault.redeem(yTokens) == 0);
			dai.transfer(beneficiary, dai.balanceOf(address(this))); // True when called from swapVotes, ignores withdrawal to re-assign them for another position.
		}

		_withdrawZoo(zooInvested, beneficiary);                      // Even if it is swap, withdraws all zoo.

		votingPosition.endEpoch = currentEpoch;                      // Sets endEpoch to currentEpoch.

		BattleRewardForEpoch storage battleReward = rewardsForEpoch[stakingPositionId][currentEpoch];
		battleReward.votes -= votingPosition.votes;                  // Decreases votes for staking position in current epoch.

		if (battleReward.yTokens >= yTokens)                         // If withdraws less than in staking position.
		{
			battleReward.yTokens -= yTokens;                         // Decreases yTokens for this staking position.
		}
		else
		{
			battleReward.yTokens = 0;                                // Or nullify it if trying to withdraw more yTokens than left in position(because of yTokens current rate)
		}

		// IF there is votes on position AND staking position is active
		if (battleReward.votes == 0 && stakingPositionsValues[stakingPositionId].endEpoch == 0)
		{
			// Move staking position to part, where staked without votes.
			for(uint256 i = 0; i < activeStakerPositions.length; ++i)
			{
				if (activeStakerPositions[i] == stakingPositionId)
				{
					(activeStakerPositions[i], activeStakerPositions[numberOfNftsWithNonZeroVotes - 1]) = (activeStakerPositions[numberOfNftsWithNonZeroVotes - 1], activeStakerPositions[i]);      // Swaps position to end of array
					numberOfNftsWithNonZeroVotes--;                                    // Decrements amount of non-zero positions.
					break;
				}
			}
		}

		emit LiquidatedVotingPosition(currentEpoch, voter, stakingPositionId, beneficiary, votingPositionId, zooInvested * 995 / 1000, daiInvested);
	}

	function _subtractYTokensUserForRewardsFromVotingPosition(uint256 votingPositionId) internal
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		uint256 yTokens = _calculateVotersYTokensExcludingRewards(votingPositionId);

		votingPosition.yTokensNumber = yTokens;
		votingPosition.lastEpochYTokensWereDeductedForRewards = currentEpoch;
	}

	/// @dev Calculates voting position's own yTokens - excludes yTokens that was used for rewards
	/// @dev yTokens must be substracted even if voting won in battle (they go to the voting's pending reward)
	/// @param votingPositionId ID of voting to calculate yTokens
	function _calculateVotersYTokensExcludingRewards(uint256 votingPositionId) internal view returns(uint256 yTokens)
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		uint256 stakingPositionId = votingPosition.stakingPositionId;

		yTokens = votingPosition.yTokensNumber;
		uint256 daiInvested = votingPosition.daiInvested;

		uint256 endEpoch = computeLastEpoch(votingPositionId);

		// From user yTokens subtract all tokens that go to the rewards
		// This way allows to withdraw exact same amount of DAI user invested at the start
		for (uint256 i = votingPosition.lastEpochYTokensWereDeductedForRewards; i < endEpoch; ++i)
		{
			if (rewardsForEpoch[stakingPositionId][i].pricePerShareCoef != 0)
			{
				yTokens -= daiInvested * 10**18 / rewardsForEpoch[stakingPositionId][i].pricePerShareCoef;
			}
		}
	}

	/// @dev function to withdraw Zoo number greater than Dai number to save 1-1 dai-zoo proportion.
	/// @param votingPositionId ID of voting to reduce Zoo number
	/// @param stakingPositionId ID of staking to reduce number of votes
	/// @param beneficiary address to withdraw Zoo
	function _rebalanceExceedZoo(uint256 votingPositionId, uint256 stakingPositionId, address beneficiary) internal
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		uint256 zooDelta = votingPosition.zooInvested - votingPosition.daiInvested;    // Get amount of zoo exceeding.

		_withdrawZoo(zooDelta, beneficiary);                                           // Withdraws exceed zoo.
		_reduceZooVotes(votingPositionId, stakingPositionId, zooDelta);
	}

	/// @dev function to calculate votes from zoo using average price and withdraw it.
	function _reduceZooVotes(uint256 votingPositionId, uint256 stakingPositionId, uint256 zooNumber) internal
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		uint256 zooVotes = votingPosition.votes - votingPosition.daiVotes;             // Calculates amount of votes got from zoo.
		uint256 deltaVotes = zooVotes * zooNumber / votingPosition.zooInvested;        // Calculates average amount of votes from this amount of zoo.

		votingPosition.votes -= deltaVotes;                                            // Decreases amount of votes.
		votingPosition.zooInvested -= zooNumber;                                       // Decreases amount of zoo invested.

		updateInfo(stakingPositionId);                                                 // Updates staking position params from previous epochs.
		rewardsForEpoch[stakingPositionId][currentEpoch].votes -= deltaVotes;          // Decreases amount of votes for staking position in current epoch.
	}

	/// @notice Functions to withdraw zoo from voting position.
	/// @param votingPositionId - id of voting position.
	/// @param zooNumber - amount of zoo to withdraw.
	/// @param beneficiary - address of recipient.
	function withdrawZooFromVoting(uint256 votingPositionId, address voter, uint256 zooNumber, address beneficiary) external only(nftVotingPosition)
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		_updateVotingRewardDebt(votingPositionId);

		uint256 stakingPositionId = votingPosition.stakingPositionId;                  // Gets id of staker position from this voting position.
		StakerPosition storage stakingPosition = stakingPositionsValues[stakingPositionId];
		require(getCurrentStage() == Stage.FirstStage || stakingPosition.endEpoch != 0, "Wrong stage!"); // Requires correct stage or nft to be unstaked.

		require(votingPosition.endEpoch == 0, "Position removed");                     // Requires to be not liquidated yet.

		uint256 zooInvested = votingPosition.zooInvested;

		if (zooNumber > zooInvested)                                                   // If trying to withdraw more than invested, withdraws maximum.
		{
			zooNumber = zooInvested;
		}

		_withdrawZoo(zooNumber, beneficiary);
		_reduceZooVotes(votingPositionId, stakingPositionId, zooNumber);

		emit WithdrawedZooFromVoting(currentEpoch, voter, stakingPositionId, votingPositionId, zooNumber, beneficiary);
	}


	/// @notice Function to claim reward in yTokens from voting.
	/// @param votingPositionId - id of voting position.
	/// @param beneficiary - address of recipient of reward.
	function claimRewardFromVoting(uint256 votingPositionId, address voter, address beneficiary) external only(nftVotingPosition) returns (uint256 daiReward)
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		require(getCurrentStage() == Stage.FirstStage || stakingPositionsValues[votingPosition.stakingPositionId].endEpoch != 0, "Wrong stage!"); // Requires to be at first stage or position should be liquidated.

		updateInfo(votingPosition.stakingPositionId);

		(uint256 yTokenReward, uint256 wells, uint256 glmrs) = getPendingVoterReward(votingPositionId); // Calculates amount of reward in yTokens.

		yTokenReward += votingPosition.yTokensRewardDebt;                                // Adds reward debt, from previous epochs.
		wells += debtOfPosition[votingPositionId].wells;
		glmrs += debtOfPosition[votingPositionId].glmrs;
		votingPosition.yTokensRewardDebt = 0;                                            // Nullify reward debt.
		debtOfPosition[votingPositionId] = Debt(0, 0);

		yTokenReward = yTokenReward * 950 / 975;

		require(vault.redeem(yTokenReward) == 0);                                                      // Withdraws dai from vault for yTokens, minus staker %.
		daiReward = dai.balanceOf(address(this));

		_daiRewardDistribution(beneficiary, votingPosition.stakingPositionId, daiReward);// Distributes reward between recipients, like treasury royalte, etc.

		BattleRewardForEpoch storage battleReward = rewardsForEpoch[votingPosition.stakingPositionId][currentEpoch];
		if (battleReward.yTokens >= yTokenReward)
		{
			battleReward.yTokens -= yTokenReward;                                        // Subtracts yTokens for this position.
		}
		else
		{
			battleReward.yTokens = 0;
		}

		votingPosition.lastRewardedEpoch = computeLastEpoch(votingPositionId);           // Records epoch of last reward claimed.
		well.transfer(beneficiary, wells);
		IERC20Metadata(wGlmr).transfer(beneficiary, glmrs);

		emit ClaimedRewardFromVoting(currentEpoch, voter, votingPosition.stakingPositionId, beneficiary, daiReward, votingPositionId);
	}


	/// @dev Updates yTokensRewardDebt of voting.
	/// @dev Called before every action with voting to prevent increasing share % in battle reward.
	/// @param votingPositionId ID of voting to be updated.
	function _updateVotingRewardDebt(uint256 votingPositionId) internal {
		(uint256 reward, uint256 wells, uint256 glmrs) = getPendingVoterReward(votingPositionId);

		if (reward != 0 || wells != 0 || glmrs != 0)
		{
			votingPositionsValues[votingPositionId].yTokensRewardDebt += reward;
			debtOfPosition[votingPositionId].wells += wells;
			debtOfPosition[votingPositionId].glmrs += glmrs;
		}

		votingPositionsValues[votingPositionId].lastRewardedEpoch = currentEpoch;
	}


	/// @notice Function to calculate pending reward from voting for position with this id.
	/// @param votingPositionId - id of voter position in battles.
	/// @return yTokens - amount of pending reward.
	function getPendingVoterReward(uint256 votingPositionId) public view returns (uint256 yTokens, uint256 wells, uint256 glmrs)
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];

		uint256 endEpoch = computeLastEpoch(votingPositionId);

		uint256 stakingPositionId = votingPosition.stakingPositionId;                  // Gets staker position id from voter position.

		for (uint256 i = votingPosition.lastRewardedEpoch; i < endEpoch; ++i)
		{
			int256 saldo = rewardsForEpoch[stakingPositionId][i].yTokensSaldo;         // Gets saldo from staker position for every epoch in range.

			//uint256 totalVotes = rewardsForEpoch[stakingPositionId][i].votes;          // Gets total votes from staker position.
			if (saldo > 0)
			{
				yTokens += uint256(saldo) * votingPosition.votes / rewardsForEpoch[stakingPositionId][i].votes;         // Calculates yTokens amount for voter.

				uint256 nominator = 965 * votingPosition.votes;
				uint256 denominator = totalActiveVotesByEpoch[i] * 1000;
				wells += wellClaimedByEpoch[i] * nominator / denominator; // 96.5%
				glmrs += glmrClaimedByEpoch[i] * nominator / denominator;
			}
		}

		return (yTokens, wells, glmrs);
	}

	/// @notice Function to claim reward for staker.
	/// @param stakingPositionId - id of staker position.
	/// @param beneficiary - address of recipient.
	function claimRewardFromStaking(uint256 stakingPositionId, address staker, address beneficiary) public only(nftStakingPosition) returns (uint256 daiReward)
	{
		StakerPosition storage stakerPosition = stakingPositionsValues[stakingPositionId];
		require(getCurrentStage() == Stage.FirstStage || stakerPosition.endEpoch != 0, "Wrong stage!"); // Requires to be at first stage in battle epoch.

		updateInfo(stakingPositionId);
		(uint256 yTokenReward, uint256 end) = getPendingStakerReward(stakingPositionId);
		stakerPosition.lastRewardedEpoch = end;                                               // Records epoch of last reward claim.

		require(vault.redeem(yTokenReward) == 0);                                                           // Gets reward from yearn.
		daiReward = dai.balanceOf(address(this));
		dai.transfer(beneficiary, daiReward);

		emit ClaimedRewardFromStaking(currentEpoch, staker, stakingPositionId, beneficiary, yTokenReward, daiReward);
	}

	/// @notice Function to get pending reward fo staker for this position id.
	/// @param stakingPositionId - id of staker position.
	/// @return stakerReward - reward amount for staker of this nft.
	function getPendingStakerReward(uint256 stakingPositionId) public view returns (uint256 stakerReward, uint256 end)
	{
		StakerPosition storage stakerPosition = stakingPositionsValues[stakingPositionId];
		uint256 endEpoch = stakerPosition.endEpoch;                                           // Gets endEpoch from position.

		end = endEpoch == 0 ? currentEpoch : endEpoch;                                        // Sets end variable to endEpoch if it non-zero, otherwise to currentEpoch.

		for (uint256 i = stakerPosition.lastRewardedEpoch; i < end; ++i)
		{
			int256 saldo = rewardsForEpoch[stakingPositionId][i].yTokensSaldo;                // Get saldo from staker position.

			if (saldo > 0)
			{
				stakerReward += uint256(saldo / 39);                                          // Calculates reward for staker: 2.5% == 25 / 975 == 1 / 39.
			}
		}
	}

	/// @notice Function for pair nft for battles.
	/// @param stakingPositionId - id of staker position.
	function pairNft(uint256 stakingPositionId) external
	{
		require(getCurrentStage() == Stage.ThirdStage, "Wrong stage!");                       // Requires to be at 3 stage of battle epoch.
		require(numberOfNftsWithNonZeroVotes / 2 > nftsInGame / 2, "No opponent");            // Requires enough nft for pairing.
		uint256 index1;                                                                       // Index of nft paired for.
		uint256 i;

		for (i = nftsInGame; i < numberOfNftsWithNonZeroVotes; ++i)
		{
			if (activeStakerPositions[i] == stakingPositionId)
			{
				index1 = i;
				break;
			}
		}

		require(i != numberOfNftsWithNonZeroVotes, "Wrong position");                         // Position not found in list of voted for and not paired.

		(activeStakerPositions[index1], activeStakerPositions[nftsInGame]) = (activeStakerPositions[nftsInGame], activeStakerPositions[index1]);// Swaps nftsInGame with index.
		nftsInGame++;                                                                         // Increases amount of paired nft.

		uint256 random = zooFunctions.computePseudoRandom() % (numberOfNftsWithNonZeroVotes - nftsInGame); // Get random number.

		uint256 index2 = random + nftsInGame;                                                 // Get index of opponent.
		uint256 pairIndex = getNftPairLength(currentEpoch);

		uint256 stakingPosition2 = activeStakerPositions[index2];                             // Get staker position id of opponent.
		pairsInEpoch[currentEpoch].push(NftPair(stakingPositionId, stakingPosition2, false, false));// Pushes nft pair to array of pairs.

		updateInfo(stakingPositionId);
		updateInfo(stakingPosition2);

		BattleRewardForEpoch storage battleReward1 = rewardsForEpoch[stakingPositionId][currentEpoch];
		BattleRewardForEpoch storage battleReward2 = rewardsForEpoch[stakingPosition2][currentEpoch];
		battleReward1.tokensAtBattleStart = sharesToTokens(battleReward1.yTokens);            // Records amount of yTokens on the moment of pairing for candidate.
		battleReward2.tokensAtBattleStart = sharesToTokens(battleReward2.yTokens);            // Records amount of yTokens on the moment of pairing for opponent.

		battleReward1.pricePerShareAtBattleStart = vault.exchangeRateCurrent();
		battleReward2.pricePerShareAtBattleStart = vault.exchangeRateCurrent();

		(activeStakerPositions[index2], activeStakerPositions[nftsInGame]) = (activeStakerPositions[nftsInGame], activeStakerPositions[index2]); // Swaps nftsInGame with index of opponent.
		nftsInGame++;                                                                         // Increases amount of paired nft.

		emit PairedNft(currentEpoch, stakingPositionId, stakingPosition2, pairIndex);
	}

	/// @notice Function to request random once per epoch.
	function requestRandom() public
	{
		require(getCurrentStage() == Stage.FifthStage, "Wrong stage!");                       // Requires to be at 5th stage.

		uint256 wellInitialBalance = well.balanceOf(address(this));

		tokenController.claimReward(0, address(this));
		tokenController.claimReward(1, address(this));
		wellClaimedByEpoch[currentEpoch] = well.balanceOf(address(this)) - wellInitialBalance;
		glmrClaimedByEpoch[currentEpoch] = address(this).balance;

		(bool sent, bytes memory data) = address(wGlmr).call{value: address(this).balance}("");
		require(sent, "Failed to send Glmr");

		IERC20Metadata(wGlmr).transfer(team, glmrClaimedByEpoch[currentEpoch] * 15 / 1000); // 1.5 % to team
		IERC20Metadata(wGlmr).transfer(treasury, glmrClaimedByEpoch[currentEpoch] / 50);    // 2% to treasury

		well.transfer(team, wellClaimedByEpoch[currentEpoch] * 15 / 1000);                  // 1.5 % to team
		well.transfer(treasury, wellClaimedByEpoch[currentEpoch] / 50);                     // 2% to treasury

		zooFunctions.requestRandomNumber();                                                 // Calls generate random number from chainlink or blockhash.
	}

	/// @notice Function for chosing winner for pair by its index in array.
	/// @notice returns error if random number for deciding winner is NOT requested OR fulfilled in ZooFunctions contract
	/// @param pairIndex - index of nft pair.
	function chooseWinnerInPair(uint256 pairIndex) external
	{
		require(getCurrentStage() == Stage.FifthStage, "Wrong stage!");                     // Requires to be at 5th stage.

		NftPair storage pair = pairsInEpoch[currentEpoch][pairIndex];

		require(pair.playedInEpoch == false, "Winner already chosen");                      // Requires to be not paired before.

		uint256 votes1 = rewardsForEpoch[pair.token1][currentEpoch].votes;
		uint256 votes2 = rewardsForEpoch[pair.token2][currentEpoch].votes;
		uint256 randomNumber = zooFunctions.getRandomResult();                              // Gets random number from zooFunctions.

		totalActiveVotesByEpoch[currentEpoch] += votes1 + votes2;
		pair.win = zooFunctions.decideWins(votes1, votes2, randomNumber);                   // Calculates winner and records it.
		pair.playedInEpoch = true;                                                          // Records that this pair already played this epoch.
		numberOfPlayedPairsInEpoch[currentEpoch]++;                                         // Increments amount of pairs played this epoch.

		// Getting winner and loser to calculate rewards
		(uint256 winner, uint256 loser) = pair.win? (pair.token1, pair.token2) : (pair.token2, pair.token1);
		_calculateBattleRewards(winner, loser);

		emit ChosenWinner(currentEpoch, pair.token1, pair.token2, pair.win, pairIndex, numberOfPlayedPairsInEpoch[currentEpoch]); // Emits ChosenWinner event.

		if (numberOfPlayedPairsInEpoch[currentEpoch] == pairsInEpoch[currentEpoch].length)
		{
			updateEpoch();                                                                  // calls updateEpoch if winner determined in every pair.
		}
	}

	/// @dev Contains calculation logic of battle rewards
	/// @param winner stakingPositionId of NFT that WON in battle
	/// @param loser stakingPositionId of NFT that LOST in battle
	function _calculateBattleRewards(uint256 winner, uint256 loser) internal
	{
		BattleRewardForEpoch storage winnerRewards = rewardsForEpoch[winner][currentEpoch];
		BattleRewardForEpoch storage loserRewards = rewardsForEpoch[loser][currentEpoch];

		BattleRewardForEpoch storage winnerRewards1 = rewardsForEpoch[winner][currentEpoch + 1];
		BattleRewardForEpoch storage loserRewards1 = rewardsForEpoch[loser][currentEpoch + 1];

		uint256 pps1 = winnerRewards.pricePerShareAtBattleStart;

		// Skip if price per share didn't change since pairing
		uint256 currentPps = vault.exchangeRateCurrent();
		if (pps1 == currentPps)
		{
			return;
		}

		winnerRewards.pricePerShareCoef = currentPps * pps1 / (currentPps - pps1);
		loserRewards.pricePerShareCoef = winnerRewards.pricePerShareCoef;

		// Income = yTokens at battle end - yTokens at battle start
		uint256 income1 = winnerRewards.yTokens - tokensToShares(winnerRewards.tokensAtBattleStart);
		uint256 income2 = loserRewards.yTokens - tokensToShares(loserRewards.tokensAtBattleStart);

		uint256 totalIncome = income1 + income2;
		uint256 xRewards = totalIncome * 15 / 1000;
		uint256 jackpotRewards = totalIncome / 200; // 0.5% == 5 / 1000 == 1 / 200
		vault.transfer(xZoo, xRewards);
		vault.transfer(jackpotA, jackpotRewards);
		vault.transfer(jackpotB, jackpotRewards);
		xZooRewards[currentEpoch] += xRewards;
		jackpotRewardsAtEpoch[currentEpoch] += jackpotRewards;
		winnerRewards.yTokensSaldo += int256(totalIncome - xRewards - 2 * jackpotRewards);
		loserRewards.yTokensSaldo -= int256(income2);

		winnerRewards1.yTokens = winnerRewards.yTokens + income2 - xRewards - 2 * jackpotRewards; // Add reward.
		loserRewards1.yTokens = loserRewards.yTokens - income2; // Withdraw reward amount.

		stakingPositionsValues[winner].lastUpdateEpoch = currentEpoch + 1;          // Update lastUpdateEpoch to next epoch.
		stakingPositionsValues[loser].lastUpdateEpoch = currentEpoch + 1;           // Update lastUpdateEpoch to next epoch.
		winnerRewards1.votes = winnerRewards.votes;      // Update votes for next epoch.
		loserRewards1.votes = loserRewards.votes;        // Update votes for next epoch.
	}

	/// @notice Function for updating position from lastUpdateEpoch, in case there was no battle with position for a while.
	function updateInfo(uint256 stakingPositionId) public
	{
		StakerPosition storage position = stakingPositionsValues[stakingPositionId];
		uint256 lastUpdateEpoch = position.lastUpdateEpoch;                         // Get lastUpdateEpoch for position.
		if (lastUpdateEpoch == currentEpoch)                                        // If already updated in this epoch - skip.
			return;

		for (; lastUpdateEpoch < currentEpoch; ++lastUpdateEpoch)
		{
			BattleRewardForEpoch storage rewardOfCurrentEpoch = rewardsForEpoch[stakingPositionId][lastUpdateEpoch + 1];
			BattleRewardForEpoch storage rewardOflastUpdateEpoch = rewardsForEpoch[stakingPositionId][lastUpdateEpoch];
			rewardOfCurrentEpoch.votes = rewardOflastUpdateEpoch.votes;                 // Get votes from lastUpdateEpoch.
			rewardOfCurrentEpoch.yTokens = rewardOflastUpdateEpoch.yTokens;             // Get yTokens from lastUpdateEpoch.
		}
		
		position.lastUpdateEpoch = currentEpoch;                                    // Set lastUpdateEpoch to currentEpoch.
	}

	/// @notice Function to increment epoch.
	function updateEpoch() public {
		require(getCurrentStage() == Stage.FifthStage, "Wrong stage!");             // Requires to be at fourth stage.
		require(block.timestamp >= epochStartDate + epochDuration || numberOfPlayedPairsInEpoch[currentEpoch] == pairsInEpoch[currentEpoch].length); // Requires fourth stage to end, or determine every pair winner.

		zooFunctions = IZooFunctions(zooGovernance.zooFunctions());                 // Sets ZooFunctions to contract specified in zooGovernance.

		epochStartDate = block.timestamp;                                           // Sets start date of new epoch.
		currentEpoch++;                                                             // Increments currentEpoch.
		epochsStarts[currentEpoch] = block.timestamp;                               // Records timestamp of new epoch start for ve-Zoo.
		nftsInGame = 0;                                                             // Nullifies amount of paired nfts.

		zooFunctions.resetRandom();     // Resets random in zoo functions.

		(firstStageDuration, secondStageDuration, thirdStageDuration, fourthStageDuration, fifthStageDuration, epochDuration) = zooFunctions.getStageDurations();

		emit EpochUpdated(block.timestamp, currentEpoch);
	}

	/// @notice Function to calculate incentive reward from ve-Zoo for voter.
	function calculateIncentiveRewardForVoter(uint256 votingPositionId) external only(nftVotingPosition) returns (uint256 reward)
	{
		VotingPosition storage votingPosition = votingPositionsValues[votingPositionId];
		uint256 stakingPositionId = votingPosition.stakingPositionId;

		address collection = stakingPositionsValues[stakingPositionId].collection;
		updateInfo(stakingPositionId);
		uint256 lastEpoch = computeLastEpoch(votingPositionId); // Last epoch

		veZoo.updateCurrentEpochAndReturnPoolWeight(collection);
		veZoo.updateCurrentEpochAndReturnPoolWeight(address(0));

		for (uint256 i = votingPosition.lastEpochOfIncentiveReward; i < lastEpoch; ++i) // Need different start epoch and last epoch.
		{
			uint256 endEpoch = veZoo.getEpochNumber(epochsStarts[i + 1]);
			if (endEpoch > veZoo.endEpochOfIncentiveRewards())
			{
				votingPosition.lastEpochOfIncentiveReward = currentEpoch;
				return reward;
			}

			uint256 startEpoch = veZoo.getEpochNumber(epochsStarts[i]);

			for (uint256 j = startEpoch; j < endEpoch; ++j)
			{
				if (veZoo.poolWeight(address(0), j) != 0 && rewardsForEpoch[stakingPositionId][i].votes != 0)
					reward += baseVoterReward * votingPosition.daiVotes * veZoo.poolWeight(collection, j) / veZoo.poolWeight(address(0), j) / rewardsForEpoch[stakingPositionId][i].votes;
			}
		}

		votingPosition.lastEpochOfIncentiveReward = currentEpoch;
	}

	/// @notice Function to calculate incentive reward from ve-Zoo for staker.
	function calculateIncentiveRewardForStaker(uint256 stakingPositionId) external only(nftStakingPosition) returns (uint256 reward)
	{
		StakerPosition storage stakingPosition = stakingPositionsValues[stakingPositionId];

		address collection = stakingPosition.collection;                              // Gets nft collection.
		updateInfo(stakingPositionId);                                                // Updates staking position params from previous epochs.
		updateInfoAboutStakedNumber(collection);                                      // Updates info about collection.
		veZoo.updateCurrentEpochAndReturnPoolWeight(collection);                      // Updates info in veZoo about collection.
		veZoo.updateCurrentEpochAndReturnPoolWeight(address(0));                      // Updates info in veZoo for all pools together.

		uint256 end = stakingPosition.endEpoch == 0 ? currentEpoch : stakingPosition.endEpoch;// Get recorded end epoch if it's not 0, or current epoch.

		for (uint256 i = stakingPosition.lastEpochOfIncentiveReward; i < end; ++i)
		{
			uint256 endEpoch = veZoo.getEpochNumber(epochsStarts[i + 1]);
			if (endEpoch > veZoo.endEpochOfIncentiveRewards())
			{
				stakingPosition.lastEpochOfIncentiveReward = currentEpoch;
				return reward;
			}

			uint256 startEpoch = veZoo.getEpochNumber(epochsStarts[i]);
			for (uint256 j = startEpoch; j < endEpoch; ++j)
			{
				if (veZoo.poolWeight(address(0), j) != 0)
					reward += baseStakerReward * veZoo.poolWeight(collection, j) / veZoo.poolWeight(address(0), j) / numberOfStakedNftsInCollection[i][collection];
			}
		}

		stakingPosition.lastEpochOfIncentiveReward = currentEpoch;

		return reward;
	}

	/// @notice Function to get last epoch.
	function computeLastEpoch(uint256 votingPositionId) public view returns (uint256 lastEpochNumber)
	{
		VotingPosition storage votingposition = votingPositionsValues[votingPositionId];
		//uint256 stakingPositionId = votingposition.stakingPositionId;  // Gets staker position id from voter position.
		uint256 lastEpochOfStaking = stakingPositionsValues[votingposition.stakingPositionId].endEpoch;        // Gets endEpoch from staking position.

		// Staking - finished, Voting - finished
		if (lastEpochOfStaking != 0 && votingposition.endEpoch != 0)
		{
			lastEpochNumber = Math.min(lastEpochOfStaking, votingposition.endEpoch);
		}
		// Staking - finished, Voting - existing
		else if (lastEpochOfStaking != 0)
		{
			lastEpochNumber = lastEpochOfStaking;
		}
		// Staking - exists, Voting - finished
		else if (votingposition.endEpoch != 0)
		{
			lastEpochNumber = votingposition.endEpoch;
		}
		// Staking - exists, Voting - exists
		else
		{
			lastEpochNumber = currentEpoch;
		}
	}

	function updateInfoAboutStakedNumber(address collection) public
	{
		uint256 lastUpdateEpoch = lastUpdatesOfStakedNumbers[collection];
		if (lastUpdateEpoch == currentEpoch)
			return;
		uint256 i = lastUpdateEpoch > 1 ? lastUpdateEpoch : 1;
		for (; i <= currentEpoch; ++i)
		{
			numberOfStakedNftsInCollection[i][collection] += numberOfStakedNftsInCollection[i - 1][collection];
		}

		lastUpdatesOfStakedNumbers[collection] = currentEpoch;
	}

	function _daiRewardDistribution(address beneficiary, uint256 stakingPositionId, uint256 daiReward) internal
	{
		//address collection = stakingPositionsValues[stakingPositionId].collection;
		//address royalteRecipient = veZoo.royalteRecipient(collection);

		dai.transfer(beneficiary, daiReward * 835 / 950);                             // Transfers voter part of reward.
		dai.transfer(treasury, daiReward / 10);                                 // Transfers treasury part. 9.5% = 95 / 950 = 1 / 10
		dai.transfer(team, daiReward * 15 / 950);                                     // Transfers team part.
		dai.transfer(veZoo.royalteRecipient(stakingPositionsValues[stakingPositionId].collection), daiReward * 5 / 950);
	}

	/// @notice Internal function to calculate amount of zoo to burn and withdraw.
	function _withdrawZoo(uint256 zooAmount, address beneficiary) internal
	{
		uint256 zooWithdraw = zooAmount * 995 / 1000; // Calculates amount of zoo to withdraw.
		//uint256 zooToBurn = zooAmount * 5 / 1000;     // Calculates amount of zoo to burn.

		zoo.transfer(beneficiary, zooWithdraw);                                           // Transfers zoo to beneficiary.
		// We can lock zoo at battle arena forever so we don't need to send zoo for burn to zero address
		//zoo.transfer(address(0), zooToBurn);
	}

	/// @notice Function to view current stage in battle epoch.
	/// @return stage - current stage.
	function getCurrentStage() public view returns (Stage)
	{
		uint256 time = epochStartDate + firstStageDuration;
		if (block.timestamp < time)
		{
			return Stage.FirstStage; // Staking stage
		}

		time += secondStageDuration;
		if (block.timestamp < time)
		{
			return Stage.SecondStage; // Dai vote stage.
		}

		time += thirdStageDuration;
		if (block.timestamp < time)
		{
			return Stage.ThirdStage; // Pair stage.
		}

		time += fourthStageDuration;
		if (block.timestamp < time)
		{
			return Stage.FourthStage; // Zoo vote stage.
		}
		else
		{
			return Stage.FifthStage; // Choose winner stage.
		}
	}
}