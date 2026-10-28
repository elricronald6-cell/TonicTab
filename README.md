# TonicTab

Prepaid, transferable vouchers on BOT Chain.

A merchant opens a **counter**: a name, a denomination and a validity window.
Customers buy vouchers at that denomination and the BOT sits in escrow — not in
the merchant's pocket — until the voucher is spent.

## The two rules that matter

1. **Only the current holder can redeem.** The merchant cannot reach into a
   voucher and pull the funds; they are paid at the moment the holder spends it.
2. **The merchant never captures breakage.** A voucher left unspent past its
   expiry refunds to whoever holds it, in full, with no fee taken.

Vouchers transfer freely before expiry, so one bought as a gift does not need
the shop's permission to change hands. The holder index uses swap-and-pop, so
a wallet's list never carries stale entries after a transfer, redemption or
refund.

## Contract surface

| Call | Who | What it does |
|---|---|---|
| `openCounter(name, denomination, validitySecs)` | anyone | Becomes a merchant. Validity 1–365 days, denomination ≥ 0.001 BOT |
| `setSelling(id, bool)` / `updateDenomination(id, amount)` | merchant | Stop selling, or reprice future sales only |
| `buyVoucher(counterId, memo)` | anyone | Pays exactly the denomination into escrow |
| `transferVoucher(id, to)` | holder | Passes it on. Works while paused |
| `redeemVoucher(id)` | holder | Pays the merchant, minus `feeBps` (1.5% default, capped 5%) |
| `refundExpired(id)` | holder | Full value back after expiry, no fee |

`onlyOwner` covers pause/unpause, `setFeeBps` and `withdrawFees`, which is
bounded by `accumulatedFees` and can never touch escrowed voucher value.
A pause blocks new counters and new sales but never blocks a transfer,
redemption or refund — a voucher already sold is never trapped.

## Build and deploy

```bash
npm install
npx hardhat test          # 15 tests
npm run deploy:testnet    # BOT Chain testnet, chain 968
npm run deploy:mainnet    # BOT Chain mainnet, chain 677
```

Create `.env` from `.env.example` with your `PRIVATE_KEY` first. The deploy
script prints the network name **and** the chain id.

After deploying, paste the address into `CONTRACT_ADDRESS` in
`frontend/index.html`. For mainnet also swap the five network values flagged in
the comment block directly above it, and set `label` to `"MAINNET"`.

## Frontend

Single file, no build step, ethers v6 from cdnjs. **Frutiger Aero**: bright
daylight sky gradients, glossy liquid-glass orbs, a water horizon and pill
navigation. Counters and vouchers sit in horizontally scrolling shelves rather
than a grid, and nothing is a bordered card — every surface is a bubble with a
specular highlight.

The page ends with the BOT Chain ecosystem footer, carrying links to
**botchain.ai** and the **block explorer**. The explorer href is read from the
`NETWORK` config at the top of the file, so the five-value mainnet swap updates
it too. No chain ID is printed anywhere on the page — these sites move from
testnet to mainnet, so a rendered chain ID would be wrong half the time.
