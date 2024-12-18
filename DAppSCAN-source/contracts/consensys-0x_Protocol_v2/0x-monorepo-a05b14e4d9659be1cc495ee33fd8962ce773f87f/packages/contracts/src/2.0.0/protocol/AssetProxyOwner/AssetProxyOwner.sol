/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/
// SWC-102-Outdated Compiler Version: L19
pragma solidity 0.4.10;

import "../../multisig/MultiSigWalletWithTimeLock.sol";


contract AssetProxyOwner is
    MultiSigWalletWithTimeLock
{

    event AssetProxyRegistration(address assetProxyContract, bool isRegistered);

    // Mapping of AssetProxy contract address =>
    // if this contract is allowed to call the AssetProxy's `removeAuthorizedAddressAtIndex` method without a time lock.
    mapping (address => bool) public isAssetProxyRegistered;

    bytes4 constant internal REMOVE_AUTHORIZED_ADDRESS_AT_INDEX_SELECTOR = bytes4(keccak256("removeAuthorizedAddressAtIndex(address,uint256)"));

    /// @dev Function will revert if the transaction does not call `removeAuthorizedAddressAtIndex`
    ///      on an approved AssetProxy contract.
    modifier validRemoveAuthorizedAddressAtIndexTx(uint256 transactionId) {
        Transaction storage tx = transactions[transactionId];
        require(isAssetProxyRegistered[tx.destination]);
        require(readBytes4(tx.data, 0) == REMOVE_AUTHORIZED_ADDRESS_AT_INDEX_SELECTOR);
        _;
    }

    /// @dev Contract constructor sets initial owners, required number of confirmations,
    ///      time lock, and list of AssetProxy addresses.
    /// @param _owners List of initial owners.
    /// @param _assetProxyContracts Array of AssetProxy contract addresses.
    /// @param _required Number of required confirmations.
    /// @param _secondsTimeLocked Duration needed after a transaction is confirmed and before it becomes executable, in seconds.
    function AssetProxyOwner(
        address[] memory _owners,
        address[] memory _assetProxyContracts,
        uint256 _required,
        uint256 _secondsTimeLocked
    )
        public
        MultiSigWalletWithTimeLock(_owners, _required, _secondsTimeLocked)
    {
        for (uint256 i = 0; i < _assetProxyContracts.length; i++) {
            address assetProxy = _assetProxyContracts[i];
            require(assetProxy != address(0));
            isAssetProxyRegistered[assetProxy] = true;
        }
    }

    /// @dev Registers or deregisters an AssetProxy to be able to execute
    ///      `removeAuthorizedAddressAtIndex` without a timelock.
    /// @param assetProxyContract Address of AssetProxy contract.
    /// @param isRegistered Status of approval for AssetProxy contract.
    function registerAssetProxy(address assetProxyContract, bool isRegistered)
        public
        onlyWallet
        notNull(assetProxyContract)
    {
        isAssetProxyRegistered[assetProxyContract] = isRegistered;
        AssetProxyRegistration(assetProxyContract, isRegistered);
    }

    /// @dev Allows execution of `removeAuthorizedAddressAtIndex` without time lock.
    /// @param transactionId Transaction ID.
    function executeRemoveAuthorizedAddressAtIndex(uint256 transactionId)
        public
        notExecuted(transactionId)
        fullyConfirmed(transactionId)
        validRemoveAuthorizedAddressAtIndexTx(transactionId)
    {
        Transaction storage tx = transactions[transactionId];
        tx.executed = true;
        // solhint-disable-next-line avoid-call-value
        if (tx.destination.call.value(tx.value)(tx.data))
            Execution(transactionId);
        else {
            ExecutionFailure(transactionId);
            tx.executed = false;
        }
    }

    /// @dev Reads an unpadded bytes4 value from a position in a byte array.
    /// @param b Byte array containing a bytes4 value.
    /// @param index Index in byte array of bytes4 value.
    /// @return bytes4 value from byte array.
    function readBytes4(
        bytes memory b,
        uint256 index
    )
        internal
        returns (bytes4 result)
    {
        require(b.length >= index + 4);
        assembly {
            result := mload(add(b, 32))
            // Solidity does not require us to clean the trailing bytes.
            // We do it anyway
            result := and(result, 0xFFFFFFFF00000000000000000000000000000000000000000000000000000000)
        }
        return result;
    }
}
