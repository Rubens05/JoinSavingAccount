### Cuenta de Ahorro Conjunta para Parejas (USDT + Aave) 💍💰 

**JSAT** es un smart contract diseñado para **parejas 1:1** que funciona como una **cuenta de ahorro conjunta on-chain**, inspirada en las cuentas bancarias tradicionales y en el principio de **separación de bienes**.

Permite a dos personas:
- Ahorrar conjuntamente en USDT
- Generar rentabilidad automática mediante **Aave v3**
- Pagar gastos comunes de forma justa (50/50)
- Mantener balances individuales proporcionales
- Separar fondos de forma limpia si la relación termina

Todo se ejecuta **on-chain**, sin terceros, sin administradores y sin posibilidad de intervención externa.

---

## 🧪 Estado del proyecto

Este proyecto es una **Prueba de Concepto (PoC)**.

- ❌ No está desplegado en mainnet
- ❌ No ha sido auditado
- ❌ No está pensado todavía para uso en producción
- ✔️ Diseñado para aprendizaje, debate y experimentación

Se agradecen contribuciones, feedback y sugerencias.

## ✨ Características principales

- 🧑‍🤝‍🧑 **Pareja fija (1:1)** — solo dos direcciones, inmutables
- 🔐 **Token de membresía Soulbound**
  - ERC20 con supply total = 2
  - 1 token por cada miembro
  - No transferible (no se puede mover ni vender)
- 💵 **Vault de USDT**
  - Depósitos individuales
  - Retiros individuales
- 📈 **Rentabilidad automática**
  - Todo el USDT se deposita en **Aave v3**
  - El rendimiento se acumula vía aUSDT
- ⚖️ **Pagos compartidos justos**
  - Gastos comunes al 50/50
  - Si el importe es impar (en unidades mínimas), la unidad extra la paga quien tenga mayor capital
- 🧮 **Contabilidad proporcional**
  - El rendimiento se reparte proporcionalmente a la aportación
- 💔 **Modo separación**
  - Bloquea los pagos comunes
  - Mantiene activos los retiros y depósitos individuales

---

## 🧠 Filosofía de diseño

- **Sin confianza**: las reglas se aplican por código
- **Sin control externo**: no hay admin, oráculos ni upgrades
- **Eficiente en gas**: lógica mínima, sin estados innecesarios
- **Máxima precisión**: se usa la unidad mínima del USDT
- **Rentabilidad real**: el yield proviene de Aave, no es simulado

---

## 🏗️ Arquitectura del contrato

### 1. Capa de membresía (ERC20 Soulbound)
- Supply total: `2`
- Decimales: `0`
- Uso: identidad y autorización
- Transferencias y approvals deshabilitados

### 2. Capa Vault (USDT)
- Custodia USDT y aUSDT
- Deposita automáticamente en Aave
- Retira de Aave cuando es necesario

### 3. Capa de contabilidad (Shares internas)
- Cada miembro tiene “shares” internas
- Representan una proporción del total
- El valor de las shares crece con el yield

---

## 🔒 Seguridad

- Usa contratos de **OpenZeppelin**
- Usa **SafeERC20** para USDT
- Protegido contra reentrancy
- Sin callbacks externos
- Lógica inmutable (no upgradeable)

---

## 📦 Requisitos

- Solidity `^0.8.24`
- OpenZeppelin Contracts v5
- Red compatible con **Aave v3**
- USDT desplegado en la red elegida

---

## 🚀 Tutorial de despliegue (Remix + Arbitrum)

### 1️⃣ Abrir Remix
https://remix.ethereum.org

---

### 2️⃣ Crear el archivo
- Crear un archivo llamado `JointSavingToken.sol`
- Pegar el código del contrato

---

### 3️⃣ Compilar
- Ir a **Solidity Compiler**
- Versión: `0.8.24`
- Activar:
  - ✔️ Optimization
- Click en **Compile**

---

### 4️⃣ Preparar MetaMask
- Añadir red **Arbitrum One**
- Tener ETH en Arbitrum para gas

---

### 5️⃣ Direcciones en Arbitrum One (ejemplo)

> ⚠️ Verifica siempre direcciones oficiales antes de desplegar

```text
USDT:       0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9
Aave Pool:  0x794a61358D6845594F94dc1DB02A252b5b4814aD
aUSDT:      0x6ab707Aca953eDAeFBc4fD23bA73294241490620
