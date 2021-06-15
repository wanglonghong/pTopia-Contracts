// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./interfaces/IBEP20.sol";
import "./interfaces/IReferral.sol";

import "./libraries/SafeBEP20.sol";
import "./helpers/Ownable.sol";

contract NativeReferral is IReferral, Ownable {
    using SafeBEP20 for IBEP20;

    mapping(address => bool) public operators;                      // operator list
    mapping(address => address) public referrers;                   // user address => referrer address
    mapping(address => uint256) public referralsCount;              // referrer address => referrals count
    mapping(address => uint256) public totalReferralCommissions;    // referrer address => total referral commissions

    /// @notice Emits when a new referreral record is created
    event ReferralRecorded(address indexed user, address indexed referrer);

    /// @notice Emits when a new referreral commission record is created
    event ReferralCommissionRecorded(address indexed referrer, uint256 commission);

    /// @notice Emits when the owner updates the status of operator
    event OperatorUpdated(address indexed operator, bool indexed status);

    modifier onlyOperator {
        require(operators[msg.sender], "onlyOperator: caller is not the operator");
        _;
    }

    /**
     * @notice Creates new mapping of user and referrer
     * @param _user The address of user
     * @param _referrer The address of referrer
     */
    function recordReferral(address _user, address _referrer) public override onlyOperator {
        require(_user != address(0), "recordReferral: Invalid user address");
        require(_referrer != address(0), "recordReferral: Invalid referrer address");
        require(_user != _referrer, "recordReferral: User address should be different from referrer address");
        require(referrers[_user] == address(0), "recordReferral: User can only have one referrer");

        referrers[_user] = _referrer;
        referralsCount[_referrer] += 1;
        emit ReferralRecorded(_user, _referrer);
    }

    /**
     * @notice Creates new commission record of the referrer
     * @param _referrer The address of commission record
     * @param _commission The amount of commission record
     */
    function recordReferralCommission(address _referrer, uint256 _commission) public override onlyOperator {

        require(_referrer != address(0), "recordReferralCommission: Invalid referrer address");
        require(_commission > 0, "recordReferralCommission: The commission amount should be larger than zero");

        totalReferralCommissions[_referrer] += _commission;
        emit ReferralCommissionRecorded(_referrer, _commission);
    }

    /**
     * @notice Views the address of the user's referrer
     * @param _user The address of the target user 
     */
    function getReferrer(address _user) public override view returns (address) {
        return referrers[_user];
    }

    /**
     * @notice Updates the status of the operator
     * @param _operator The operator's address updated by owner
     * @param _status New status of the operator updated by owner
     */
    function updateOperator(address _operator, bool _status) external onlyOwner {
        operators[_operator] = _status;
        emit OperatorUpdated(_operator, _status);
    }

    /**
     * @notice Drains bep20 tokens which was transferred to by mistakes.
     * @param _token BEP-20 token address
     * @param _amount BEP-20 token amount
     * @param _to The address which sends BEP-20 token to.
     */
    function drainBEP20Token(IBEP20 _token, uint256 _amount, address _to) external onlyOwner {
        _token.safeTransfer(_to, _amount);
    }
}