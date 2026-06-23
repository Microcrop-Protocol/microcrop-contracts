// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/**
 * @title MockInsurer
 * @notice Stand-in for a licensed design-partner insurer (Determination Schema §8.5 mitigation).
 *         Lets engineering rehearse the full determination → settlement loop end-to-end without
 *         a signed insurer. It mirrors the insurer's responsibilities in the target fund flow
 *         (Target-State Spec v3 §3): it underwrites products, holds the risk capital, and
 *         pre-funds a SEGREGATED, ring-fenced payout float that settlement draws against.
 *
 *         The core principle being rehearsed: **MicroCrop holds no risk capital — the insurer's
 *         capital backs every payout.** Built behind a minimal interface so the real insurer /
 *         provider-held-float integration can replace it without a rewrite (§8.3). The `sink`
 *         is the Treasury today; in the post-narrowing target state it becomes the
 *         provider-held off-chain float — same interface, different sink.
 *
 *         NOT production. Test/rehearsal harness only.
 */
contract MockInsurer {
    IERC20Min public immutable usdc;
    address public owner;

    /// @notice A parametric product underwritten by the insurer.
    struct Product {
        bytes32 peril; // keccak256("DROUGHT") etc.
        bytes32 region;
        uint256 triggerBp; // damage threshold (basis points) at/above which a payout is due
        uint256 maxSumInsured; // USDC base units
        uint256 premiumRateBp;
        bool active;
    }

    mapping(uint256 => Product) public products;
    uint256 public productCount;

    // Segregated payout-float accounting (insurer-funded, ring-fenced).
    uint256 public floatFunded; // cumulative USDC pre-funded into the float sink
    uint256 public floatDrawn; // cumulative USDC accounted as drawn for payouts

    event ProductUnderwritten(uint256 indexed productId, bytes32 peril, bytes32 region, uint256 maxSumInsured);
    event FloatFunded(address indexed sink, uint256 amount, uint256 totalFunded);
    event DrawRecorded(uint256 amount, uint256 totalDrawn);

    error NotOwner();
    error InsufficientCapital(uint256 requested, uint256 available);
    error ProductInactive(uint256 productId);
    error SumInsuredExceedsLimit(uint256 sumInsured, uint256 maxSumInsured);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _usdc) {
        usdc = IERC20Min(_usdc);
        owner = msg.sender;
    }

    /// @notice Underwrite a parametric product (peril/region/trigger/limits). The insurer's role.
    function underwriteProduct(
        bytes32 peril,
        bytes32 region,
        uint256 triggerBp,
        uint256 maxSumInsured,
        uint256 premiumRateBp
    ) external onlyOwner returns (uint256 productId) {
        productId = ++productCount;
        products[productId] = Product(peril, region, triggerBp, maxSumInsured, premiumRateBp, true);
        emit ProductUnderwritten(productId, peril, region, maxSumInsured);
    }

    /// @notice Bind a policy to a product — checks the sum insured against the underwritten limit.
    /// @dev Rehearsal-side underwriting acceptance; in production the insurer's systems decide this.
    function acceptPolicy(uint256 productId, uint256 sumInsured) external view returns (bool) {
        Product storage p = products[productId];
        if (!p.active) revert ProductInactive(productId);
        if (sumInsured > p.maxSumInsured) revert SumInsuredExceedsLimit(sumInsured, p.maxSumInsured);
        return true;
    }

    /// @notice Pre-fund the segregated payout float at `sink` from the insurer's own capital.
    ///         Today `sink` is the Treasury; in the target state it is the provider-held float.
    function fundFloat(address sink, uint256 amount) external onlyOwner {
        uint256 bal = usdc.balanceOf(address(this));
        if (bal < amount) revert InsufficientCapital(amount, bal);
        usdc.transfer(sink, amount);
        floatFunded += amount;
        emit FloatFunded(sink, amount, floatFunded);
    }

    /// @notice Capital pre-funded but not yet accounted as drawn.
    function availableFloat() external view returns (uint256) {
        return floatFunded - floatDrawn;
    }

    /// @notice Record a payout draw against the float (bookkeeping for rehearsal assertions; in
    ///         production the provider reports draws against the insurer-funded float).
    function recordDraw(uint256 amount) external onlyOwner {
        floatDrawn += amount;
        emit DrawRecorded(amount, floatDrawn);
    }

    /// @notice Insurer's remaining uncommitted capital (its own USDC balance).
    function capital() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }
}
