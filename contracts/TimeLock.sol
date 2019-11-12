pragma solidity ^0.4.24;

import "@aragon/os/contracts/apps/AragonApp.sol";
import "@aragon/os/contracts/common/IForwarder.sol";
import "@aragon/os/contracts/common/IForwarderFee.sol";
import "@aragon/os/contracts/common/SafeERC20.sol";
import "@aragon/os/contracts/lib/token/ERC20.sol";
import "@aragon/os/contracts/lib/math/SafeMath.sol";

contract TimeLock is AragonApp, IForwarder, IForwarderFee {

    using SafeERC20 for ERC20;
    using SafeMath for uint256;

    bytes32 public constant CHANGE_DURATION_ROLE = keccak256("CHANGE_DURATION_ROLE");
    bytes32 public constant CHANGE_AMOUNT_ROLE = keccak256("CHANGE_AMOUNT_ROLE");
    bytes32 public constant CHANGE_SPAM_PENALTY_ROLE = keccak256("CHANGE_SPAM_PENALTY_ROLE");
    bytes32 public constant LOCK_TOKENS_ROLE = keccak256("LOCK_TOKENS_ROLE");

    string private constant ERROR_NOT_CONTRACT = "TIME_LOCK_NOT_CONTRACT";
    string private constant ERROR_TOO_MANY_WITHDRAW_LOCKS = "TIME_LOCK_TOO_MANY_WITHDRAW_LOCKS";
    string private constant ERROR_CAN_NOT_FORWARD = "TIME_LOCK_CAN_NOT_FORWARD";
    string private constant ERROR_TRANSFER_REVERTED = "TIME_LOCK_TRANSFER_REVERTED";

    struct WithdrawLock {
        uint256 unlockTime;
        uint256 lockAmount;
    }

    ERC20 public token;
    uint256 public lockDuration;
    uint256 public lockAmount;

    uint256 public spamPenaltyFactor;
    uint256 public constant PCT_BASE = 10 ** 18; // 0% = 0; 1% = 10^16; 100% = 10^18

    // Using an array of WithdrawLocks instead of a mapping here means we cannot add fields to the WithdrawLock
    // struct in an upgrade of this contract. If we want to be able to add to the WithdrawLock structure in
    // future we must use a mapping instead, requiring overhead of storing index.
    mapping(address => WithdrawLock[]) public addressesWithdrawLocks;

    event ChangeLockDuration(uint256 newLockDuration);
    event ChangeLockAmount(uint256 newLockAmount);
    event ChangeSpamPenaltyFactor(uint256 newSpamPenaltyFactor);
    event NewLock(address lockAddress, uint256 unlockTime, uint256 lockAmount);
    event Withdrawal(address withdrawalAddress ,uint256 withdrawalLockCount);

    /**
    * @notice Initialize the Time Lock app
    * @param _token The token which will be locked when forwarding actions
    * @param _lockDuration The duration tokens will be locked before being able to be withdrawn
    * @param _lockAmount The amount of the token that is locked for each forwarded action
    * @param _spamPenaltyFactor The spam penalty factor (`_spamPenaltyFactor / PCT_BASE`)
    */
    function initialize(address _token, uint256 _lockDuration, uint256 _lockAmount, uint256 _spamPenaltyFactor) external onlyInit {
        require(isContract(_token), ERROR_NOT_CONTRACT);

        token = ERC20(_token);
        lockDuration = _lockDuration;
        lockAmount = _lockAmount;
        spamPenaltyFactor = _spamPenaltyFactor;

        initialized();
    }

    /**
    * @notice Change lock duration to `_lockDuration`
    * @param _lockDuration The new lock duration
    */
    function changeLockDuration(uint256 _lockDuration) external auth(CHANGE_DURATION_ROLE) {
        lockDuration = _lockDuration;
        emit ChangeLockDuration(lockDuration);
    }

    /**
    * @notice Change lock amount to `_lockAmount`
    * @param _lockAmount The new lock amount
    */
    function changeLockAmount(uint256 _lockAmount) external auth(CHANGE_AMOUNT_ROLE) {
        lockAmount = _lockAmount;
        emit ChangeLockAmount(lockAmount);
    }

    /**
    * @notice Change spam penalty factor to `_spamPenaltyFactor`
    * @param _spamPenaltyFactor The new spam penalty factor
    */
    function changeSpamPenaltyFactor(uint256 _spamPenaltyFactor) external auth(CHANGE_SPAM_PENALTY_ROLE) {
        spamPenaltyFactor = _spamPenaltyFactor;
        emit ChangeSpamPenaltyFactor(_spamPenaltyFactor);
    }

    /**
    * @notice Withdraw all withdrawable tokens
    */
    function withdrawAllTokens() external {
        WithdrawLock[] storage addressWithdrawLocks = addressesWithdrawLocks[msg.sender];
        _withdrawTokens(msg.sender, addressWithdrawLocks.length);
    }

    /**
    * @notice Withdraw all withdrawable tokens from the `_numberWithdrawLocks` oldest withdraw lock's
    * @param _numberWithdrawLocks The number of withdraw locks to attempt withdrawal from
    */
    function withdrawTokens(uint256 _numberWithdrawLocks) external {
        _withdrawTokens(msg.sender, _numberWithdrawLocks);
    }

    /**
    * @notice Returns the forward fee token and required lock amount
    * @dev IFeeForwarder interface conformance
    *      Note that the Time Lock app has to be the first forwarder in the transaction path, it must be called by an
    *      EOA not another forwarder, in order for the spam penalty mechanism to work
    * @return Forwarder token address
    * @return Forwarder lock amount
    */
    function forwardFee() external view returns (address, uint256) {
        (uint256 _spamPenaltyAmount, ) = getSpamPenalty(msg.sender);

        uint256 totalLockAmountRequired = lockAmount.add(_spamPenaltyAmount);

        return (address(token), totalLockAmountRequired);
    }

    /**
    * @notice Returns whether the Time Lock app is a forwarder or not
    * @dev IForwarder interface conformance
    * @return Always true
    */
    function isForwarder() external pure returns (bool) {
        return true;
    }

    /**
    * @notice Returns whether the `_sender` can forward actions or not
    * @dev IForwarder interface conformance
    * @return True if _sender has LOCK_TOKENS_ROLE role
    */
    function canForward(address _sender, bytes) public view returns (bool) {
        return canPerform(_sender, LOCK_TOKENS_ROLE, arr(_sender));
    }

    /**
    * @notice Locks `@tokenAmount(self.token(): address, self.getSpamPenalty(self): uint + self.lockAmount(): uint)` tokens and executes desired action
    * @dev IForwarder interface conformance.
    *      Note that the Time Lock app has to be the first forwarder in the transaction path, it must be called by an
    *      EOA not another forwarder, in order for the spam penalty mechanism to work
    * @param _evmCallScript Script to execute
    */
    function forward(bytes _evmCallScript) public {
        require(canForward(msg.sender, _evmCallScript), ERROR_CAN_NOT_FORWARD);

        WithdrawLock[] storage addressWithdrawLocks = addressesWithdrawLocks[msg.sender];
        (uint256 spamPenaltyAmount, uint256 spamPenaltyDuration) = getSpamPenalty(msg.sender);

        uint256 totalAmount = lockAmount.add(spamPenaltyAmount);
        uint256 totalDuration = lockDuration.add(spamPenaltyDuration);
        uint256 unlockTime = getTimestamp().add(totalDuration);

        addressWithdrawLocks.push(WithdrawLock(unlockTime, totalAmount));
        require(token.safeTransferFrom(msg.sender, address(this), totalAmount), ERROR_TRANSFER_REVERTED);

        emit NewLock(msg.sender, unlockTime, totalAmount);
        runScript(_evmCallScript, new bytes(0), new address[](0));
    }

    function getWithdrawLocksCount(address _lockAddress) public view returns (uint256) {
        return addressesWithdrawLocks[_lockAddress].length;
    }

    /**
    * @notice Get the amount and duration penalty based on the number of current locks `_sender` has
    * @dev Potential out of gas issue is considered acceptable. In this case a user would just have to wait and withdraw()
    *      some tokens before this function and forward() could be called again.
    * @return amount penalty
    * @return duration penalty
    */
    function getSpamPenalty(address _sender) public view returns (uint256, uint256) {
        WithdrawLock[] memory addressWithdrawLocks = addressesWithdrawLocks[_sender];

        uint256 activeLocks = 0;
        for (uint256 withdrawLockIndex = 0; withdrawLockIndex < addressWithdrawLocks.length; withdrawLockIndex++) {
            if (getTimestamp() < addressWithdrawLocks[withdrawLockIndex].unlockTime) {
                activeLocks += 1;
            }
        }

        uint256 totalAmount = lockAmount.mul(activeLocks).mul(spamPenaltyFactor).div(PCT_BASE);
        uint256 totalDuration = lockDuration.mul(activeLocks).mul(spamPenaltyFactor).div(PCT_BASE);

        return (totalAmount, totalDuration);
    }

    function _withdrawTokens(address _sender, uint256 _numberWithdrawLocks) internal {
        WithdrawLock[] storage addressWithdrawLocksStorage = addressesWithdrawLocks[_sender];
        require(_numberWithdrawLocks <= addressWithdrawLocksStorage.length, ERROR_TOO_MANY_WITHDRAW_LOCKS);

        uint256 amountOwed = 0;
        uint256 withdrawLockCount = 0;
        uint256 withdrawLockShiftAmount = addressWithdrawLocksStorage.length - _numberWithdrawLocks;

        for (uint256 withdrawLockIndex = _numberWithdrawLocks - 1; withdrawLockIndex >= 0; withdrawLockIndex--) {
            WithdrawLock memory withdrawLock = addressWithdrawLocksStorage[withdrawLockIndex];

            if (getTimestamp() > withdrawLock.unlockTime) {
                amountOwed = amountOwed.add(withdrawLock.lockAmount);
                withdrawLockCount += 1;

                delete addressWithdrawLocksStorage[withdrawLockIndex];
            }
        }

        for (uint256 shiftIndex = 0; shiftIndex < withdrawLockShiftAmount; shiftIndex++) {
            addressWithdrawLocksStorage[shiftIndex] = addressWithdrawLocksStorage[_numberWithdrawLocks + shiftIndex];
        }

        addressWithdrawLocksStorage.length = withdrawLockShiftAmount;

        token.transfer(_sender, amountOwed);

        emit Withdrawal(_sender, withdrawLockCount);
    }
}
