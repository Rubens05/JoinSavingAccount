### Joint Savings Account for Couples (USDT + Aave Earn) 💍💰 

JSAT is a **smart contract for couples (1:1)** that works as a **joint savings account**, inspired by traditional joint bank accounts and separation-of-assets principles.

It allows two people to:
- Deposit USDT together
- Earn yield automatically via **Aave v3**
- Pay shared expenses fairly (50/50)
- Keep **individual proportional balances**
- Separate funds cleanly if the relationship ends

Everything is handled **on-chain**, with **no third parties**, **no admins**, and **no possibility of external interference**.

---

## 🧪 Project Status

This project is a **Proof of Concept (PoC)**.

- ❌ Not deployed on mainnet
- ❌ Not audited
- ❌ Not intended for production use yet
- ✔️ Designed for learning, discussion and experimentation

Contributions, feedback and suggestions are welcome.

## ✨ Key Features

- 🧑‍🤝‍🧑 **Fixed pair (1:1)** — only two addresses, immutable
- 🔐 **Soulbound membership token**
  - ERC20 with total supply = 2
  - 1 token per partner
  - Non-transferable (cannot be sold or moved)
- 💵 **USDT Vault**
  - Individual deposits
  - Individual withdrawals
- 📈 **Automatic yield**
  - All USDT is deposited into **Aave v3**
  - Yield accrues automatically via aUSDT
- ⚖️ **Fair shared payments**
  - Shared expenses are split 50/50
  - If the amount is odd (in minimal units), the extra unit is paid by the partner with the higher balance
- 🧮 **Proportional accounting**
  - Yield is distributed proportionally using internal shares
- 💔 **Separation mode**
  - Shared payments are blocked
  - Individual deposits and withdrawals remain possible

---

## 🧠 Design Philosophy

- **No trust required**: rules are enforced by code
- **No external control**: no admins, no oracles, no upgrades
- **Gas-efficient**: minimal storage writes, no unnecessary state
- **Precise accounting**: uses smallest USDT unit (optimal granularity)
- **Real yield**: no fake APR, yield comes from Aave

---

## 🏗️ Contract Architecture

### 1. Membership Layer (ERC20 – Soulbound)
- Total supply: `2`
- Decimals: `0`
- Purpose: identity / authorization
- Transfers, approvals and allowances are disabled

### 2. Vault Layer (USDT)
- Holds USDT and aUSDT
- Deposits USDT into Aave
- Withdraws USDT from Aave when needed

### 3. Accounting Layer (Internal Shares)
- Each partner owns internal “shares”
- Shares represent a proportional claim on total assets
- Yield is automatically reflected in share value

---

## 🔒 Security Considerations

- Uses **OpenZeppelin** contracts
- Uses **SafeERC20** for USDT transfers
- Uses **ReentrancyGuard**
- No external callbacks
- No upgradeability (immutable logic)
- USDT approval pattern compatible with USDT quirks

---

## 📦 Requirements

- Solidity `^0.8.24`
- OpenZeppelin Contracts v5
- Aave v3 compatible network
- USDT deployed on the chosen network

---

## 🚀 Deploy Tutorial (Remix + Arbitrum)

### 1️⃣ Open Remix
Go to: https://remix.ethereum.org

### 2️⃣ Create the Contract File
- Create a new file: `JoinSavingToken.sol`
- Paste the full contract code into it

### 3️⃣ Configure the Compiler
- Go to **Solidity Compiler**
- Version: `0.8.24`
- Enable:
  - ✔️ Optimization (recommended)
- Click **Compile JoinSavingToken.sol**

### 4️⃣ Prepare Arbitrum Network
You will need:
- MetaMask installed
- Arbitrum One added to MetaMask
- Some ETH on Arbitrum for gas

### 5️⃣ Aave + USDT Addresses (Arbitrum One)

As of writing:

```text
USDT:       0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
Aave Pool:  0x794a61358D6845594F94dc1DB02A252b5b4814aD
aUSDT:      0x6ab707Aca953eDAeFBc4fD23bA73294241490620
