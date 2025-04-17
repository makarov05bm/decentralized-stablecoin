-include .env

.PHONY: all test deploy

build:
	forge build

test:
	forge test

install:
	forge install Cyfrin/foundry-devops --no-commit && forge install transmissions11/solmate@v6 --no-commit && forge install smartcontractkit/chainlink-brownie-contracts@1.3.0 --no-commit && forge install foundry-rs/forge-std@v1.8.2 --no-commit

deploy-sepolia:
	@forge script script/DeployRaffle.s.sol:DeployRaffle --rpc-url $(SEPOLIA_RPC_URL) --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) --account sepoliaKey
