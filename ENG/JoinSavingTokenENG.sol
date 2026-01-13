// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

/*
    JSAT — Joint Savings Account for Couples (USDT + Aave Earn)

    OVERVIEW
    --------
    JSAT is a smart contract designed for a fixed couple (1:1) that behaves like
    a traditional joint savings account, but fully on-chain.

    The contract combines two core components:
    1) A SOULBOUND ERC20 membership token (total supply = 2)
       - One token per partner
       - Non-transferable
       - Used only for identity / authorization

    2) A USDT savings vault with yield generation via Aave v3
       - Each partner deposits USDT
       - All USDT is supplied to Aave
       - Yield accrues automatically via aUSDT
       - Balances are tracked proportionally using internal "shares"

    KEY PROPERTIES
    --------------
    - Exactly two immutable partners
    - No admins, no upgrades, no third parties
    - Individual deposits and withdrawals
    - Shared payments split 50/50
    - If the amount is odd (in minimal units), the partner with higher balance pays the extra
    - Separation mode disables shared payments but preserves individual withdrawals
    - Maximum precision: uses the smallest USDT unit (optimal granularity)

    IMPORTANT
    ---------
    - USDT usually has 6 decimals, but the contract works in minimal units only
    - Users must approve USDT before depositing
    - Yield is real and comes from Aave, not simulated
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal interface for Aave v3 Pool
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract JointSavingToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                        COUPLE MEMBERSHIP
    // =============================================================

    /// @notice Partner A address (immutable)
    address public immutable partnerA;

    /// @notice Partner B address (immutable)
    address public immutable partnerB;

    /// @notice USDT token used as capital
    IERC20 public immutable usdt;

    /// @notice Aave v3 Pool
    IAavePool public immutable aavePool;

    /// @notice aToken for USDT (aUSDT)
    IERC20 public immutable aUSDT;

    /// @notice Contract state
    enum State {
        ACTIVE,     // Normal operation
        SEPARATED   // Shared payments disabled
    }

    State public state;

    // =============================================================
    //                   INTERNAL SHARE ACCOUNTING
    // =============================================================

    /*
        Internal shares represent a proportional claim on total assets.
        As Aave yield increases total assets, share value increases automatically.
    */

    mapping(address => uint256) private _shares;
    uint256 public totalShares;

    // =============================================================
    //                             ERRORS
    // =============================================================

    error NotPartner();
    error NonTransferable();
    error InvalidState();
    error ZeroAddress();
    error SameAddress();
    error InsufficientBalance();

    // =============================================================
    //                             EVENTS
    // =============================================================

    event Deposited(address indexed partner, uint256 amountUSDT, uint256 mintedShares);
    event Withdrawn(address indexed partner, uint256 amountUSDT, uint256 burnedShares);
    event CommonPaid(
        address indexed to,
        uint256 totalAmountUSDT,
        uint256 paidByA,
        uint256 paidByB,
        uint256 burnedSharesA,
        uint256 burnedSharesB
    );
    event SeparationTriggered(address indexed by);

    // =============================================================
    //                           MODIFIERS
    // =============================================================

    modifier onlyPartner() {
        if (msg.sender != partnerA && msg.sender != partnerB) revert NotPartner();
        _;
    }

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    /*
        Constructor parameters:
        - name_ / symbol_: ERC20 metadata (membership token)
        - partnerA / partnerB: the two fixed members
        - usdtAddress: USDT token address
        - aavePoolAddress: Aave v3 Pool address
        - aUSDTAddress: aToken address for USDT
    */
    constructor(
        string memory name_,
        string memory symbol_,
        address _partnerA,
        address _partnerB,
        address usdtAddress,
        address aavePoolAddress,
        address aUSDTAddress
    ) ERC20(name_, symbol_) {
        if (
            _partnerA == address(0) ||
            _partnerB == address(0) ||
            usdtAddress == address(0) ||
            aavePoolAddress == address(0) ||
            aUSDTAddress == address(0)
        ) revert ZeroAddress();

        if (_partnerA == _partnerB) revert SameAddress();

        partnerA = _partnerA;
        partnerB = _partnerB;
        usdt = IERC20(usdtAddress);
        aavePool = IAavePool(aavePoolAddress);
        aUSDT = IERC20(aUSDTAddress);

        // Mint exactly 2 membership tokens (1 per partner)
        _mint(_partnerA, 1);
        _mint(_partnerB, 1);

        state = State.ACTIVE;

        // Approve Aave Pool to move USDT from this contract
        usdt.approve(aavePoolAddress, 0);
        usdt.approve(aavePoolAddress, type(uint256).max);
    }

    // =============================================================
    //                 SOULBOUND ERC20 (MEMBERSHIP)
    // =============================================================

    /// @notice No decimals: exactly 2 tokens exist
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    /*
        Disable all transfers.
        Only minting (from address(0)) is allowed.
    */
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) public pure override returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    // =============================================================
    //                         VIEW FUNCTIONS
    // =============================================================

    /// @notice Total economic USDT balance (Aave + idle)
    function totalAssets() public view returns (uint256) {
        return aUSDT.balanceOf(address(this)) + usdt.balanceOf(address(this));
    }

    /// @notice Internal shares of a partner
    function sharesOf(address partner) external view returns (uint256) {
        return _shares[partner];
    }

    /// @notice Estimated USDT balance of a partner (includes yield)
    function balanceOfPartnerUSDT(address partner) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (_shares[partner] * totalAssets()) / totalShares;
    }

    // =============================================================
    //                           DEPOSIT
    // =============================================================

    function depositUSDT(uint256 amount) external onlyPartner nonReentrant {
        require(amount > 0, "Amount=0");

        uint256 assetsBefore = totalAssets();
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        uint256 mintedShares;
        if (totalShares == 0 || assetsBefore == 0) {
            mintedShares = amount;
        } else {
            mintedShares = (amount * totalShares) / assetsBefore;
            if (mintedShares == 0) mintedShares = 1;
        }

        _shares[msg.sender] += mintedShares;
        totalShares += mintedShares;

        aavePool.supply(address(usdt), amount, address(this), 0);

        emit Deposited(msg.sender, amount, mintedShares);
    }

    // =============================================================
    //                      INDIVIDUAL WITHDRAW
    // =============================================================

    function withdrawMyUSDT(uint256 amount) external onlyPartner nonReentrant {
        require(amount > 0, "Amount=0");

        uint256 burned = _burnSharesForAmount(msg.sender, amount);

        _ensureUSDTLiquidity(amount);
        usdt.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, burned);
    }

    // =============================================================
    //                       SHARED PAYMENT
    // =============================================================

    function payCommon(address to, uint256 amount) external onlyPartner nonReentrant {
        if (state != State.ACTIVE) revert InvalidState();
        require(to != address(0), "Zero to");
        require(amount > 0, "Amount=0");

        uint256 base = amount / 2;
        uint256 extra = amount % 2;

        uint256 balA = balanceOfPartnerUSDT(partnerA);
        uint256 balB = balanceOfPartnerUSDT(partnerB);

        uint256 payA = base;
        uint256 payB = base;

        if (extra == 1) {
            if (balA >= balB) payA += 1;
            else payB += 1;
        }

        uint256 burnedA = _burnSharesForAmount(partnerA, payA);
        uint256 burnedB = _burnSharesForAmount(partnerB, payB);

        _ensureUSDTLiquidity(amount);
        usdt.safeTransfer(to, amount);

        emit CommonPaid(to, amount, payA, payB, burnedA, burnedB);
    }

    // =============================================================
    //                       SEPARATION MODE
    // =============================================================

    function triggerSeparation() external onlyPartner {
        if (state != State.ACTIVE) revert InvalidState();
        state = State.SEPARATED;
        emit SeparationTriggered(msg.sender);
    }

    // =============================================================
    //                         INTERNAL LOGIC
    // =============================================================

    function _burnSharesForAmount(address partner, uint256 amount) internal returns (uint256 burnedShares) {
        uint256 assetsNow = totalAssets();
        require(totalShares > 0 && assetsNow > 0, "Empty vault");

        burnedShares = (amount * totalShares + assetsNow - 1) / assetsNow;
        if (_shares[partner] < burnedShares) revert InsufficientBalance();

        _shares[partner] -= burnedShares;
        totalShares -= burnedShares;

        return burnedShares;
    }

    function _ensureUSDTLiquidity(uint256 amount) internal {
        uint256 idle = usdt.balanceOf(address(this));
        if (idle >= amount) return;

        uint256 need = amount - idle;
        aavePool.withdraw(address(usdt), need, address(this));
    }
}
