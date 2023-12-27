// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AssetToken is ERC20 {
    error AssetToken__onlyThunderLoan();
    error AssetToken__ExhangeRateCanOnlyIncrease(uint256 oldExchangeRate, uint256 newExchangeRate);
    error AssetToken__ZeroAddress();

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    IERC20 private immutable i_underlying;
    address private immutable i_thunderLoan;

    // The underlying per asset exchange rate
    // ie: s_exchangeRate = 2
    // means 1 asset token is worth 2 underlying tokens
    // e underlying == USDC
    // asset == shares
    uint256 private s_exchangeRate;
    uint256 public constant EXCHANGE_RATE_PRECISION = 1e18;
    uint256 private constant STARTING_EXCHANGE_RATE = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event ExchangeRateUpdated(uint256 newExchangeRate);

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier onlyThunderLoan() {
        if (msg.sender != i_thunderLoan) {
            revert AssetToken__onlyThunderLoan();
        }
        _;
    }

    modifier revertIfZeroAddress(address someAddress) {
        if (someAddress == address(0)) {
            revert AssetToken__ZeroAddress();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(
        address thunderLoan,
        IERC20 underlying, // @audit the tokens being deposited for flash loans
        // oh, are the ERC20s stored in AssetToken.sol in stead of thunderLoan.sol?
        // q where are the ERC20s stored?
        string memory assetName,
        string memory assetSymbol
    )
        ERC20(assetName, assetSymbol)
        revertIfZeroAddress(thunderLoan)
        revertIfZeroAddress(address(underlying))
    {
        i_thunderLoan = thunderLoan;
        i_underlying = underlying;
        s_exchangeRate = STARTING_EXCHANGE_RATE;
    }

    // e ok, only the thunderloan contract can mint and burn asset tokens
    //
    function mint(address to, uint256 amount) external onlyThunderLoan {
        _mint(to, amount);
    }

    function burn(address account, uint256 amount) external onlyThunderLoan {
        _burn(account, amount);
    }

    function transferUnderlyingTo(address to, uint256 amount) external onlyThunderLoan {
        // e weird ERC20s??
        // q what happens if USDC blacklists the thunderLoan contract?
        // q what happens if USDC transfers to the thunderLoan contract?
        // @follow-up
        // if a user is denylisted, too bad.
        // if a user is denylisted, and this affects other users, this is bad.
        i_underlying.safeTransfer(to, amount);
    }

    function updateExchangeRate(uint256 fee) external onlyThunderLoan {
        // 1. Get the current exchange rate
        // 2. How big the fee is should be divided by the total supply
        // 3. So if the fee is 1e18, and the total supply is 2e18, the exchange rate be multiplied by 1.5
        // if the fee is 0.5 ETH, and the total supply is 4, the exchange rate should be multiplied by 1.125
        // it should always go up, never down @audit --> We've got an invariant here!!!
        // q ok, but why?
        // newExchangeRate = oldExchangeRate * (totalSupply + fee) / totalSupply
        // newExchangeRate = 1 (4 + 0.5) / 4
        // newExchangeRate = 1.125

        // q what if totalSupply = 0?
        // this breaks the invariant is that an issue?
        uint256 newExchangeRate = s_exchangeRate * (totalSupply() + fee) / totalSupply();

        if (newExchangeRate <= s_exchangeRate) {
            revert AssetToken__ExhangeRateCanOnlyIncrease(s_exchangeRate, newExchangeRate);
        }
        s_exchangeRate = newExchangeRate;
        emit ExchangeRateUpdated(s_exchangeRate);
    }
    // @audit A potential issue arises when there is a significant burning of AssetTokens (reduction in total supply).
    // In such a scenario, the new exchange rate may be lower than the current exchange rate, triggering the revert
    // condition: ```if (newExchangeRate <= s_exchangeRate)```. This could prevent the exchange rate from adjusting
    // properly to reflect changes in the total supply.

    // To address this vulnerability, you might want to reconsider the logic around how the exchange rate is updated.
    // It's common for exchange rates in decentralized finance (DeFi) systems to be able to decrease under certain
    // conditions, especially when there are substantial changes in the total supply or other factors.

    // Consider whether the invariant of only allowing an increase in the exchange rate is a strict requirement for your
    // protocol. If not, you might need to design a mechanism that allows for both increases and decreases in the
    // exchange rate based on the underlying economic conditions.

    function getExchangeRate() external view returns (uint256) {
        return s_exchangeRate;
    }

    function getUnderlying() external view returns (IERC20) {
        return i_underlying;
    }
}

// notes by bigBagBoogy:
// User
// If a malicious actor takes a huge flash loan and bloats the totalSupply and as such the newExchangeRate?

// If a malicious actor takes a huge flash loan and artificially inflates the total supply of the AssetTokens, it could
// indeed impact the newExchangeRate as calculated in the updateExchangeRate function. Let's break down the potential
// scenario:

// Flash Loan Attack:

// A flash loan allows a user to borrow a large amount of assets without providing collateral as long as the borrowed
// funds are returned within the same transaction.
// Impact on updateExchangeRate:

// The updateExchangeRate function calculates the new exchange rate based on the total supply and a fee. If a malicious
// actor borrows a significant amount, leading to a massive increase in the total supply, the calculated newExchangeRate
// may also increase substantially.
// Potential Consequences:

// The consequences depend on the specific economic model of the protocol and how it reacts to changes in the total
// supply.
// If the protocol is designed to handle flash loan-induced changes gracefully, it might not be a severe issue. However,
// if the protocol assumes a relatively stable total supply, such extreme fluctuations could lead to unintended economic
// consequences.
// Risk of Manipulation:

// Flash loan attacks are a known vector for manipulation in decentralized finance (DeFi) protocols. Malicious actors
// may exploit price oracles, liquidity pools, and other mechanisms to their advantage.
// Security Implications:

// It's essential to assess whether such fluctuations in the total supply pose security risks or economic
// vulnerabilities. For example, consider the impact on token holders, arbitrageurs, and other participants in the
// system.
// Mitigation:

// Consider implementing mechanisms to mitigate the impact of flash loans, such as transactional constraints, fees, or
// rate limits on changes in the total supply.
