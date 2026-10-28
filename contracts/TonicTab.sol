// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TonicTab
 * @notice Prepaid, transferable vouchers on BOT Chain.
 *
 * A merchant opens a counter: a name, a denomination and a validity window.
 * Customers buy vouchers at that denomination. The BOT sits in escrow — not
 * in the merchant's pocket — until the voucher is spent.
 *
 * Two rules do the real work here:
 *
 *  1. Only the current holder can redeem. The merchant cannot reach into a
 *     voucher and pull the funds out; they are paid when the holder spends it.
 *  2. The merchant never captures breakage. A voucher that goes unspent past
 *     its expiry refunds to whoever holds it, in full, with no fee taken.
 *
 * Vouchers are freely transferable before expiry, so a gift card bought for
 * someone else does not need the shop's permission to change hands.
 */
contract TonicTab is Ownable, Pausable, ReentrancyGuard {
    enum VoucherStatus {
        Open,
        Redeemed,
        Refunded
    }

    struct Counter {
        address merchant;
        uint256 denomination;
        uint64 validitySecs;
        bool selling;
        uint32 sold;
        uint32 redeemed;
        uint32 refunded;
        string name;
    }

    struct Voucher {
        uint64 counterId;
        address holder;
        uint64 boughtAt;
        uint64 expiresAt;
        uint256 value;
        VoucherStatus status;
        string memo;
    }

    uint64 public constant MIN_VALIDITY = 1 days;
    uint64 public constant MAX_VALIDITY = 365 days;
    uint256 public constant MIN_DENOMINATION = 0.001 ether;
    uint256 public constant MAX_NAME = 48;
    uint256 public constant MAX_MEMO = 64;
    uint16 public constant MAX_FEE_BPS = 500;

    /// @notice Taken from the voucher value at redemption. Never from a refund.
    uint16 public feeBps = 150;

    uint256 public accumulatedFees;
    /// @notice Total value held for unspent vouchers.
    uint256 public escrowedTotal;

    Counter[] private _counters;
    Voucher[] private _vouchers;

    mapping(address => uint256[]) private _byMerchant;
    mapping(address => uint256[]) private _byHolder;
    /// @dev voucherId => position inside its holder's array, for swap-and-pop on transfer.
    mapping(uint256 => uint256) private _holderPos;
    mapping(uint256 => uint256[]) private _byCounter;

    event CounterOpened(uint256 indexed counterId, address indexed merchant, string name, uint256 denomination, uint64 validitySecs);
    event CounterSellingSet(uint256 indexed counterId, bool selling);
    event DenominationUpdated(uint256 indexed counterId, uint256 denomination);
    event VoucherBought(uint256 indexed voucherId, uint256 indexed counterId, address indexed buyer, uint256 value, uint64 expiresAt);
    event VoucherTransferred(uint256 indexed voucherId, address indexed from, address indexed to);
    event VoucherRedeemed(uint256 indexed voucherId, uint256 indexed counterId, address indexed holder, uint256 toMerchant, uint256 fee);
    event VoucherRefunded(uint256 indexed voucherId, address indexed holder, uint256 amount);
    event FeeUpdated(uint16 feeBps);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor() Ownable(msg.sender) {}

    // ------------------------------------------------------------ counters

    function openCounter(string calldata name, uint256 denomination, uint64 validitySecs)
        external
        whenNotPaused
        returns (uint256 counterId)
    {
        require(bytes(name).length > 0 && bytes(name).length <= MAX_NAME, "bad name");
        require(denomination >= MIN_DENOMINATION, "denomination too small");
        require(validitySecs >= MIN_VALIDITY && validitySecs <= MAX_VALIDITY, "bad validity");

        counterId = _counters.length;
        _counters.push(
            Counter({
                merchant: msg.sender,
                denomination: denomination,
                validitySecs: validitySecs,
                selling: true,
                sold: 0,
                redeemed: 0,
                refunded: 0,
                name: name
            })
        );
        _byMerchant[msg.sender].push(counterId);
        emit CounterOpened(counterId, msg.sender, name, denomination, validitySecs);
    }

    function setSelling(uint256 counterId, bool selling) external {
        Counter storage c = _counter(counterId);
        require(c.merchant == msg.sender, "not merchant");
        c.selling = selling;
        emit CounterSellingSet(counterId, selling);
    }

    /// @dev Only affects vouchers bought from here on. Vouchers already sold
    ///      keep the value they were bought at.
    function updateDenomination(uint256 counterId, uint256 denomination) external {
        Counter storage c = _counter(counterId);
        require(c.merchant == msg.sender, "not merchant");
        require(denomination >= MIN_DENOMINATION, "denomination too small");
        c.denomination = denomination;
        emit DenominationUpdated(counterId, denomination);
    }

    // ------------------------------------------------------------ vouchers

    function buyVoucher(uint256 counterId, string calldata memo)
        external
        payable
        whenNotPaused
        returns (uint256 voucherId)
    {
        Counter storage c = _counter(counterId);
        require(c.selling, "counter closed");
        require(msg.value == c.denomination, "wrong amount");
        require(bytes(memo).length <= MAX_MEMO, "memo too long");

        uint64 expiresAt = uint64(block.timestamp) + c.validitySecs;
        voucherId = _vouchers.length;
        _vouchers.push(
            Voucher({
                counterId: uint64(counterId),
                holder: msg.sender,
                boughtAt: uint64(block.timestamp),
                expiresAt: expiresAt,
                value: msg.value,
                status: VoucherStatus.Open,
                memo: memo
            })
        );

        _holderPos[voucherId] = _byHolder[msg.sender].length;
        _byHolder[msg.sender].push(voucherId);
        _byCounter[counterId].push(voucherId);

        escrowedTotal += msg.value;
        unchecked {
            c.sold += 1;
        }
        emit VoucherBought(voucherId, counterId, msg.sender, msg.value, expiresAt);
    }

    /// @dev Allowed while paused: a holder must always be able to pass a voucher on.
    function transferVoucher(uint256 voucherId, address to) external {
        Voucher storage v = _voucher(voucherId);
        require(v.holder == msg.sender, "not holder");
        require(v.status == VoucherStatus.Open, "not open");
        require(block.timestamp < v.expiresAt, "expired");
        require(to != address(0) && to != msg.sender, "bad recipient");

        _detachFromHolder(voucherId, msg.sender);
        v.holder = to;
        _holderPos[voucherId] = _byHolder[to].length;
        _byHolder[to].push(voucherId);

        emit VoucherTransferred(voucherId, msg.sender, to);
    }

    /**
     * @notice Spend a voucher. Only the holder can do this; the merchant is
     *         paid at this moment and not before.
     */
    function redeemVoucher(uint256 voucherId) external nonReentrant {
        Voucher storage v = _voucher(voucherId);
        require(v.holder == msg.sender, "not holder");
        require(v.status == VoucherStatus.Open, "not open");
        require(block.timestamp < v.expiresAt, "expired");

        Counter storage c = _counters[v.counterId];
        uint256 value = v.value;
        uint256 fee = (value * feeBps) / 10_000;
        uint256 toMerchant = value - fee;

        v.status = VoucherStatus.Redeemed;
        escrowedTotal -= value;
        accumulatedFees += fee;
        unchecked {
            c.redeemed += 1;
        }
        _detachFromHolder(voucherId, msg.sender);

        emit VoucherRedeemed(voucherId, v.counterId, msg.sender, toMerchant, fee);

        (bool ok, ) = payable(c.merchant).call{value: toMerchant}("");
        require(ok, "merchant payment failed");
    }

    /**
     * @notice Reclaim an expired voucher in full.
     * @dev No fee. Breakage belongs to the customer, not the shop and not the
     *      protocol.
     */
    function refundExpired(uint256 voucherId) external nonReentrant {
        Voucher storage v = _voucher(voucherId);
        require(v.holder == msg.sender, "not holder");
        require(v.status == VoucherStatus.Open, "not open");
        require(block.timestamp >= v.expiresAt, "not expired");

        uint256 value = v.value;
        v.status = VoucherStatus.Refunded;
        escrowedTotal -= value;
        unchecked {
            _counters[v.counterId].refunded += 1;
        }
        _detachFromHolder(voucherId, msg.sender);

        emit VoucherRefunded(voucherId, msg.sender, value);

        (bool ok, ) = payable(msg.sender).call{value: value}("");
        require(ok, "refund failed");
    }

    // --------------------------------------------------------------- views

    function counterCount() external view returns (uint256) {
        return _counters.length;
    }

    function voucherCount() external view returns (uint256) {
        return _vouchers.length;
    }

    function getCounter(uint256 counterId) external view returns (Counter memory) {
        return _counter(counterId);
    }

    function getVoucher(uint256 voucherId) external view returns (Voucher memory) {
        return _voucher(voucherId);
    }

    /// @notice Open vouchers currently held by an address.
    function getVouchersByHolder(address holder) external view returns (uint256[] memory) {
        return _byHolder[holder];
    }

    function getCountersByMerchant(address merchant) external view returns (uint256[] memory) {
        return _byMerchant[merchant];
    }

    function getCounterVouchers(uint256 counterId) external view returns (uint256[] memory) {
        return _byCounter[counterId];
    }

    /// @notice Newest-first page of counter ids.
    function getRecentCounters(uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = _counters.length;
        if (limit > n) limit = n;
        ids = new uint256[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = n - 1 - i;
        }
    }

    function isRedeemable(uint256 voucherId) external view returns (bool) {
        Voucher storage v = _voucher(voucherId);
        return v.status == VoucherStatus.Open && block.timestamp < v.expiresAt;
    }

    // --------------------------------------------------------------- admin

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Bounded by `accumulatedFees`, so escrowed voucher value is unreachable.
    function withdrawFees(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "bad recipient");
        uint256 amount = accumulatedFees;
        require(amount > 0, "nothing to withdraw");
        accumulatedFees = 0;
        emit FeesWithdrawn(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------ internal

    function _counter(uint256 id) private view returns (Counter storage) {
        require(id < _counters.length, "no such counter");
        return _counters[id];
    }

    function _voucher(uint256 id) private view returns (Voucher storage) {
        require(id < _vouchers.length, "no such voucher");
        return _vouchers[id];
    }

    /// @dev Swap-and-pop so a holder's list never grows stale entries.
    function _detachFromHolder(uint256 voucherId, address holder) private {
        uint256[] storage arr = _byHolder[holder];
        uint256 pos = _holderPos[voucherId];
        uint256 last = arr.length - 1;
        if (pos != last) {
            uint256 moved = arr[last];
            arr[pos] = moved;
            _holderPos[moved] = pos;
        }
        arr.pop();
        delete _holderPos[voucherId];
    }

    receive() external payable {
        accumulatedFees += msg.value;
    }
}
