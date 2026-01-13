// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

/*
    JSAT (Pareja 1:1) — Cuenta de ahorros conjunta con USDT + Earn en Aave

    IDEA (resumen):
    - Este contrato combina 2 cosas en 1:
      1) Un ERC20 “de membresía” (SOULBOUND) con supply total = 2 (1 token para cada miembro).
         - No es un token para transferir valor.
         - Sirve como “prueba on-chain” de que SOLO existen 2 miembros autorizados.
         - Transferencias, approvals y allowance están prohibidos.
      2) Un “vault” de USDT que deposita en Aave v3 para generar rendimiento.
         - Cada miembro deposita USDT.
         - El vault mete esos USDT en Aave para generar yield (aUSDT crece en balance con el tiempo).
         - El rendimiento se reparte proporcionalmente a la aportación usando “shares internas”.

    Objetivos de diseño:
    - Pareja fija 1:1 (sin terceros).
    - Nadie puede transferir el “token de membresía” a otra wallet (prohibido).
    - Depósitos individuales y retiros individuales (cada uno retira lo suyo).
    - Pagos comunes: se paga 50/50. Si hay “impar” (unidad mínima), lo paga quien tenga mayor capital.
    - Modo separación (divorcio/terminación): bloquea pagos comunes; depósitos y retiros individuales siguen permitidos.
    - “Granularidad óptima”: usamos la unidad mínima del USDT (normalmente 1 = 0.000001 USDT).

    Nota importante sobre USDT:
    - USDT suele tener 6 decimales (pero aquí NO asumimos nada; trabajamos en unidades mínimas).
    - Para depositar, cada usuario debe hacer approve() del USDT al contrato antes de llamar depositUSDT().
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Interface mínima del Pool de Aave v3 para supply/withdraw.
interface IAavePool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

contract JoinSavingToken is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =============================================================
    //                         MEMBRESÍA 1:1
    // =============================================================

    /// @notice Miembro A de la pareja (inmutable).
    address public immutable partnerA;

    /// @notice Miembro B de la pareja (inmutable).
    address public immutable partnerB;

    /// @notice ERC20 del capital (USDT).
    IERC20 public immutable usdt;

    /// @notice Pool Aave v3.
    IAavePool public immutable aavePool;

    /// @notice aToken correspondiente a USDT en Aave (aUSDT).
    /// @dev Lo pasamos por constructor para evitar dependencias de structs (más robusto en compilación).
    IERC20 public immutable aUSDT;

    /// @notice Estado del acuerdo: activo o separación (terminación / divorcio).
    enum State {
        ACTIVE, // Operativa normal (depósitos, retiros, pagos comunes)
        SEPARATED // Separación activada (solo depósitos y retiros individuales; pagos comunes bloqueados)
    }

    State public state;

    // =============================================================
    //                   VAULT: SHARES INTERNAS (PROPORCIONAL)
    // =============================================================

    /*
        ¿Por qué “shares internas”?
        - Aave genera rendimiento aumentando el balance del aUSDT del contrato con el tiempo.
        - Si lleváramos “balances fijos” por persona, tendríamos que recalcular/harvest.
        - Con shares internas:
            totalAssets = (aUSDT del contrato) + (USDT idle)
            assetsPerShare = totalAssets / totalShares
            balanceIndividual ≈ sharesIndividual * assetsPerShare
        - Así el yield se reparte automáticamente proporcional a las aportaciones.
    */

    mapping(address => uint256) private _shares;
    uint256 public totalShares;

    // =============================================================
    //                             ERRORES
    // =============================================================

    error NotPartner();
    error NonTransferable();
    error InvalidState();
    error ZeroAddress();
    error SameAddress();
    error InsufficientBalance();

    // =============================================================
    //                             EVENTOS
    // =============================================================

    event Deposited(
        address indexed partner,
        uint256 amountUSDT,
        uint256 mintedShares
    );
    event Withdrawn(
        address indexed partner,
        uint256 amountUSDT,
        uint256 burnedShares
    );
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
        if (msg.sender != partnerA && msg.sender != partnerB)
            revert NotPartner();
        _;
    }

    // =============================================================
    //                          CONSTRUCTOR
    // =============================================================

    /*
        Despliegue:
        - La pareja despliega el contrato indicando:
          partnerA, partnerB
          address USDT
          address AavePool
          address aUSDT (aToken de USDT)
        - El contrato:
          - Minta 1 token de membresía a cada uno (supply total = 2).
          - Deja aprobado USDT al Pool para poder hacer supply sin aprobar cada vez.

        Seguridad:
        - Direcciones inmutables: nadie puede “meterse”.
        - Token de membresía no se puede transferir jamás.
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
        ) {
            revert ZeroAddress();
        }
        if (_partnerA == _partnerB) revert SameAddress();

        partnerA = _partnerA;
        partnerB = _partnerB;

        usdt = IERC20(usdtAddress);
        aavePool = IAavePool(aavePoolAddress);
        aUSDT = IERC20(aUSDTAddress);

        // Membresía: 2 tokens exactos (no fraccionables): 1 token para cada partner.
        _mint(_partnerA, 1);
        _mint(_partnerB, 1);

        // Estado inicial
        state = State.ACTIVE;

        // Approve “infinito” al pool para mover USDT desde este contrato cuando hagamos supply.
        // (Patrón robusto: primero 0 y luego max, por compatibilidad con tokens “raros”.)
        usdt.approve(aavePoolAddress, 0);
        usdt.approve(aavePoolAddress, type(uint256).max);
    }

    // =============================================================
    //                    ERC20 DE MEMBRESÍA (SOULBOUND)
    // =============================================================

    /// @notice Queremos “2 tokens reales”, sin fracciones.
    function decimals() public pure override returns (uint8) {
        return 0;
    }

    /*
        En OpenZeppelin v5, ERC20 usa _update() para:
        - mint (from == address(0))
        - burn (to == address(0))
        - transfer normal (from != 0 && to != 0)

        Aquí prohibimos transferencias normales.
        Permitimos únicamente mint (solo ocurre en constructor).
        (No exponemos burn, así que nadie puede alterar supply.)
    */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    /// @dev Bloqueamos approvals/allowances para que no haya delegación ni transferFrom.
    function approve(address, uint256) public pure override returns (bool) {
        revert NonTransferable();
    }

    function allowance(
        address,
        address
    ) public pure override returns (uint256) {
        return 0;
    }

    function transferFrom(
        address,
        address,
        uint256
    ) public pure override returns (bool) {
        revert NonTransferable();
    }

    // =============================================================
    //                   VIEWS: “CUENTA DE AHORROS”
    // =============================================================

    /// @notice Total de USDT económicos del vault (en Aave + USDT idle en el contrato).
    function totalAssets() public view returns (uint256) {
        // aUSDT balance crece con el tiempo por el interés.
        return aUSDT.balanceOf(address(this)) + usdt.balanceOf(address(this));
    }

    /// @notice Shares internas de un miembro (no es un token, solo contabilidad interna).
    function sharesOf(address partner) external view returns (uint256) {
        return _shares[partner];
    }

    /// @notice Balance estimado en USDT (incluye yield) de un miembro.
    function balanceOfPartnerUSDT(
        address partner
    ) public view returns (uint256) {
        uint256 ts = totalShares;
        if (ts == 0) return 0;
        return (_shares[partner] * totalAssets()) / ts;
    }

    // =============================================================
    //                        DEPÓSITO / EARN
    // =============================================================

    /*
        depositUSDT:
        1) Recibe USDT del usuario (requiere approve previo en USDT).
        2) Calcula shares a mintear:
            - Si es el primer depósito: 1 share = 1 unidad mínima de USDT (1:1).
            - Si no: mintedShares = amount * totalShares / totalAssetsBefore
              (floor: estándar. Un redondeo mínimo beneficia a quienes ya están dentro.)
        3) Actualiza shares internas.
        4) Deposita ese USDT en Aave (supply) para generar earn.
    */
    function depositUSDT(uint256 amount) external onlyPartner nonReentrant {
        require(amount > 0, "Amount=0");

        uint256 assetsBefore = totalAssets();

        // Traer USDT al contrato
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        // Calcular shares a mintear
        uint256 mintedShares;
        if (totalShares == 0 || assetsBefore == 0) {
            mintedShares = amount; // 1:1 inicial
        } else {
            mintedShares = (amount * totalShares) / assetsBefore;

            // Si el depósito es extremadamente pequeño, podría dar 0 por el floor.
            // Para no “donar” dinero al pool sin recibir shares, forzamos mínimo 1 share.
            // (Esto es una decisión práctica; alternativa sería revertir si mintedShares == 0.)
            if (mintedShares == 0) mintedShares = 1;
        }

        _shares[msg.sender] += mintedShares;
        totalShares += mintedShares;

        // Meter en Aave (earn)
        aavePool.supply(address(usdt), amount, address(this), 0);

        emit Deposited(msg.sender, amount, mintedShares);
    }

    // =============================================================
    //                         RETIRO INDIVIDUAL
    // =============================================================

    /*
        withdrawMyUSDT:
        - Cada miembro retira SOLO su parte proporcional.
        - Para extraer `amount` USDT, quemamos shares equivalentes usando CEIL:
            sharesNeeded = ceil(amount * totalShares / totalAssets)
          (Ceil garantiza que se cubre el amount incluso con redondeo.)
        - Si no hay suficiente USDT idle, retiramos de Aave lo necesario.
    */
    function withdrawMyUSDT(uint256 amount) external onlyPartner nonReentrant {
        require(amount > 0, "Amount=0");

        uint256 burned = _burnSharesForAmount(msg.sender, amount);

        _ensureUSDTLiquidity(amount);
        usdt.safeTransfer(msg.sender, amount);

        emit Withdrawn(msg.sender, amount, burned);
    }

    // =============================================================
    //                          PAGO COMÚN 50/50
    // =============================================================

    /*
        payCommon:
        - Solo en estado ACTIVE.
        - El pago común se divide 50/50:
            base = amount / 2
            extra = amount % 2   (0 o 1 unidad mínima)
        - Si extra == 1, la unidad extra la paga quien tenga MAYOR capital en ese momento
          (incluyendo yield). Esto evita “perjudicar” al que va más justo.

        - Se implementa quemando shares equivalentes a la parte que paga cada uno,
          con CEIL para exactitud.
    */
    function payCommon(
        address to,
        uint256 amount
    ) external onlyPartner nonReentrant {
        if (state != State.ACTIVE) revert InvalidState();
        require(to != address(0), "Zero to");
        require(amount > 0, "Amount=0");

        uint256 base = amount / 2;
        uint256 extra = amount % 2; // granularidad óptima: unidad mínima del USDT

        // Balances actuales (incluyen yield)
        uint256 balA = balanceOfPartnerUSDT(partnerA);
        uint256 balB = balanceOfPartnerUSDT(partnerB);

        uint256 payA = base;
        uint256 payB = base;

        if (extra == 1) {
            // Si empatan, por eficiencia dejamos que A pague el extra (>=),
            // evitando estado extra (sin SSTORE) para alternar.
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
    //                    “DIVORCIO / TERMINACIÓN”: SEPARATION MODE
    // =============================================================

    /*
        triggerSeparation:
        - Cualquiera de los 2 puede activarlo.
        - Bloquea pagos comunes (payCommon).
        - Depósitos y retiros individuales siguen funcionando.
        - Sirve como “modo terminación” sin depender de terceros.
    */
    function triggerSeparation() external onlyPartner {
        if (state != State.ACTIVE) revert InvalidState();
        state = State.SEPARATED;
        emit SeparationTriggered(msg.sender);
    }

    // =============================================================
    //                           INTERNAS (CORE)
    // =============================================================

    /// @dev Quema shares suficientes (ceil) para cubrir `amount` USDT.
    function _burnSharesForAmount(
        address partner,
        uint256 amount
    ) internal returns (uint256 burnedShares) {
        uint256 assetsNow = totalAssets();
        uint256 ts = totalShares;

        require(ts > 0 && assetsNow > 0, "Empty vault");

        burnedShares = _sharesForAmountCeil(amount, assetsNow, ts);

        if (_shares[partner] < burnedShares) revert InsufficientBalance();

        _shares[partner] -= burnedShares;
        totalShares = ts - burnedShares;

        return burnedShares;
    }

    /// @dev sharesNeeded = ceil(amount * totalShares / totalAssets)
    function _sharesForAmountCeil(
        uint256 amount,
        uint256 assetsNow,
        uint256 ts
    ) internal pure returns (uint256) {
        // (amount * ts + assetsNow - 1) / assetsNow
        uint256 num = amount * ts;
        return (num + assetsNow - 1) / assetsNow;
    }

    /// @dev Si no hay suficiente USDT idle, retira de Aave exactamente lo necesario.
    function _ensureUSDTLiquidity(uint256 amount) internal {
        uint256 idle = usdt.balanceOf(address(this));
        if (idle >= amount) return;

        uint256 need = amount - idle;
        aavePool.withdraw(address(usdt), need, address(this));
    }
}
