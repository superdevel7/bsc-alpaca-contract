// SPDX-License-Identifier: MIT
/**
  ∩~~~~∩ 
  ξ ･×･ ξ 
  ξ　~　ξ 
  ξ　　 ξ 
  ξ　　 “~～~～〇 
  ξ　　　　　　 ξ 
  ξ ξ ξ~～~ξ ξ ξ 
　 ξ_ξξ_ξ　ξ_ξξ_ξ
Alpaca Fin Corporation
*/

pragma solidity 0.8.11;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../../interfaces/ISwapFactoryLike.sol";
import "../../interfaces/ISwapPairLike.sol";
import "../../interfaces/IBaseV1Router01.sol";
import "../../interfaces/IStrategy.sol";
import "../../interfaces/IVault.sol";
import "../../interfaces/IMultiRewardWorker03.sol";

import "../../../utils/SafeToken.sol";
import "../../../utils/AlpacaMath.sol";

contract SolidlyStrategyAddTwoSidesOptimal is OwnableUpgradeable, ReentrancyGuardUpgradeable, IStrategy {
  using SafeToken for address;

  event LogSetWorkerOk(address[] indexed workers, bool isOk);

  ISwapFactoryLike public factory;
  IBaseV1Router01 public router;
  IVault public vault;

  mapping(address => bool) public okWorkers;

  /// @notice require that only allowed workers are able to do the rest of the method call
  modifier onlyWhitelistedWorkers() {
    require(okWorkers[msg.sender], "bad worker");
    _;
  }

  /// @dev Create a new add two-side optimal strategy instance.
  /// @param _router The WaultSwap Router smart contract.
  function initialize(IBaseV1Router01 _router, IVault _vault) external initializer {
    OwnableUpgradeable.__Ownable_init();
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    factory = ISwapFactoryLike(_router.factory());
    router = _router;
    vault = _vault;
  }

  /// @dev Compute optimal deposit amount
  /// @param amtA amount of token A desired to deposit
  /// @param amtB amonut of token B desired to deposit
  /// @param resA amount of token A in reserve
  /// @param resB amount of token B in reserve
  function optimalDeposit(
    uint256 amtA,
    uint256 amtB,
    uint256 resA,
    uint256 resB
  ) internal view returns (uint256 swapAmt, bool isReversed) {
    if (amtA * (resB) >= amtB * (resA)) {
      swapAmt = _optimalDepositA(amtA, amtB, resA, resB);
      isReversed = false;
    } else {
      swapAmt = _optimalDepositA(amtB, amtA, resB, resA);
      isReversed = true;
    }
  }

  /// @notice This function is written base on fee=998, feeDenom=1000
  /// @dev Compute optimal deposit amount helper
  /// @param amtA amount of token A desired to deposit
  /// @param amtB amonut of token B desired to deposit
  /// @param resA amount of token A in reserve
  /// @param resB amount of token B in reserve
  function _optimalDepositA(
    uint256 amtA,
    uint256 amtB,
    uint256 resA,
    uint256 resB
  ) internal pure returns (uint256) {
    require(amtA * (resB) >= amtB * (resA), "reversed");

    uint256 fee = amtA / 10000;
    uint256 _c = (amtA * resB) - (amtB * resA);
    uint256 c = _c / (amtB + resB);
    uint256 swapAmt = (5000 * (AlpacaMath.sqrt(399960001 * resA**2 + 399920004 * resA * c) - (19999 * resA))) /
      99980001;
    return swapAmt;
  }

  /// @dev Execute worker strategy. Take BaseToken + FarmingToken. Return LP tokens.
  /// @param data Extra calldata information passed along to this strategy.
  function execute(
    address, /* user */
    uint256,
    /* debt */
    bytes calldata data
  ) external override onlyWhitelistedWorkers nonReentrant {
    // 1. Find out what farming token we are dealing with.
    (uint256 farmingTokenAmount, uint256 minLPAmount) = abi.decode(data, (uint256, uint256));
    IMultiRewardWorker03 worker = IMultiRewardWorker03(msg.sender);
    address baseToken = worker.baseToken();
    address farmingToken = worker.farmingToken();
    ISwapPairLike lpToken = worker.lpToken();
    // 2. Approve router to do their stuffs
    baseToken.safeApprove(address(router), type(uint256).max);
    farmingToken.safeApprove(address(router), type(uint256).max);
    // 3. Compute the optimal amount of BaseToken and FarmingToken to be converted.
    vault.requestFunds(farmingToken, farmingTokenAmount);
    uint256 baseTokenBalance = baseToken.myBalance();

    if (baseTokenBalance > 0 && farmingToken.myBalance() > 0)
      router.addLiquidity(
        baseToken,
        farmingToken,
        false,
        baseToken.myBalance(),
        farmingToken.myBalance(),
        0,
        0,
        address(this),
        block.timestamp
      );

    uint256 swapAmt;
    bool isReversed;
    {
      (uint256 r0, uint256 r1, ) = lpToken.getReserves();
      (uint256 baseTokenReserve, uint256 farmingTokenReserve) = lpToken.token0() == baseToken ? (r0, r1) : (r1, r0);
      (swapAmt, isReversed) = optimalDeposit(
        baseToken.myBalance(),
        farmingToken.myBalance(),
        baseTokenReserve,
        farmingTokenReserve
      );
    }
    // 4. Convert between BaseToken and farming tokens
    address[] memory path = new address[](2);
    (path[0], path[1]) = isReversed ? (farmingToken, baseToken) : (baseToken, farmingToken);
    // 5. Swap according to path
    if (swapAmt > 0)
      router.swapExactTokensForTokensSimple(swapAmt, 0, path[0], path[1], false, address(this), block.timestamp);
    // 6. Mint more LP tokens and return all LP tokens to the sender.
    (, , uint256 moreLPAmount) = router.addLiquidity(
      baseToken,
      farmingToken,
      false,
      baseToken.myBalance(),
      farmingToken.myBalance(),
      0,
      0,
      address(this),
      block.timestamp
    );
    require(moreLPAmount >= minLPAmount, "insufficient LP tokens received");
    address(lpToken).safeTransfer(msg.sender, lpToken.balanceOf(address(this)));
    // 7. Reset approve to 0 for safety reason
    farmingToken.safeApprove(address(router), 0);
    baseToken.safeApprove(address(router), 0);
  }

  function setWorkersOk(address[] calldata workers, bool isOk) external onlyOwner {
    for (uint256 idx = 0; idx < workers.length; idx++) {
      okWorkers[workers[idx]] = isOk;
    }
    emit LogSetWorkerOk(workers, isOk);
  }
}
