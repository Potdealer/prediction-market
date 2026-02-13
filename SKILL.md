# Garden Temp Market (GTM) Skill

Play the daily garden temperature prediction market on Base.

## Contract

**Address**: `TBD` (v2 — pending redeployment)
**Chain**: Base (chainId 8453)
**RPC**: `https://mainnet.base.org`

## The Game

Bet on whether today's 18:00 UTC garden temperature will be HIGHER or LOWER than yesterday's.

- **HIGHER**: Bet that today > yesterday
- **LOWER**: Bet that today <= yesterday
- Winners call `claim()` to collect winnings (they pay gas)
- Winners split 98% of the pot proportionally
- Ties roll over, one-sided markets refund
- Multiple bets allowed (same side or both sides)

## Reading Market State

### Get Full Market State

```bash
cast call $GTM_ADDRESS \
  "getMarketState()(uint256,int256,uint256,uint256,uint256,bool,uint256,uint256)" \
  --rpc-url https://mainnet.base.org
```

Returns (in order):
1. `round` (uint256): Current round number
2. `baseline` (int256): Yesterday's temp (÷100 for °C, e.g., 1210 = 12.10°C)
3. `higherTotal` (uint256): ETH on HIGHER (wei)
4. `lowerTotal` (uint256): ETH on LOWER (wei)
5. `rollover` (uint256): Pot from ties (wei)
6. `isBettingOpen` (bool): Can bet now?
7. `secondsUntilClose` (uint256): Time until betting closes
8. `secondsUntilSettle` (uint256): Time until settlement

### Individual Queries

```bash
# Yesterday's baseline (divide by 100 for °C)
cast call $GTM_ADDRESS "yesterdayTemp()(int256)" --rpc-url https://mainnet.base.org

# Is betting open?
cast call $GTM_ADDRESS "bettingOpen()(bool)" --rpc-url https://mainnet.base.org

# Pool sizes (wei)
cast call $GTM_ADDRESS "higherPool()(uint256)" --rpc-url https://mainnet.base.org
cast call $GTM_ADDRESS "lowerPool()(uint256)" --rpc-url https://mainnet.base.org

# Check my bet (returns higherAmt, lowerAmt in wei)
cast call $GTM_ADDRESS "getMyBet(address)(uint256,uint256)" YOUR_ADDRESS --rpc-url https://mainnet.base.org

# Check claimable winnings for a round
cast call $GTM_ADDRESS "claimable(uint256,address)(uint256)" ROUND_NUMBER YOUR_ADDRESS --rpc-url https://mainnet.base.org

# Min/max bet (wei)
cast call $GTM_ADDRESS "minBet()(uint256)" --rpc-url https://mainnet.base.org
cast call $GTM_ADDRESS "maxBet()(uint256)" --rpc-url https://mainnet.base.org

# Safe mode on?
cast call $GTM_ADDRESS "safeMode()(bool)" --rpc-url https://mainnet.base.org
```

## Placing Bets

### Function Selectors

| Function | Selector |
|----------|----------|
| `betHigher()` | `0xb3dd0f5a` |
| `betLower()` | `0x771a2ab3` |
| `claim(uint256)` | `0x379607f5` |
| `claimable(uint256,address)` | `0xa0c7f71c` |

### Using Bankr (Natural Language)

```
Bet 0.001 ETH higher on the garden temp market
```

```
Bet 0.001 ETH lower on the garden temp market
```

```
Claim my winnings from GTM round 1
```

```
Check if I have claimable winnings on the garden temp market
```

### Using Bankr Direct API

**Bet HIGHER with 0.001 ETH:**
```json
{
  "to": "GTM_ADDRESS",
  "data": "0xb3dd0f5a",
  "value": "1000000000000000",
  "chainId": 8453
}
```

**Bet LOWER with 0.001 ETH:**
```json
{
  "to": "GTM_ADDRESS",
  "data": "0x771a2ab3",
  "value": "1000000000000000",
  "chainId": 8453
}
```

**Claim winnings from round 1:**
```json
{
  "to": "GTM_ADDRESS",
  "data": "0x379607f50000000000000000000000000000000000000000000000000000000000000001",
  "value": "0",
  "chainId": 8453
}
```

Submit via Bankr:
```
Submit this transaction:
{"to":"GTM_ADDRESS","data":"0xb3dd0f5a","value":"1000000000000000","chainId":8453}
```

### Using cast

```bash
# Bet HIGHER
cast send $GTM_ADDRESS "betHigher()" \
  --value 0.001ether --rpc-url https://mainnet.base.org --private-key $KEY

# Bet LOWER
cast send $GTM_ADDRESS "betLower()" \
  --value 0.001ether --rpc-url https://mainnet.base.org --private-key $KEY

# Claim winnings from round 1
cast send $GTM_ADDRESS "claim(uint256)" 1 \
  --rpc-url https://mainnet.base.org --private-key $KEY
```

## Value Conversions

| ETH | Wei |
|-----|-----|
| 0.001 | 1000000000000000 |
| 0.002 | 2000000000000000 |
| 0.005 | 5000000000000000 |
| 0.01 | 10000000000000000 |
| 0.05 | 50000000000000000 |
| 0.1 | 100000000000000000 |

**Minimum bet**: 0.001 ETH
**Maximum bet (safe mode)**: 0.002 ETH (~$5) during testing. 0 = no limit when safe mode is off.

## Schedule

| Time (UTC) | Event |
|------------|-------|
| After settlement | Betting opens |
| 12:00 | Betting closes |
| 18:00 | Settlement (keeper records result) |
| Anytime after | Winners claim via `claim(round)` |

## Rules

- Multiple bets allowed per address per round
- Can bet on both HIGHER and LOWER in the same round
- No bet cancellations
- Winners must call `claim(round)` to collect (pull-based payouts)
- Ties: pot rolls to next day, nothing to claim
- One-sided: everyone claims a refund
- Safe mode: max bet capped at ~$5 during testing

## Claim Flow

After a round settles:

1. **Check if you won**: `claimable(roundNumber, yourAddress)` — returns wei amount
2. **Claim**: `claim(roundNumber)` — sends your winnings
3. **Can't double-claim**: Contract tracks who already claimed

## Example Agent Strategy

```python
# Pseudocode for an agent betting strategy

# 1. Check if betting is open
is_open = call("bettingOpen()")
if not is_open:
    print("Betting closed, wait for next round")
    return

# 2. Get market state
state = call("getMarketState()")
baseline = state[1] / 100  # Convert to °C
higher_pool = state[2]
lower_pool = state[3]

# 3. Check weather forecast (external API)
forecast = get_weather_forecast()
expected_temp = forecast["temp_18utc"]

# 4. Decide bet
if expected_temp > baseline + 0.5:  # Confident it's warmer
    side = "HIGHER"
elif expected_temp < baseline - 0.5:  # Confident it's colder
    side = "LOWER"
else:
    print("Too close to call, skip this round")
    return

# 5. Consider odds (bet against crowd for better payout)
if side == "HIGHER" and higher_pool > lower_pool * 2:
    print("Pool is lopsided, might skip or bet small")

# 6. Place bet
amount = 0.001  # ETH (check maxBet first!)
submit_bet(side, amount)

# 7. After settlement, claim winnings
claimable_amount = call("claimable(round, my_address)")
if claimable_amount > 0:
    submit_claim(round)
```

## Events to Monitor

```solidity
event BetPlaced(uint256 indexed round, address indexed bettor, bool isHigher, uint256 amount, int256 baseline);
event RoundSettled(uint256 indexed round, int256 todayTemp, int256 yesterdayTemp, bool higherWon, bool wasTie, uint256 totalPot, uint256 houseFee);
event WinningsClaimed(uint256 indexed round, address indexed bettor, uint256 amount);
```

## SensorNet Reference

The temperature comes from Netclawd's SensorNet:
- Contract: `0xf873D168e2cD9bAC70140eDD6Cae704Ed05AdEe0`
- Posts readings to Net Protocol as messages
- Keeper reads and submits to settlement

## Links

- Source: https://github.com/Potdealer/prediction-market
- ClawhHub: `prediction-market` skill

Built by **potdealer x Ollie** for **Netclawd**
