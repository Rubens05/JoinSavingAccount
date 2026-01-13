// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

contract JointSavingToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable partnerA;
    address public immutable partnerB;

    IERC20 public immutable usdt;
    IAavePool public immutable aavePool;
    IERC20 public immutable aUSDT;

    enum State {
        ACTIVE,
        SEPARATED
    }

    State public state;

    mapping(address => uint256) private _shares;
    uint256 public totalShares;

    error NotPartner();
    error NonTransferable();
    error InvalidState();
    error ZeroAddress();
    error SameAddress();
    error InsufficientBalance();

    event Deposited(address indexed partner, uint256 amount, uint256 mintedShares);
    event Withdrawn(address indexed partner, uint256 amount, uint256 burnedShares);
    event CommonPaid(
        address indexed to,
        uint256 totalAmount,
        uint256 paidByA,
        uint256 paidByB,
        uint256 burnedSharesA,
        uint256 burnedSharesB
    );
    event SeparationTriggered(address indexed by);

    modifier onlyPartner() {
        if (msg.sender != partnerA && msg.sender != partnerB) revert NotPartner();
        _;
    }

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

        _mint(_partnerA, 1);
        _mint(_partnerB, 1);

        state = State.ACTIVE;

        usdt.approve(aavePoolAddress, 0);
        usdt.approve(aavePoolAddress, type(uint256).max);
    }

    function decimals() public pure override returns (uint8) {
        return 0;
    }

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

    function totalAssets() public view returns (uint256) {
        return aUSDT.balanceOf(address(this)) + usdt.balanceOf(address(this));
    }

    function sharesOf(address partner) external view returns (uint256) {
        return _shares[partner];
    }

    function balanceOfPartnerUSDT(address partner) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (_shares[partner] * totalAssets()) / totalShares;
    }

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

    function withdrawMyUSDT(uint256 amount) external onlyPartner nonReentrant {
        require(amount > 0, "Amount=0");

        uint256 burned = _burnSharesForAmount(msg.sender, amount);

        _ensureUSDTLiquidity(amount);
        usdt.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, burned);
    }

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

    function triggerSeparation() external onlyPartner {
        if (state != State.ACTIVE) revert InvalidState();
        state = State.SEPARATED;
        emit SeparationTriggered(msg.sender);
    }

    function _burnSharesForAmount(address partner, uint256 amount) internal returns (uint256 burnedShares) {
        uint256 assetsNow = totalAssets();
        uint256 ts = totalShares;

        require(ts > 0 && assetsNow > 0, "Empty vault");

        burnedShares = (amount * ts + assetsNow - 1) / assetsNow;
        if (_shares[partner] < burnedShares) revert InsufficientBalance();

        _shares[partner] -= burnedShares;
        totalShares = ts - burnedShares;

        return burnedShares;
    }

    function _ensureUSDTLiquidity(uint256 amount) internal {
        uint256 idle = usdt.balanceOf(address(this));
        if (idle >= amount) return;

        uint256 need = amount - idle;
        aavePool.withdraw(address(usdt), need, address(this));
    }
}
