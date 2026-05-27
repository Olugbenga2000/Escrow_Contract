# ERC20 Escrow Contract

## About
This is an escrow smart contract that holds ERC-20 tokens while two parties trade, 
and releases or refunds the funds based on mutual confirmation. A neutral owner 
acts as mediator in the event of a dispute or unresolved escrow.

## How It Works

1. **Seller creates an escrow**: specifying the buyer's address, the ERC-20 token (must be a whitelisted token), the amount, the duration, and optional metadata (e.g. an IPFS 
   hash of the off-chain agreement).

2. **Buyer funds the escrow** : the buyer must deposit the full amount within 24 hours 
   of creation, ensuring both parties have on-chain input before funds are locked. 
   If the buyer does not fund within this window, the escrow is implicitly cancelled 
   and can be explicitly cancelled by anyone.

3. **Both parties confirm the outcome** : either party can call `confirm()` with 
   their preferred outcome (`RELEASE` or `REFUND`). A party can change their 
   confirmation at any time before expiry, as long as the escrow has not been 
   finalized. If both confirm the same outcome before the escrow expires, it 
   executes automatically:
   - `RELEASE` → funds (minus 1% platform fee) are sent to the seller.
   - `REFUND` → funds (minus 1% platform fee) are returned to the buyer.

4. **Disagreement or silence** : if the parties confirm different outcomes, or neither 
   acts before expiry, the owner steps in as mediator after the escrow expires and 
   decides the final outcome.

5. **Platform fee** : 1% is deducted from the escrowed amount on all finalized 
   escrows (release, refund, and mediation). This fee accumulates in the contract 
   and can be withdrawn by the owner at any time.

## Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd Escrow_Contract

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts

# Build
forge build

# Run tests
forge test
```

## Important Notes
- **Supported tokens only** : only standard ERC-20 tokens are supported. 
  Fee-on-transfer, rebase, and tokens with non-standard behavior are not 
  supported.
- **Trusted mediator** : the owner is trusted to act fairly when mediating 
  disputes.
- **No token recovery** : any tokens sent to the contract directly without 
  using the proper functions will be permanently lost. Always use 
  `fundEscrow()` to deposit funds.
- **Immutable owner** : the owner address is set at deployment and cannot 
  be changed.
- **Fee on all outcomes** : the 1% platform fee applies to releases, 
  refunds, and mediations alike.

## Possible Improvements

- **Signature-based escrow creation**: allow the seller and buyer to sign off-chain messages to signify consent, enabling a third party to create the escrow on-chain in a single transaction without requiring two separate on-chain interactions from both parties.

- **Native token support**: extend the contract to support ETH/native token escrows in addition to ERC-20 tokens.

- **Configurable platform fee**: allow the owner to adjust the platform fee within a defined cap, rather than hardcoding 1% at deployment.

- **Custom mediators**: allow escrow participants to designate their own trusted mediator per escrow instead of defaulting to the contract owner.

- **Multi-token escrows**: allow a single escrow to hold multiple token types simultaneously, useful for trade agreements involving more than one asset.
