# Foundry Charity Donations (Educational Project)

Short: an educational Solidity project that accepts ETH donations, forwards funds to a charity wallet, tracks donors, and periodically selects a random donor to receive an ERC‑721 Gift NFT using Chainlink VRF (v2+) and Chainlink Automation.

## Overview

- Purpose: Demonstrate building a small, testable smart contract system integrating Chainlink VRF and Automation with Foundry-based tests and scripts.
- Key contracts:
	- `src/Donations.sol` — collects donations, forwards to a charity wallet, tracks donors, requests randomness and mints a prize NFT to a randomly selected donor.
	- `src/GiftNFT.sol` — minimal ERC‑721 used to mint prize NFTs.
- Tests and scripts are written for Foundry (forge) and the repo includes example scripts under `script/` for deploying and managing Chainlink subscriptions.

## Features

- Accept ETH donations and immediately forward to a charity address.
- Track donors and donation totals for a selection round.
- Request secure randomness from Chainlink VRF to pick a winner.
- Mint and transfer a Gift NFT to the selected winner.
- Chainlink Automation (Keepers) compatible `checkUpkeep` / `performUpkeep` flow to trigger selection when conditions are met.

## Prerequisites

- Linux / macOS / Windows WSL
- Foundry (forge & cast). Install via:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

- Anvil (comes with Foundry) for local development and testing.
- A Sepolia RPC URL and a funded deployer private key for testnet deployment (or another testnet provider).
- (Optional) Chainlink account / UI access to create and fund VRF subscriptions for public testnets.
- Node/npm only required if you plan to run additional local tooling; not required for forge-based flows in this repo.

## Environment / Configuration

Create a `.env` file in the project root with the following variables for non-local deployments:

```env
# RPC and wallet
RPC_URL=https://sepolia.infura.io/v3/<INFURA_KEY>
PRIVATE_KEY=0xYOUR_PRIVATE_KEY

# Chainlink / VRF values (for Sepolia or your chosen network)
VRF_COORDINATOR_ADDRESS=0x...      # Chainlink VRF Coordinator for the network
VRF_KEY_HASH=0x...                  # gas lane / keyHash for VRF on the network
VRF_SUBSCRIPTION_ID=123            # subscription id you create for VRF

# Optional verification
ETHERSCAN_API_KEY=...
```


## Local development (Anvil)

1. Start Anvil (basic):

```bash
anvil
```

2. Build the project:

```bash
forge build
```

3. Run tests (unit + integration):

```bash
forge test -vv
```

4. Deploy locally using the included script (deploys contracts and uses local mocks if configured):

```bash
# Example: run the top-level deploy script against anvil and broadcast with the first anvil private key
forge script script/DeployDonations.s.sol --rpc-url http://127.0.0.1:8545 --private-key <ANVIL_PK> --broadcast -vvvv
```

Notes for local VRF behavior:
- The tests and the provided scripts assume a VRF coordinator mock is available for local testing. The script or test harness will deploy a mock coordinator when targeting a local chain if needed.
- You can simulate time passing and upkeep calls using Foundry's cheatcodes in tests (the repo tests already exercise these flows).

## Deploying to Sepolia (testnet)

High level checklist:

1. Create a Chainlink VRF v2 subscription (via Chainlink UI or scripts) on Sepolia.
2. Fund the subscription with LINK tokens (using faucet or test LINK on Sepolia).
3. Add your deployed `Donations` contract as a consumer to the subscription.
4. Deploy `Donations.sol` supplying the VRF Coordinator address, keyHash (gas lane), subscription id, callback gas limit and interval.
5. Ensure Automation (Keepers) is configured to call `checkUpkeep`/`performUpkeep` for your deployed contract, or call `performUpkeep` via a trusted operator / script.

Suggested commands (replace env values):

```bash
# Build first
forge build

# Deploy to Sepolia (example)
export RPC_URL="${RPC_URL}"
export PRIVATE_KEY="${PRIVATE_KEY}"

forge script script/DeployDonations.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

After deployment:
- Configure Chainlink Automation (Keepers) to monitor your contract's `checkUpkeep` and trigger `performUpkeep` when needed. On testnets you can register an Upkeep via the Chainlink UI.

## Running the included scripts

- `script/HelperConfig.s.sol` - convenience for network-specific constants and quick local config.
- `script/DeployDonations.s.sol` - deploy Donations and GiftNFT.
- `script/Interactions.s.sol` - helper scripts to create/fund a subscription and add a consumer.

Run a script with:

```bash
forge script script/Interactions.s.sol:CreateSubscription --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
```

Replace `CreateSubscription` with the exported script contract name present in the file (if multiple scripts are defined inside the file).

## Tests

- Unit tests are under `test/unit` and integration tests under `test/integration`.
- Run all tests with:

```bash
forge test -vv
```

If a test requires a local environment, run Anvil and point the tests to it (Foundry's default test runner uses in-memory chains for unit tests).

## Troubleshooting & Tips

- If you see a compiler warning about shadowed variables or unused parameters, run `forge build` and inspect file/line numbers — the repo aims to keep the code warning-free.
- If VRF requests appear to fail on a public testnet, verify your subscription is funded and that your contract has been added as a consumer.
- Use `console2.log` found in tests for helpful debugging output when running `forge test -vv`.


## License

MIT
