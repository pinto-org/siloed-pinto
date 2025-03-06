
<img src="./assets/sPINTO.png" alt="sPinto logo" width="120" />

# Siloed Pinto

Siloed Pinto is a fungible ERC4626 wrapper around an interest bearing asset.
Specifically, it wraps Pinto and captures Silo-derived yield. It captures a subset of the essential properties of low volatility money without sacrificing the upside of the Silo. The implementation follows industry standard for interest bearing stable coins and LSTs. The Pinto underlying a single sPINTO token will always be greater than or equal to the underlying Pinto in the past. In other words, the sPINTO token
is an up-only token, when denominated in Pinto.

## Implementation Overview
All underlying value is held as Pinto deposits. Depositing/Redeeming adds/removes deposits in a LIFO order. This means that users PDV (Pinto Denominated Value) is protected, but they are not entitled to the stalk increase relative to their initial deposit. Yield is accrued via mowing & planting which is performed through a claim operation that can be called directly or upon every deposit/redeem interaction.

## Installation
Siloed Pinto is build using the [Foundry](https://github.com/foundry-rs/foundry) framewrok. To install foundry run the following command:

```bash
curl -L https://foundry.paradigm.xyz | bash
```
Next, run `foundryup`.

## Building and Testing
Install dependencies:
```bash
forge install
```

Create a .env file and add your `BASE_RPC` url as seen in `.env.example`:
```bash
touch .env
```

Run the tests:
```bash
forge clean && forge test
```
Note that every time you run the tests you would need to clean the foundry artifacts first due to the usage of the [Foundry Upgrades](https://github.com/OpenZeppelin/openzeppelin-foundry-upgrades) plugin.

## License

[MIT](https://github.com/pinto-org/siloed-pinto/blob/main/LICENSE.txt)
