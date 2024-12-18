// SPDX-License-Identifier: BUSL
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

pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import "./interfaces/IPriceHelper.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IWorker02.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IWNativeRelayer.sol";
import "./interfaces/IDeltaNeutralVaultConfig.sol";
import "./interfaces/IFairLaunch.sol";
import "../utils/SafeToken.sol";
import "../utils/Math.sol";

contract DeltaNeutralVault is ERC20Upgradeable, ReentrancyGuardUpgradeable, OwnableUpgradeable {
  /// @notice Libraries
  using SafeToken for address;

  /// @dev Events
  event LogInitializePositions(address indexed _from, uint256 _stableVaultPosId, uint256 _assetVaultPosId);
  event LogDeposit(
    address indexed _from,
    address indexed _shareReceiver,
    uint256 _shares,
    uint256 _stableTokenAmount,
    uint256 _assetTokenAmount
  );
  event LogWithdraw(address indexed _shareOwner, uint256 _minStableTokenAmount, uint256 _minAssetTokenAmount);
  event LogRebalance(uint256 _equityBefore, uint256 _equityAfter);

  /// @dev Errors
  error Unauthorized(address _caller);
  error PositionsAlreadyInitialized();
  error PositionsNotInitialized();
  error InvalidPositions(address _vault, uint256 _positionId);
  error UnsafePositionEquity();
  error UnsafePositionValue();
  error UnsafeDebtValue();
  error UnsafeDebtRatio();
  error UnsafeOutstanding(address _token, uint256 _amountBefore, uint256 _amountAfter);
  error PositionsIsHealthy();
  error InsufficientTokenReceived(address _token, uint256 _requiredAmount, uint256 _receivedAmount);
  error InsufficientShareReceived(uint256 _requiredAmount, uint256 _receivedAmount);

  struct Outstanding {
    uint256 stableAmount;
    uint256 assetAmount;
    uint256 nativeAmount;
  }

  struct PositionInfo{
    uint256 stablePositionEquity;
    uint256 stablePositionDebtValue;
    uint256 assetPositionEquity;
    uint256 assetPositionDebtValue;
  }

  /// @dev constants
  uint8 private constant ACTION_WORK = 1;
  uint8 private constant ACTION_WRAP = 2;

  address private lpToken;
  address public stableVault;
  address public assetVault;

  address public stableVaultWorker;
  address public assetVaultWorker;

  address public stableToken;
  address public assetToken;
  address public alpacaToken;

  uint256 public stableVaultPosId;
  uint256 public assetVaultPosId;

  IPriceHelper public priceHelper;

  IDeltaNeutralVaultConfig public config;

  /// @dev mutable
  bool private OPENING;

  /// @dev Require that the caller must be an EOA account if not whitelisted.
  modifier onlyEOAorWhitelisted() {
    if (msg.sender != tx.origin && !config.whitelistedCallers(msg.sender)) {
      revert Unauthorized(msg.sender);
    }
    _;
  }

  /// @dev Require that the caller must be a rebalancer account.
  modifier onlyRebalancers() {
    if (!config.whitelistedRebalancers(msg.sender)) revert Unauthorized(msg.sender);
    _;
  }

  /// @notice Initialize Delta Neutral vault.
  /// @param _name Name.
  /// @param _symbol Symbol.
  /// @param _stableVault Address of stable vault.
  /// @param _assetVault Address of asset vault.
  /// @param _stableVaultWorker Address of stable worker.
  /// @param _stableVaultWorker Address of asset worker.
  /// @param _lpToken Address stable and asset token pair.
  /// @param _alpacaToken Alpaca token address.
  /// @param _priceHelper Price helper address.
  /// @param _config The address of delta neutral vault config.
  function initialize(
    string calldata _name,
    string calldata _symbol,
    address _stableVault,
    address _assetVault,
    address _stableVaultWorker,
    address _assetVaultWorker,
    address _lpToken,
    address _alpacaToken,
    IPriceHelper _priceHelper,
    IDeltaNeutralVaultConfig _config
  ) external initializer {
    OwnableUpgradeable.__Ownable_init();
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
    ERC20Upgradeable.__ERC20_init(_name, _symbol);

    stableVault = _stableVault;
    assetVault = _assetVault;

    stableToken = IVault(_stableVault).token();
    assetToken = IVault(_assetVault).token();
    alpacaToken = _alpacaToken;

    stableVaultWorker = _stableVaultWorker;
    assetVaultWorker = _assetVaultWorker;

    lpToken = _lpToken;

    priceHelper = _priceHelper;
    config = _config;
  }

  /// @notice initialize delta neutral vault positions.
  /// @param _minShareReceive Minimum share that _shareReceiver must receive.
  /// @param _stableTokenAmount Amount of stable token transfer to vault.
  /// @param _assetTokenAmount Amount of asset token transfer to vault.
  /// @param _data The calldata to pass along to the proxy action for more working context.
  function initPositions(
    uint256 _minShareReceive,
    uint256 _stableTokenAmount,
    uint256 _assetTokenAmount,
    bytes calldata _data
  ) external payable onlyOwner {
    if (stableVaultPosId != 0 || assetVaultPosId != 0) {
      revert PositionsAlreadyInitialized();
    }

    OPENING = true;
    stableVaultPosId = IVault(stableVault).nextPositionID();
    assetVaultPosId = IVault(assetVault).nextPositionID();

    deposit(msg.sender, _minShareReceive, _stableTokenAmount, _assetTokenAmount, _data);

    OPENING = false;

    emit LogInitializePositions(msg.sender, stableVaultPosId, assetVaultPosId);
  }

  /// @notice Get token from msg.sender.
  /// @param _token token to transfer.
  /// @param _amount amount to transfer.
  function _transferTokenToVault(address _token, uint256 _amount) internal {
    if (_token == config.getWrappedNativeAddr()) {
      IWETH(config.getWrappedNativeAddr()).deposit{ value: _amount }();
    } else {
      SafeToken.safeTransferFrom(_token, msg.sender, address(this), _amount);
    }
  }

  /// @notice return token to share owenr.
  /// @param _to receiver address.
  /// @param _token token to transfer.
  /// @param _amount amount to transfer.
  function _transferTokenToShareOwner(
    address _to,
    address _token,
    uint256 _amount
  ) internal {
    if (_token == config.getWrappedNativeAddr()) {
      SafeToken.safeTransferETH(_to, _amount);
    } else {
      SafeToken.safeTransfer(_token, _to, _amount);
    }
  }

  // SWC-114-Transaction Order Dependence
  /// @notice Deposit to delta neutral vault.
  /// @param _shareReceiver Addresses to be receive share.
  /// @param _minShareReceive Minimum share that _shareReceiver must receive.
  /// @param _stableTokenAmount Amount of stable token transfer to vault.
  /// @param _assetTokenAmount Amount of asset token transfer to vault.
  /// @param _data The calldata to pass along to the proxy action for more working context.
  // 
  function deposit(
    address _shareReceiver,
    uint256 _minShareReceive,
    uint256 _stableTokenAmount,
    uint256 _assetTokenAmount,
    bytes calldata _data
  ) public payable onlyEOAorWhitelisted nonReentrant returns (uint256 _shares) {

    PositionInfo memory _positionInfoBefore = positionInfo();
    Outstanding memory _outstandingBefore = _outstanding();
    _outstandingBefore.nativeAmount = _outstandingBefore.nativeAmount - msg.value;

    // 1. transfer tokens from user to vault
    _transferTokenToVault(stableToken, _stableTokenAmount);
    _transferTokenToVault(assetToken, _assetTokenAmount);

    // 2. mint share for shareReceiver
    uint256 _depositValue = ((_stableTokenAmount * priceHelper.getTokenPrice(stableToken)) +
      (_assetTokenAmount * priceHelper.getTokenPrice(assetToken))) / 1e18;

    uint256 _shares = valueToShare(_depositValue);
    if (_shares < _minShareReceive) {
      revert InsufficientShareReceived(_minShareReceive, _shares);
    }

    _mint(_shareReceiver, _shares);
    
    {
      // 3. call execute to do more work.
      // Perform the actual work, using a new scope to avoid stack-too-deep errors.
      (uint8[] memory actions, uint256[] memory values, bytes[] memory _datas) = abi.decode(
        _data,
        (uint8[], uint256[], bytes[])
      );
      _execute(actions, values, _datas);
    }

    // 4. sanity check
    _depositHealthCheck(
      _depositValue,
      _positionInfoBefore,
      positionInfo()
    );
    _outstandingCheck(_outstandingBefore, _outstanding());
    
    emit LogDeposit(msg.sender, _shareReceiver, _shares, _stableTokenAmount, _assetTokenAmount);
    return _shares;
  }

  // SWC-114-Transaction Order Dependence
  /// @notice Withdraw from delta neutral vault.
  /// @param _shareAmount Amount of share to withdraw from vault.
  /// @param _minStableTokenAmount Minimum stable token shareOwner expect to receive.
  /// @param _minAssetTokenAmount Minimum asset token shareOwner expect to receive.
  /// @param _data The calldata to pass along to the proxy action for more working context.
  function withdraw(
    uint256 _shareAmount,
    uint256 _minStableTokenAmount,
    uint256 _minAssetTokenAmount,
    bytes calldata _data
  ) public onlyEOAorWhitelisted nonReentrant returns (uint256 _withdrawValue) {

    address _shareOwner = msg.sender;
    PositionInfo memory _positionInfoBefore = positionInfo();
    Outstanding memory _outstandingBefore = _outstanding();

    uint256 _shareValue = shareToValue(_shareAmount);
    _burn(_shareOwner, _shareAmount);

    {
      (uint8[] memory actions, uint256[] memory values, bytes[] memory _datas) = abi.decode(
        _data,
        (uint8[], uint256[], bytes[])
      );
      _execute(actions, values, _datas);
    }

    PositionInfo memory _positionInfoAfter = positionInfo();
    Outstanding memory _outstandingAfter = _outstanding();

    // transfer funds back to shareOwner
    uint256 _stableTokenBack = stableToken == config.getWrappedNativeAddr()
      ? _outstandingAfter.nativeAmount - _outstandingBefore.nativeAmount
      : _outstandingAfter.stableAmount - _outstandingBefore.stableAmount;
    uint256 _assetTokenBack = assetToken == config.getWrappedNativeAddr()
      ? _outstandingAfter.nativeAmount - _outstandingBefore.nativeAmount
      : _outstandingAfter.assetAmount - _outstandingBefore.assetAmount;

    if (_stableTokenBack < _minStableTokenAmount) {
      revert InsufficientTokenReceived(stableToken, _minStableTokenAmount, _stableTokenBack);
    }
    if (_assetTokenBack < _minAssetTokenAmount) {
      revert InsufficientTokenReceived(assetToken, _minAssetTokenAmount, _assetTokenBack);
    }

    _transferTokenToShareOwner(_shareOwner, stableToken, _stableTokenBack);
    _transferTokenToShareOwner(_shareOwner, assetToken, _assetTokenBack);

    uint256 _withdrawValue;
    {
      uint256 _stableWithdrawValue = _stableTokenBack * priceHelper.getTokenPrice(stableToken);
      uint256 _assetWithdrawValue = _assetTokenBack * priceHelper.getTokenPrice(assetToken);
      _withdrawValue = (_stableWithdrawValue + _assetWithdrawValue) / 1e18;
    }

    // sanity check
    _withdrawHealthCheck(_withdrawValue, _positionInfoBefore, _positionInfoAfter);
    _outstandingCheck(_outstandingBefore, _outstandingAfter);

    emit LogWithdraw(_shareOwner, _stableTokenBack, _assetTokenBack);
    return _withdrawValue;
  }


  function rebalance(
    uint8[] memory _actions,
    uint256[] memory _values,
    bytes[] memory _datas
  ) external onlyRebalancers {

    PositionInfo memory _positionInfoBefore = positionInfo();
    Outstanding memory _outstandingBefore = _outstanding();
    uint256 _stablePositionValue = _positionInfoBefore.stablePositionEquity + _positionInfoBefore.stablePositionDebtValue;
    uint256 _assetPositionValue = _positionInfoBefore.assetPositionEquity + _positionInfoBefore.assetPositionDebtValue;
    uint256 _equityBefore = _positionInfoBefore.stablePositionEquity + _positionInfoBefore.assetPositionEquity;
    uint256 _rebalanceFactor = config.rebalanceFactor();

    if (
      _stablePositionValue * _rebalanceFactor >= _positionInfoBefore.stablePositionDebtValue * 10000 &&
      _assetPositionValue * _rebalanceFactor >= _positionInfoBefore.assetPositionDebtValue * 10000
    ) {
      revert PositionsIsHealthy();
    }

    // 2. execute rebalance
    {
      _execute(_actions, _values, _datas);
    }

    // 3. sanity check
    // check if position in a healthy state after rebalancing
    uint256 _equityAfter = totalEquityValue();
    if (!Math.almostEqual(_equityAfter, _equityBefore, config.positionValueTolerance())) {
      revert UnsafePositionValue();
    }
    _outstandingCheck(_outstandingBefore, _outstanding());

    emit LogRebalance(_equityBefore, _equityAfter);
  }

  /// @notice check if position equity and debt are healthy after deposit.
  /// @param _depositValue deposit value in usd.
  /// @param _positionInfoBefore position equity and debt before deposit.
  /// @param _positionInfoAfter position equity and debt after deposit.
  function _depositHealthCheck(
    uint256 _depositValue,
    PositionInfo memory _positionInfoBefore,
    PositionInfo memory _positionInfoAfter
  ) internal {

    uint256 _toleranceBps = config.positionValueTolerance();

    // 1. check position value
    if (
      !Math.almostEqual(_positionInfoAfter.stablePositionEquity - _positionInfoBefore.stablePositionEquity, (_depositValue ) / 4, _toleranceBps) ||
      !Math.almostEqual(_positionInfoAfter.assetPositionEquity - _positionInfoBefore.assetPositionEquity, (_depositValue * 3) / 4, _toleranceBps)
    ) {
      revert UnsafePositionEquity();
    }

    // 2. check Debt value
    if (
      !Math.almostEqual(
        _positionInfoAfter.stablePositionDebtValue - _positionInfoBefore.stablePositionDebtValue ,
        (_depositValue * 2) / 4,
        _toleranceBps
      ) ||
      !Math.almostEqual( _positionInfoAfter.assetPositionDebtValue - _positionInfoBefore.assetPositionDebtValue, (_depositValue * 6) / 4, _toleranceBps)
    ) {
      revert UnsafeDebtValue();
    }
  }

  /// @notice Check if position equity and debt ratio are healthy after withdraw.
  /// @param _withdrawValue Withdraw value in usd.
  /// @param _positionInfoBefore Position equity and debt before deposit.
  /// @param _positionInfoAfter Position equity and debt after deposit.
  function _withdrawHealthCheck(
    uint256 _withdrawValue,
    PositionInfo memory _positionInfoBefore,
    PositionInfo memory _positionInfoAfter
  ) internal {
    uint256 _toleranceBps = config.positionValueTolerance();
    // 1. equity value check
    uint256 _totalEquityBefore = _positionInfoBefore.stablePositionEquity + _positionInfoBefore.assetPositionEquity;
    uint256 _stableExpectedWithdrawValue = (_withdrawValue *_positionInfoBefore.stablePositionEquity)/_totalEquityBefore;
    uint256 _stableActualWithdrawValue = _positionInfoBefore.stablePositionEquity - _positionInfoAfter.stablePositionEquity;

    if(!Math.almostEqual(_stableActualWithdrawValue, _stableExpectedWithdrawValue, _toleranceBps)){
      revert UnsafePositionValue();
    }
    uint256 _assetExpectedWithdrawValue = (_withdrawValue *_positionInfoBefore.assetPositionEquity)/_totalEquityBefore;
    uint256 _assetActualWithdrawValue = _positionInfoBefore.assetPositionEquity - _positionInfoAfter.assetPositionEquity;
    if(!Math.almostEqual(_assetActualWithdrawValue, _assetExpectedWithdrawValue, _toleranceBps)){
      revert UnsafePositionValue();
    }

    // 2. debt ratio check
    uint256 _totalDebtBefore = _positionInfoBefore.stablePositionDebtValue + _positionInfoBefore.assetPositionDebtValue;
    uint256 _totalPositionValueBefore =  _positionInfoBefore.stablePositionEquity + _positionInfoBefore.assetPositionEquity + _totalDebtBefore;
    uint256 _totalDebtAfter = _positionInfoAfter.stablePositionDebtValue + _positionInfoAfter.assetPositionDebtValue;
    uint256 _totalPositionValueAfter = _positionInfoAfter.stablePositionEquity + _positionInfoAfter.assetPositionEquity + _totalDebtAfter;
    if (!Math.almostEqual(_totalPositionValueBefore/_totalDebtBefore , _totalPositionValueAfter / _totalDebtAfter, _toleranceBps)) {
      revert UnsafeDebtRatio();
    }

  }

  /// @notice Check tokens' balance.
  /// @param _outstandingBefore Tokens' balance before.
  /// @param _outstandingAfter Tokens' balance after.
  function _outstandingCheck(Outstanding memory _outstandingBefore, Outstanding memory _outstandingAfter) internal {
    if (_outstandingAfter.stableAmount < _outstandingBefore.stableAmount) {
      revert UnsafeOutstanding(stableToken, _outstandingBefore.stableAmount, _outstandingAfter.stableAmount);
    }
    if (_outstandingAfter.assetAmount < _outstandingBefore.assetAmount) {
      revert UnsafeOutstanding(assetToken, _outstandingBefore.assetAmount, _outstandingAfter.assetAmount);
    }
    if (_outstandingAfter.nativeAmount < _outstandingBefore.nativeAmount) {
      revert UnsafeOutstanding(address(0), _outstandingBefore.nativeAmount, _outstandingAfter.nativeAmount);
    }
  }

  /// @notice Return stable token, asset token and native token balance.
  function _outstanding() internal view returns (Outstanding memory) {
    return
      Outstanding({
        stableAmount: stableToken.myBalance(),
        assetAmount: assetToken.myBalance(),
        nativeAmount: address(this).balance
      });
  }

  /// @notice Return equity and debt value in usd of stable and asset positions.
  function positionInfo() public view returns (PositionInfo memory) {
    return
      PositionInfo({
        stablePositionEquity: _positionEquity(stableVault, stableVaultWorker, stableVaultPosId),
        stablePositionDebtValue: _positionDebtValue(stableVault, stableVaultPosId),
        assetPositionEquity: _positionEquity(assetVault, assetVaultWorker, assetVaultPosId),
        assetPositionDebtValue: _positionDebtValue(assetVault, assetVaultPosId)
      });
  }

  /// @notice Return the value of share from the given share amount.
  /// @param _shareAmount Amount of share.
  function shareToValue(uint256 _shareAmount) public view returns (uint256) {
    uint256 _shareSupply = totalSupply();
    if (_shareSupply == 0) return _shareAmount;
    return (_shareAmount * totalEquityValue()) / _shareSupply;
  }

  /// @notice Return the amount of share from the given value.
  /// @param _value value in usd.
  function valueToShare(uint256 _value) public view returns (uint256) {
    uint256 _shareSupply = totalSupply();
    if (_shareSupply == 0) return _value;
    return (_value * _shareSupply) / totalEquityValue();
  }

  /// @notice Return equity value of delta neutral position.
  function totalEquityValue() public view returns (uint256) {
    uint256 _positionValue = _positionValue(stableVaultWorker) + _positionValue(assetVaultWorker);
    uint256 _debtValue = _positionDebtValue(stableVault, stableVaultPosId) + _positionDebtValue(assetVault, assetVaultPosId);
    if (_positionValue < _debtValue) {
      return 0;
    }
    return _positionValue - _debtValue;
  }

  function _positionDebtValue(address _vault, uint256 _posId) internal view returns (uint256) {
    (, , uint256 _positionDebtShare) = IVault(_vault).positions(_posId);
    address _token = IVault(_vault).token();
    uint256 _vaultDebtShare = IVault(_vault).vaultDebtShare();
    if (_vaultDebtShare == 0) {
      return (_positionDebtShare * priceHelper.getTokenPrice(_token))/1e18;
    }
    uint256 _vaultDebtValue = IVault(_vault).vaultDebtVal() + IVault(_vault).pendingInterest(0);
    uint256 _debtAmount = (_positionDebtShare * _vaultDebtValue) / _vaultDebtShare;
    return (_debtAmount * priceHelper.getTokenPrice(_token))/1e18;
  }

  function _positionValue(address _worker) internal view returns (uint256) {
    return priceHelper.lpToDollar(IWorker02(_worker).totalLpBalance(), lpToken);
  }

  function _positionEquity(address _vault, address _worker, uint256 _posId) internal view returns (uint256) {
    uint256 _positionValue = _positionValue(_worker);
    uint256 _positionDebtValue = _positionDebtValue(_vault, _posId);
    if( _positionValue < _positionDebtValue){
      return 0;
    }
    return _positionValue - _positionDebtValue;
  }

  /// @notice Proxy function for calling internal action.
  function _execute(
    uint8[] memory _actions,
    uint256[] memory _values,
    bytes[] memory _datas
  ) internal {
    for (uint256 i = 0; i < _actions.length; i++) {
      uint8 _action = _actions[i];
      if (_action == ACTION_WORK) {
        _doWork(_datas[i]);
      }
      if (_action == ACTION_WRAP) {
        IWETH(config.getWrappedNativeAddr()).deposit{ value: _values[i] }();
      }
    }
  }

  /// @notice interact with delta neutral position.
  /// @param _data The calldata to pass along to the vault for more working context.
  function _doWork(bytes memory _data) internal {

    if (stableVaultPosId == 0 || assetVaultPosId == 0) {
      revert PositionsNotInitialized();
    }

    // 1. Decode data
    (
      address payable _vault,
      uint256 _posId,
      address _worker,
      uint256 _principalAmount,
      uint256 _borrowAmount,
      uint256 _maxReturn,
      bytes memory _workData
    ) = abi.decode(_data, (address, uint256, address, uint256, uint256, uint256, bytes));

    if ( !OPENING  &&
      !((_vault == stableVault && _posId == stableVaultPosId) || (_vault == assetVault && _posId == assetVaultPosId))
    ) {
      revert InvalidPositions({ _vault: _vault, _positionId: _posId });
    }

    // 2. approve vault
    stableToken.safeApprove(_vault, type(uint256).max);
    assetToken.safeApprove(_vault, type(uint256).max);

    // 3. Call work to altering Vault position
    IVault(_vault).work(_posId, _worker, _principalAmount, _borrowAmount, _maxReturn, _workData);

    // 4. Reset approve to 0
    stableToken.safeApprove(_vault, 0);
    assetToken.safeApprove(_vault, 0);
  }

  /// @notice Claim Alpaca reward of stable vault and asset vault
  function claim() external returns (uint256, uint256) {
    uint256 rewardStableVault = _claim(IVault(stableVault).fairLaunchPoolId());
    uint256 rewardAssetVault = _claim(IVault(assetVault).fairLaunchPoolId());
  }

  /// @dev Claim Alpaca reward for internal
  function _claim(uint256 _poolId) internal returns (uint256) {
    uint256 alpacaBefore = alpacaToken.myBalance();
    IFairLaunch(config.fairLaunchAddr()).harvest(_poolId);
    uint256 alpacaAfter = alpacaToken.myBalance();
    return alpacaAfter - alpacaBefore;
  }

  /// @notice withdraw alpaca to receiver address
  function withdrawAlpaca(address _to, uint256 amount) external onlyOwner {
    alpacaToken.safeTransfer(_to, amount);
  }

  /// @dev Fallback function to accept BNB.
  receive() external payable {}
}
