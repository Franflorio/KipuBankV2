# KipuBankV2 (non-upgradeable)

Bóvedas personales **multi-token** (ETH + ERC-20) con **cap global** y **tope por retiro** expresados en **USD(6)**.  
Convierte **ETH → USD** vía **Chainlink ETH/USD** y trata **ERC-20 “USD-stable”** (USDC/USDT/DAI) como 1:1 usando normalización de decimales.  
Incluye **AccessControl**, **Pausable**, **ReentrancyGuard**, patrón **CEI**, errores personalizados y eventos.

---

## 1) ¿Qué mejoramos y por qué?

- **Multi-token real (ETH + ERC-20)**  
  Contabilidad por token y por usuario (`balances[token][user]`, `totalByToken[token]`).
  - *Motivo:* custodiar varios activos con una misma lógica segura.

- **Cap Global y Tope por Retiro en USD(6)**  
  Límite total del banco y por transacción en una unidad homogénea (USD con 6 decimales).
  - *Motivo:* reglas de riesgo consistentes y fáciles de comunicar (producto/negocio).

- **Oráculo Chainlink (ETH/USD) con defensas**  
  Validaciones de **staleness**, **rangos razonables**, **desvío máximo** vs último precio válido y chequeo de **`answeredInRound`**.
  - *Motivo:* evitar usar precios inválidos o anómalos para valorar depósitos/retiros de ETH.

- **Protección de slippage en depósitos**  
  `depositETH(minUsd6Expected)` / `depositERC20(..., minUsd6Expected)` revierte si el USD recibido cae por debajo del mínimo indicado.
  - *Motivo:* proteger al usuario de cambios de precio entre firma y minado.

- **Seguridad on-chain**  
  **CEI** en retiros, **ReentrancyGuard**, **Pausable** (emergencias) y **AccessControl** (roles operativos).
  - *Motivo:* reducir superficie de ataque y habilitar operación responsable.

---

## 2) Decisiones de diseño y trade-offs

- **No-upgradeable (Ruta A)**  
  **+** Menos superficie de ataque y gas más bajo que con proxy.  
  **–** Cambios de lógica requieren nuevo despliegue (posible migración off-chain).

- **Contabilidad “accounted” en USD(6)**  
  `accountedTotalUsd6` refleja lo contabilizado al depositar/retirar (no mark-to-market).
  **+** Simplicidad y previsibilidad.  
  **–** En alta volatilidad puede diferir del valor de mercado.

- **Sólo stables 1:1 en V2**  
  **+** Menos riesgo y complejidad (no se necesitan feeds por token).  
  **–** ERC-20 volátiles quedan para una versión posterior.

- **`receive`/`fallback` sin slippage**  
  Aceptan ETH directo con `minUsd6Expected = 0`.  
  **+** UX simple.  
  **–** El usuario no fija un piso de USD; si el precio se mueve, recibe lo que marque el oráculo.

- **Emergencias**  
  `emergencyWithdraw` no ajusta contabilidad interna (se documenta como salvataje/migración).  
  **+** Herramienta de rescate.  
  **–** Si se reanuda, puede requerir reconciliación contable externa.

---

## 3) Despliegue

### Requisitos
- **Solidity 0.8.24**  
- **Cuenta en testnet** (p. ej., Sepolia) con ETH de faucet  
- **Dirección del feed ETH/USD** de la red elegida (consultar documentación oficial de Chainlink para la red donde desplegás)

### Pasos (Remix)
1. Crea `KipuBankV2.sol` y pega el contrato.  
2. Compila con **0.8.24** (recordá configuración de optimizer para la verificación).  
3. Deploy (Value = 0) con constructor:
   - `bankCapUsd6` → p. ej. `100000000` (100 USD con 6 decimales)  
   - `withdrawCapUsd6` → p. ej. `1000000` (1 USD con 6 decimales)  
   - `feed` → **ETH/USD Aggregator** de tu red (address oficial de Chainlink para esa testnet)
4. Post-deploy (tu cuenta es admin):
   - (Opcional) Delegá roles:
     - `grantRole(PAUSER_ROLE, 0xOps...)`
     - `grantRole(FEED_ADMIN_ROLE, 0xOracleOps...)`
     - `grantRole(CONFIG_ADMIN_ROLE, 0xTokenOps...)`
     - `grantRole(EMERGENCY_ROLE, 0xSafe...)`
   - Configurá tokens stables:
     - `setTokenConfig(<USDC>, true, true, 6)` (repetir por cada stable)

### Verificación en Etherscan — Método “Flatten” (Remix)
1. Activá plugin **Flattener/Flatten** → **Flatten** sobre `KipuBankV2.sol`.  
2. En el archivo aplanado:
   - Dejá **una sola** línea `// SPDX-License-Identifier: MIT` al inicio.
   - Confirmá `pragma solidity ^0.8.24;`.
3. En Etherscan → **Verify & Publish** → “Solidity (Single file)”:
   - **Compiler:** 0.8.24 (exacto)
   - **Optimizer:** ON/OFF y `runs` igual que tu deploy
   - Pegá el `Flattened.sol`
   - **Constructor args (en orden):** `bankCapUsd6`, `withdrawCapUsd6`, `feed`

> Alternativa: “Solidity (Standard JSON Input)” copiando el JSON desde **Compilation Details** en Remix.

---

## 4) Interacción rápida (Remix)

### Oráculo
- `getCurrentEthUsdPrice()` → precio ETH/USD, decimales del feed y timestamp.  
- (Admin de feed) `setFeed(new)`, `setFeedStaleThreshold(seconds)`, `updateLastValidPrice()`.

### Depósitos
- **ETH (rápido, sin slippage):**  
  `depositETH(0)` con **Value** en ETH.  
  *O bien* enviar directamente ETH a `receive`/`fallback` (equivale a `minUsd6Expected = 0`).
- **ETH (con slippage):**  
  1) `previewDepositETH(weiAmount)` → USD(6) estimado  
  2) Llamar `depositETH(minUsd6Expected)` con un mínimo (p. ej. 99% del preview).
- **ERC-20 stable:**  
  1) `approve(<KipuBankV2>, amount)` en el token  
  2) `depositERC20(token, amount, minUsd6Expected)`

### Retiros (respetan el tope por transacción en USD)
- `withdrawETH(amountWei)`  
- `withdrawERC20(token, amountToken)`

### Lecturas útiles
- `balanceOf(token, user)`  
- `totalBy(token)`  
- `capacityRemainingUsd6()`  
- `previewDepositETH(weiAmount)` / `previewDepositERC20(token, amount)`

### Operación
- `pause()` / `unpause()` (PAUSER_ROLE)  
- `emergencyWithdraw(token, to, amount)` (EMERGENCY_ROLE — pausado + delay)

---

## 5) Roles (resumen)

- `DEFAULT_ADMIN_ROLE` → otorga/revoca roles (recomendado en **multisig**).  
- `PAUSER_ROLE` → `pause`/`unpause`.  
- `FEED_ADMIN_ROLE` → `setFeed`, `setFeedStaleThreshold`, `updateLastValidPrice`.  
- `CONFIG_ADMIN_ROLE` → `setTokenConfig`.  
- `EMERGENCY_ROLE` → `emergencyWithdraw`.

> Buenas prácticas: otorgar sólo lo necesario y **revocar** permisos del deployer si no harán falta.

---

### Descargo
Este código está orientado a **entornos de prueba y formación**. Para uso productivo real, se recomienda auditoría externa, monitoreo on-chain y procedimientos operativos formales.
