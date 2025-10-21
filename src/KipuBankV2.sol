// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title KipuBankV2 (Upgradeable)
 * @author ...
 * @notice Bóvedas personales multi–token (ETH + ERC-20) con límites en USD,
 *         controladas por oráculo Chainlink y gobernadas con AccessControl.
 * @dev Ruta upgradeable (UUPS). Aplica CEI, Pausable y ReentrancyGuard.
 *      Esta versión unifica el riesgo con un cap global en USD(6), soporta
 *      tokens "USD-stables" (1:1) y ETH con conversión Chainlink.
 */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

// Chainlink ETH/USD price feed
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // ========= Roles =========
    /// @notice Puede autorizar upgrades (se recomienda multisig/timelock).
    bytes32 public constant UPGRADER_ROLE     = keccak256("UPGRADER_ROLE");
    /// @notice Puede pausar/reanudar depósitos y retiros.
    bytes32 public constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");
    /// @notice Puede actualizar feed de precios y políticas de staleness.
    bytes32 public constant FEED_ADMIN_ROLE   = keccak256("FEED_ADMIN_ROLE");
    /// @notice Puede configurar tokens soportados/decimales.
    bytes32 public constant CONFIG_ADMIN_ROLE = keccak256("CONFIG_ADMIN_ROLE");

    // ========= Constantes =========
    /// @notice Decimales destino para USD (USDC-style).
    uint8 public constant USD_DECIMALS = 6;
    /// @notice Representación del token nativo (ETH) en mappings.
    address public constant NATIVE_TOKEN = address(0);
    /// @notice Denominador para basis points (para futuros fees si aplica).
    uint256 public constant BPS_DENOM = 10_000;
    /// @notice Umbral default de "staleness" del precio (segundos).
    uint256 public constant DEFAULT_FEED_STALE_THRESHOLD = 1 hours;

    // ========= Tipos y configuración =========
    /// @notice Alias semántico para token address.
    type Token is address;

    /// @notice Configuración por token ERC-20.
    struct TokenConfig {
        bool supported;    // en whitelist
        bool isUsdStable;  // USDC/USDT/DAI => 1:1 USD
        uint8 decimals;    // decimales del token
    }

    // ========= Estado: límites y oráculo =========
    /// @notice Cap global del banco expresado en USD con 6 decimales.
    uint256 public bankCapUsd6;
    /// @notice Tope por transacción de retiro en USD con 6 decimales.
    uint256 public withdrawCapUsd6;
    /// @notice Suma contable global (USD con 6 decimales).
    uint256 public accountedTotalUsd6;

    /// @notice Instancia del price feed ETH/USD (Chainlink).
    AggregatorV3Interface public ethUsdFeed;
    /// @notice Umbral máximo de antigüedad aceptada para el feed.
    uint256 public feedStaleThreshold;

    // ========= Estado: contabilidad multi–token =========
    /// @notice Balances por (token => usuario => monto).
    mapping(address => mapping(address => uint256)) private balances;
    /// @notice Totales por token.
    mapping(address => uint256) private totalByToken;
    /// @notice Configuración de tokens soportados.
    mapping(address => TokenConfig) private tokenConfigs;

    // (Opcional) contadores compactos
    uint96 public totalDepositCount;
    uint96 public totalWithdrawalCount;

    // ========= Errores =========
    error ZeroAmount();
    error TokenNotSupported(address token);
    error CapExceeded(uint256 remainingUsd6, uint256 attemptedUsd6);
    error WithdrawCapExceeded(uint256 capUsd6, uint256 attemptedUsd6);
    error InsufficientBalance(uint256 current, uint256 attempted);
    error FeedAnswerInvalid(int256 answer);
    error FeedStale(uint256 updatedAt, uint256 now_, uint256 threshold);

    // ========= Eventos =========
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 usd6, uint256 newBalance);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 usd6, uint256 newBalance);
    event FeedUpdated(address indexed newFeed);
    event FeedStaleThresholdUpdated(uint256 seconds_);
    event TokenConfigUpdated(address indexed token, bool supported, bool isUsdStable, uint8 decimals);

    // ========= Upgradeable gap =========
    uint256[50] private __gap;

    // ========= Inicialización & UUPS =========

    /**
     * @notice Inicializa el contrato (UUPS).
     * @param bankCapUsd6_ Cap global en USD(6).
     * @param withdrawCapUsd6_ Tope por retiro en USD(6).
     * @param feed_ Dirección del AggregatorV3 ETH/USD.
     * @param admin_ Address con DEFAULT_ADMIN_ROLE.
     * @param pauser_ Address con PAUSER_ROLE.
     */
    function initialize(
        uint256 bankCapUsd6_,
        uint256 withdrawCapUsd6_,
        address feed_,
        address admin_,
        address pauser_
    ) public initializer {
        if (bankCapUsd6_ == 0 || withdrawCapUsd6_ == 0) revert ZeroAmount();

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);
        _grantRole(PAUSER_ROLE, pauser_);
        _grantRole(FEED_ADMIN_ROLE, admin_);
        _grantRole(CONFIG_ADMIN_ROLE, admin_);

        bankCapUsd6 = bankCapUsd6_;
        withdrawCapUsd6 = withdrawCapUsd6_;
        ethUsdFeed = AggregatorV3Interface(feed_);
        feedStaleThreshold = DEFAULT_FEED_STALE_THRESHOLD;
    }

    /// @dev UUPS: solo quien tenga UPGRADER_ROLE puede autorizar upgrades.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(UPGRADER_ROLE)
    {}

    // ========= Administración (feeds y tokens) =========

    /// @notice Actualiza el feed ETH/USD.
    function setFeed(address newFeed) external onlyRole(FEED_ADMIN_ROLE) {
        ethUsdFeed = AggregatorV3Interface(newFeed);
        emit FeedUpdated(newFeed);
    }

    /// @notice Ajusta el umbral de “staleness” aceptado para el feed.
    function setFeedStaleThreshold(uint256 seconds_) external onlyRole(FEED_ADMIN_ROLE) {
        feedStaleThreshold = seconds_;
        emit FeedStaleThresholdUpdated(seconds_);
    }

    /**
     * @notice Configura un token ERC-20 soportado.
     * @param token Address del token.
     * @param supported En whitelist o no.
     * @param isUsdStable Si es 1:1 con USD (USDC/USDT/DAI).
     * @param decimals_ Decimales del token.
     */
    function setTokenConfig(
        address token,
        bool supported,
        bool isUsdStable,
        uint8 decimals_
    ) external onlyRole(CONFIG_ADMIN_ROLE) {
        tokenConfigs[token] = TokenConfig({
            supported: supported,
            isUsdStable: isUsdStable,
            decimals: decimals_
        });
        emit TokenConfigUpdated(token, supported, isUsdStable, decimals_);
    }

    // ========= Depósitos =========

    /// @notice Deposita ETH (redirigido también por receive/fallback).
    function depositETH() external payable whenNotPaused {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _ethToUsd6(amount);
        _checkCapAndAccrue(usd6);

        uint256 newBal = balances[NATIVE_TOKEN][msg.sender] + amount;
        balances[NATIVE_TOKEN][msg.sender] = newBal;
        totalByToken[NATIVE_TOKEN] += amount;

        unchecked { totalDepositCount += 1; }

        emit Deposited(msg.sender, NATIVE_TOKEN, amount, usd6, newBal);
    }

    /**
     * @notice Deposita un token ERC-20 soportado.
     * @dev Para esta iteración soportamos:
     *      - tokens "USD-stable" (1:1) normalizando decimales a USD(6).
     * @param token Address del token.
     * @param amount Monto a depositar (decimales del token).
     */
    function depositERC20(address token, uint256 amount) external whenNotPaused {
        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported) revert TokenNotSupported(token);
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _erc20ToUsd6(token, amount, cfg);
        _checkCapAndAccrue(usd6);

        IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 newBal = balances[token][msg.sender] + amount;
        balances[token][msg.sender] = newBal;
        totalByToken[token] += amount;

        unchecked { totalDepositCount += 1; }

        emit Deposited(msg.sender, token, amount, usd6, newBal);
    }

    // ========= Retiros =========

    /// @notice Retira ETH respetando withdrawCapUsd6.
    function withdrawETH(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        uint256 usd6 = _ethToUsd6(amount);
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
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert();

        emit Withdrawn(msg.sender, NATIVE_TOKEN, amount, usd6, newBal);
    }

    /// @notice Retira un token ERC-20 soportado respetando withdrawCapUsd6.
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
        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount, usd6, newBal);
    }

    // ========= Lecturas (DX) =========

    /// @notice Balance de `user` para `token`.
    function balanceOf(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    /// @notice Total depositado por `token`.
    function totalBy(address token) external view returns (uint256) {
        return totalByToken[token];
    }

    /// @notice Capacidad restante en USD(6) antes de alcanzar el bank cap.
    function capacityRemainingUsd6() external view returns (uint256) {
        return bankCapUsd6 - accountedTotalUsd6;
    }

    /// @notice Configuración registrada de un token.
    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokenConfigs[token];
    }

    /// @notice Vista previa: cuánto USD(6) representa un depósito de `weiAmount` en ETH.
    function previewDepositETH(uint256 weiAmount) external view returns (uint256) {
        if (weiAmount == 0) return 0;
        return _ethToUsd6View(weiAmount);
    }

    /// @notice Vista previa: USD(6) para un depósito `amount` del `token`.
    function previewDepositERC20(address token, uint256 amount) external view returns (uint256) {
        TokenConfig memory cfg = tokenConfigs[token];
        if (!cfg.supported || amount == 0) return 0;
        return _erc20ToUsd6View(token, amount, cfg);
    }

    // ========= Conversión y checks (internos/puros) =========

    /// @dev Chequea cap y acumula contabilidad global en USD(6).
    function _checkCapAndAccrue(uint256 usd6) internal {
        uint256 remaining = bankCapUsd6 - accountedTotalUsd6;
        if (usd6 > remaining) revert CapExceeded(remaining, usd6);
        accountedTotalUsd6 += usd6;
    }

    /// @dev ETH -> USD(6) con Chainlink (estado).
    function _ethToUsd6(uint256 weiAmount) internal view returns (uint256) {
        (uint256 price, uint8 pDec, uint256 updatedAt) = _getEthUsdPrice();
        // usd6 = (wei * price * 10^USD_DECIMALS) / (10^pDec * 1e18)
        return (weiAmount * price * (10 ** USD_DECIMALS)) / (10 ** pDec) / 1e18;
    }

    /// @dev ETH -> USD(6) (versión view separada para previews).
    function _ethToUsd6View(uint256 weiAmount) internal view returns (uint256) {
        (uint256 price, uint8 pDec, ) = _getEthUsdPrice();
        return (weiAmount * price * (10 ** USD_DECIMALS)) / (10 ** pDec) / 1e18;
    }

    /// @dev Obtiene precio ETH/USD con validaciones.
    function _getEthUsdPrice() internal view returns (uint256 price, uint8 pDec, uint256 updatedAt) {
        pDec = ethUsdFeed.decimals();
        (
            /*uint80 roundID*/,
            int256 answer,
            /*uint256 startedAt*/,
            uint256 updated,
            /*uint80 answeredInRound*/
        ) = ethUsdFeed.latestRoundData();

        if (answer <= 0) revert FeedAnswerInvalid(answer);
        if (block.timestamp - updated > feedStaleThreshold) revert FeedStale(updated, block.timestamp, feedStaleThreshold);

        price = uint256(answer);
        updatedAt = updated;
    }

    /// @dev ERC-20 (stable 1:1) -> USD(6) normalizando decimales (estado).
    function _erc20ToUsd6(address /*token*/, uint256 amount, TokenConfig memory cfg) internal pure returns (uint256) {
        if (!cfg.isUsdStable) revert TokenNotSupported(address(0)); // usar un error específico si luego soportamos no-stables
        return _scaleDecimals(amount, cfg.decimals, USD_DECIMALS);
    }

    /// @dev Vista previa sin side-effects.
    function _erc20ToUsd6View(address /*token*/, uint256 amount, TokenConfig memory cfg) internal pure returns (uint256) {
        if (!cfg.isUsdStable) return 0;
        return _scaleDecimals(amount, cfg.decimals, USD_DECIMALS);
    }

    /// @dev Escala `amount` de `fromDec` a `toDec` con redondeo hacia abajo.
    function _scaleDecimals(uint256 amount, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (fromDec == toDec) return amount;
        if (fromDec < toDec) {
            return amount * (10 ** (toDec - fromDec));
        } else {
            return amount / (10 ** (fromDec - toDec));
        }
    }

    // ========= Pausable & Receive/Fallback =========

    /// @notice Pausa depósitos y retiros.
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /// @notice Reanuda depósitos y retiros.
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    /// @notice Acepta ETH directo y lo trata como depósito.
    receive() external payable { 
        // Mantiene msg.sender y msg.value
        depositETH(); 
    }

    /// @notice Acepta llamadas con datos y ETH, y las trata como depósito ETH.
    fallback() external payable { 
        depositETH(); 
    }
}
