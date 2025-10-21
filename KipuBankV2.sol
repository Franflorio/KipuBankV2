// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title KipuBankV2 
 * @author Franflorio
 * @notice Bóvedas personales multi–token (ETH + ERC-20) con límites globales en USD(6),
 *         controlados por oráculo Chainlink y gobernados con AccessControl.
 * @dev CEI, Pausable, ReentrancyGuard. ETH usa Chainlink ETH/USD;
 *      ERC-20 "USD-stable" se normalizan por decimales (1:1) a USD(6).
 *      Incluye defensas: staleness, desvío máximo, rangos razonables y slippage.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========= Roles =========
    bytes32 public constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");
    bytes32 public constant FEED_ADMIN_ROLE   = keccak256("FEED_ADMIN_ROLE");
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE    = keccak256("EMERGENCY_ROLE");

    // ========= Constantes =========
    uint8   public constant USD_DECIMALS = 6;
    address public constant NATIVE_TOKEN = address(0);
    uint256 public constant BPS_DENOM = 10_000;
    uint256 public constant DEFAULT_FEED_STALE_THRESHOLD = 1 hours;
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 2000; // 20%
    uint256 public constant EMERGENCY_WITHDRAW_DELAY = 2 days;
    // NOTA: estas constantes están expresadas en 8 decimales; se escalan al pDec del feed al comparar.
    uint256 public constant MIN_REASONABLE_ETH_PRICE = 100 * 1e8;        // 100 USD (8 dec)
    uint256 public constant MAX_REASONABLE_ETH_PRICE = 1_000_000 * 1e8;  // 1M USD (8 dec)

    // ========= Tipos =========
    type Token is address;

    struct TokenConfig {
        bool  supported;    // whitelist
        bool  isUsdStable;  // USDC/USDT/DAI => 1:1 USD
        uint8 decimals;     // decimales del token
    }

    // ========= Estado: límites & oráculo =========
    uint256 public immutable bankCapUsd6;
    uint256 public immutable withdrawCapUsd6;
    /// @dev Contabilidad histórica en USD(6), no mark-to-market.
    uint256 public accountedTotalUsd6;

    AggregatorV3Interface public ethUsdFeed;
    uint256 public feedStaleThreshold;
    uint256 public lastValidPrice;
    uint256 public lastValidPriceTimestamp;
    uint256 public emergencyPausedAt;

    // ========= Estado: contabilidad multi-token =========
    mapping(address => mapping(address => uint256)) private balances;
    mapping(address => uint256) private totalByToken;
    mapping(address => TokenConfig) private tokenConfigs;

    uint96 public totalDepositCount;
    uint96 public totalWithdrawalCount;

    // ========= Errores =========
    error ZeroAmount();
    error ZeroAddress();
    error TokenNotSupported(address token);
    error CapExceeded(uint256 remainingUsd6, uint256 attemptedUsd6);
    error WithdrawCapExceeded(uint256 capUsd6, uint256 attemptedUsd6);
    error InsufficientBalance(uint256 current, uint256 attempted);
    error FeedAnswerInvalid(int256 answer);
    error FeedStale(uint256 updatedAt, uint256 now_, uint256 threshold);
    error PriceDeviationTooHigh(uint256 deviation, uint256 maxDeviation);
    error PriceOutOfBounds(uint256 price, uint256 min, uint256 max);
    error SlippageTooHigh(uint256 actual, uint256 minimum);
    error EthTransferFailed(bytes data);
    error InvalidFeed(address feed);
    error OverflowInScaling();
    error EmergencyDelayNotMet(uint256 current, uint256 required);
    error InvalidCapConfiguration(uint256 bankCap, uint256 withdrawCap);

    // ========= Eventos =========
    event Deposited(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usd6,
        uint256 newBalance,
        uint256 accountedTotalAfter,
        uint256 timestamp
    );
    event Withdrawn(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 usd6,
        uint256 newBalance,
        uint256 accountedTotalAfter,
        uint256 timestamp
    );
    event FeedUpdated(address indexed oldFeed, address indexed newFeed);
    event FeedStaleThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event TokenConfigUpdated(address indexed token, bool supported, bool isUsdStable, uint8 decimals);
    event PriceValidated(uint256 price, uint256 timestamp, uint256 deviation);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount, address indexed initiator);

    // ========= Constructor =========
    constructor(
        uint256 bankCapUsd6_,
        uint256 withdrawCapUsd6_,
        address feed_
    ) {
        if (bankCapUsd6_ == 0 || withdrawCapUsd6_ == 0) revert ZeroAmount();
        if (withdrawCapUsd6_ > bankCapUsd6_) revert InvalidCapConfiguration(bankCapUsd6_, withdrawCapUsd6_);
        if (feed_ == address(0)) revert ZeroAddress();

        bankCapUsd6 = bankCapUsd6_;
        withdrawCapUsd6 = withdrawCapUsd6_;
        feedStaleThreshold = DEFAULT_FEED_STALE_THRESHOLD;

        _validateAndSetFeed(feed_);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(FEED_ADMIN_ROLE, msg.sender);
        _grantRole(CONFIG_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    // ========= Administración =========
    function setFeed(address newFeed) external onlyRole(FEED_ADMIN_ROLE) {
        if (newFeed == address(0)) revert ZeroAddress();
        address oldFeed = address(ethUsdFeed);
        _validateAndSetFeed(newFeed);
        emit FeedUpdated(oldFeed, newFeed);
    }

    function _validateAndSetFeed(address feed_) internal {
        try AggregatorV3Interface(feed_).decimals() returns (uint8 dec) {
            if (dec == 0 || dec > 18) revert InvalidFeed(feed_);
            try AggregatorV3Interface(feed_).latestRoundData() returns (
                uint80 roundId,
                int256 answer,
                uint256 /*startedAt*/,
                uint256 updatedAt,
                uint80 answeredInRound
            ) {
                if (answer <= 0) revert FeedAnswerInvalid(answer);
                if (answeredInRound < roundId) revert InvalidFeed(feed_);
                if (block.timestamp - updatedAt > feedStaleThreshold) {
                    revert FeedStale(updatedAt, block.timestamp, feedStaleThreshold);
                }
                ethUsdFeed = AggregatorV3Interface(feed_);
                if (lastValidPrice == 0) {
                    lastValidPrice = uint256(answer);
                    lastValidPriceTimestamp = updatedAt;
                }
            } catch {
                revert InvalidFeed(feed_);
            }
        } catch {
            revert InvalidFeed(feed_);
        }
    }

    function setFeedStaleThreshold(uint256 seconds_) external onlyRole(FEED_ADMIN_ROLE) {
        if (seconds_ == 0 || seconds_ > 1 days) revert InvalidFeed(address(0));
        uint256 old = feedStaleThreshold;
        feedStaleThreshold = seconds_;
        emit FeedStaleThresholdUpdated(old, seconds_);
    }

    function updateLastValidPrice() external onlyRole(FEED_ADMIN_ROLE) {
        (uint256 price, , uint256 timestamp) = _getEthUsdPrice();
        lastValidPrice = price;
        lastValidPriceTimestamp = timestamp;
        emit PriceValidated(price, timestamp, 0);
    }

    function setTokenConfig(
        address token,
        bool supported,
        bool isUsdStable,
        uint8 decimals_
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (token == NATIVE_TOKEN) revert TokenNotSupported(token);
        if (decimals_ == 0 || decimals_ > 18) revert InvalidFeed(token);

        tokenConfigs[token] = TokenConfig({
            supported: supported,
            isUsdStable: isUsdStable,
            decimals: decimals_
        });
        emit TokenConfigUpdated(token, supported, isUsdStable, decimals_);
    }

    // ========= Depósitos =========

    /**
     * @notice Deposita ETH con protección contra slippage.
     * @param minUsd6Expected Mínimo USD(6) esperado por el usuario (0 desactiva la protección).
     */
    function depositETH(uint256 minUsd6Expected) public payable whenNotPaused nonReentrant {
        _depositETHInternal(msg.value, minUsd6Expected);
    }

    function _depositETHInternal(uint256 amount, uint256 minUsd6Expected) internal {
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _ethToUsd6(amount); // actualiza baseline
        if (usd6 < minUsd6Expected) revert SlippageTooHigh(usd6, minUsd6Expected);

        _checkCapAndAccrue(usd6);

        uint256 newBal = balances[NATIVE_TOKEN][msg.sender] + amount;
        balances[NATIVE_TOKEN][msg.sender] = newBal;
        totalByToken[NATIVE_TOKEN] += amount;

        unchecked { totalDepositCount += 1; }

        emit Deposited(
            msg.sender,
            NATIVE_TOKEN,
            amount,
            usd6,
            newBal,
            accountedTotalUsd6,
            block.timestamp
        );
    }

    /**
     * @notice Deposita un token ERC-20 soportado con protección de slippage (solo stables 1:1 en V2).
     */
    function depositERC20(
        address token,
        uint256 amount,
        uint256 minUsd6Expected
    ) external whenNotPaused nonReentrant {
        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported) revert TokenNotSupported(token);
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _erc20ToUsd6(token, amount, cfg);
        if (usd6 < minUsd6Expected) revert SlippageTooHigh(usd6, minUsd6Expected);

        _checkCapAndAccrue(usd6);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 newBal = balances[token][msg.sender] + amount;
        balances[token][msg.sender] = newBal;
        totalByToken[token] += amount;

        unchecked { totalDepositCount += 1; }

        emit Deposited(
            msg.sender,
            token,
            amount,
            usd6,
            newBal,
            accountedTotalUsd6,
            block.timestamp
        );
    }

    // ========= Retiros =========

    function withdrawETH(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _ethToUsd6(amount); // actualiza baseline
        if (usd6 > withdrawCapUsd6) revert WithdrawCapExceeded(withdrawCapUsd6, usd6);

        uint256 bal = balances[NATIVE_TOKEN][msg.sender];
        if (bal < amount) revert InsufficientBalance(bal, amount);

        // Effects
        uint256 newBal = bal - amount;
        balances[NATIVE_TOKEN][msg.sender] = newBal;
        totalByToken[NATIVE_TOKEN] -= amount;
        accountedTotalUsd6 -= usd6;
        unchecked { totalWithdrawalCount += 1; }

        // Interactions
        (bool ok, bytes memory data) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert EthTransferFailed(data);

        emit Withdrawn(
            msg.sender,
            NATIVE_TOKEN,
            amount,
            usd6,
            newBal,
            accountedTotalUsd6,
            block.timestamp
        );
    }

    function withdrawERC20(address token, uint256 amount) external nonReentrant whenNotPaused {
        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported) revert TokenNotSupported(token);
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _erc20ToUsd6(token, amount, cfg);
        if (usd6 > withdrawCapUsd6) revert WithdrawCapExceeded(withdrawCapUsd6, usd6);

        uint256 bal = balances[token][msg.sender];
        if (bal < amount) revert InsufficientBalance(bal, amount);

        // Effects
        uint256 newBal = bal - amount;
        balances[token][msg.sender] = newBal;
        totalByToken[token] -= amount;
        accountedTotalUsd6 -= usd6;
        unchecked { totalWithdrawalCount += 1; }

        // Interactions
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(
            msg.sender,
            token,
            amount,
            usd6,
            newBal,
            accountedTotalUsd6,
            block.timestamp
        );
    }

    // ========= Emergencia =========

    /**
     * @notice Retiro de emergencia (pausado + delay). NO ajusta contabilidad.
     * @dev Úsese para salvataje/migración; puede requerir reconciliación off-chain.
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(EMERGENCY_ROLE) whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 requiredTime = emergencyPausedAt + EMERGENCY_WITHDRAW_DELAY;
        if (block.timestamp < requiredTime) {
            revert EmergencyDelayNotMet(block.timestamp, requiredTime);
        }

        if (token == NATIVE_TOKEN) {
            (bool ok, bytes memory data) = payable(to).call{value: amount}("");
            if (!ok) revert EthTransferFailed(data);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit EmergencyWithdraw(token, to, amount, msg.sender);
    }

    // ========= Lecturas =========

    function balanceOf(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    function totalBy(address token) external view returns (uint256) {
        return totalByToken[token];
    }

    function capacityRemainingUsd6() external view returns (uint256) {
        if (accountedTotalUsd6 >= bankCapUsd6) return 0;
        return bankCapUsd6 - accountedTotalUsd6;
    }

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    function previewDepositETH(uint256 weiAmount) external view returns (uint256) {
        if (weiAmount == 0) return 0;
        return _ethToUsd6View(weiAmount);
    }

    function previewDepositERC20(address token, uint256 amount) external view returns (uint256) {
        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported || amount == 0) return 0;
        return _erc20ToUsd6View(token, amount, cfg);
    }

    function getCurrentEthUsdPrice() external view returns (uint256 price, uint8 decimals_, uint256 timestamp) {
        (price, decimals_, timestamp) = _getEthUsdPrice();
    }

    // ========= Conversión & checks =========

    function _checkCapAndAccrue(uint256 usd6) internal {
        uint256 remaining = bankCapUsd6 - accountedTotalUsd6;
        if (usd6 > remaining) revert CapExceeded(remaining, usd6);
        accountedTotalUsd6 += usd6;
    }

    /// @dev ETH -> USD(6) con Chainlink (ACTUALIZA baseline).
    function _ethToUsd6(uint256 weiAmount) internal returns (uint256) {
        (uint256 price, uint8 pDec, uint256 updatedAt) = _getEthUsdPrice();

        // Actualizar baseline para control de desviación futuro
        lastValidPrice = price;
        lastValidPriceTimestamp = updatedAt;

        // usd6 = (wei * price * 10^USD_DECIMALS) / (10^pDec * 1e18)
        return (weiAmount * price * (10 ** USD_DECIMALS)) / (10 ** pDec) / 1e18;
    }

    /// @dev ETH -> USD(6) sin side-effects (preview).
    function _ethToUsd6View(uint256 weiAmount) internal view returns (uint256) {
        (uint256 price, uint8 pDec, ) = _getEthUsdPrice();
        return (weiAmount * price * (10 ** USD_DECIMALS)) / (10 ** pDec) / 1e18;
    }

    /// @dev Obtiene precio con defensas: respuesta>0, no-stale, bounds escalados y answeredInRound.
    function _getEthUsdPrice() internal view returns (uint256 price, uint8 pDec, uint256 updatedAt) {
        pDec = ethUsdFeed.decimals();
        (uint80 roundId, int256 answer, , uint256 updated, uint80 answeredInRound) = ethUsdFeed.latestRoundData();

        if (answer <= 0) revert FeedAnswerInvalid(answer);
        if (answeredInRound < roundId) revert FeedAnswerInvalid(answer);

        price = uint256(answer);

        // Escalar bounds (definidos en 8 decimales) al pDec real del feed
        uint256 minP = (pDec == 8) ? MIN_REASONABLE_ETH_PRICE : _scaleDecimals(MIN_REASONABLE_ETH_PRICE, 8, pDec);
        uint256 maxP = (pDec == 8) ? MAX_REASONABLE_ETH_PRICE : _scaleDecimals(MAX_REASONABLE_ETH_PRICE, 8, pDec);

        if (price < minP || price > maxP) revert PriceOutOfBounds(price, minP, maxP);

        if (block.timestamp - updated > feedStaleThreshold) {
            revert FeedStale(updated, block.timestamp, feedStaleThreshold);
        }

        // Control de desvío vs baseline (si existe)
        if (lastValidPrice > 0) {
            uint256 base = lastValidPrice;
            uint256 deviation = (price > base)
                ? ((price - base) * BPS_DENOM) / base
                : ((base - price) * BPS_DENOM) / base;

            if (deviation > MAX_PRICE_DEVIATION_BPS) {
                revert PriceDeviationTooHigh(deviation, MAX_PRICE_DEVIATION_BPS);
            }
        }

        updatedAt = updated;
    }

    /// @dev ERC-20 (stable 1:1) -> USD(6) por normalización de decimales.
    function _erc20ToUsd6(address /*token*/, uint256 amount, TokenConfig memory cfg) internal pure returns (uint256) {
        if (!cfg.isUsdStable) revert TokenNotSupported(address(0));
        return _scaleDecimals(amount, cfg.decimals, USD_DECIMALS);
    }

    function _erc20ToUsd6View(address /*token*/, uint256 amount, TokenConfig memory cfg) internal pure returns (uint256) {
        if (!cfg.isUsdStable) return 0;
        return _scaleDecimals(amount, cfg.decimals, USD_DECIMALS);
    }

    /// @dev Escala `amount` de `fromDec` a `toDec` con guardas.
    function _scaleDecimals(uint256 amount, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (fromDec == toDec) return amount;
        if (fromDec < toDec) {
            uint256 multiplier = 10 ** (toDec - fromDec);
            uint256 result = amount * multiplier;
            if (result / multiplier != amount) revert OverflowInScaling();
            return result;
        } else {
            return amount / (10 ** (fromDec - toDec));
        }
    }

    // ========= Pausable & Receive/Fallback =========

    function pause() external onlyRole(PAUSER_ROLE) {
        emergencyPausedAt = block.timestamp;
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        emergencyPausedAt = 0;
        _unpause();
    }

    /// @dev Depósito ETH directo sin slippage protection (min=0).
    receive() external payable whenNotPaused {
        _depositETHInternal(msg.value, 0);
    }

    /// @dev Depósito ETH con datos, sin slippage protection (min=0).
    fallback() external payable whenNotPaused {
        _depositETHInternal(msg.value, 0);
    }
}
