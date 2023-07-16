import brownie

# Sample addresses
dai = "0x0000000000000000000000000000000000000041"
zoo = "0x0000000000000000000000000000000000000042"

def test_set_name_and_symbol(accounts, NftVotingPosition):
	name = 'Voting'
	symbol = 'VT'

	staking = NftVotingPosition.deploy(name, symbol, dai, zoo, {"from": accounts[0]})

	assert staking.name() == name
	assert staking.symbol() == symbol

	assert staking.zoo() == zoo
	assert staking.dai() == dai


def test_owner(accounts, NftVotingPosition):
	staking = NftVotingPosition.deploy("name", "symbol", dai, zoo, {"from": accounts[0]})

	assert staking.owner() == accounts[0]
