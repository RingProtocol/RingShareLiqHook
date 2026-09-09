#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env.ring-backed-sepolia}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Missing $ENV_FILE; copy .env.ring-backed-sepolia.example first" >&2
    exit 1
fi

# Preserve per-command overrides. Values supplied before `bash sepolia.sh ...`
# must take precedence over defaults stored in the dotenv file.
override_names=(
    SIMULATE ACTION LIVE TOKEN_ADDR AMOUNT TO ZERO_FOR_ONE AMOUNT_SPECIFIED
    AMOUNT_LIMIT DEADLINE DEADLINE_FROM_NOW RUN_CHECKS SYNC_ONLY SQRT_PRICE_LIMIT_X96
)
override_values=()
override_present=()
for name in "${override_names[@]}"; do
    if [[ -v "$name" ]]; then
        override_present+=(1)
        override_values+=("${!name}")
    else
        override_present+=(0)
        override_values+=("")
    fi
done

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for i in "${!override_names[@]}"; do
    if [[ "${override_present[$i]}" == "1" ]]; then
        export "${override_names[$i]}=${override_values[$i]}"
    fi
done

: "${SEPOLIA_RPC_URL:?missing SEPOLIA_RPC_URL}"
: "${SEPOLIA_PRIVATE_KEY:?missing SEPOLIA_PRIVATE_KEY}"

chain_id="$(cast chain-id --rpc-url "$SEPOLIA_RPC_URL")"
if [[ "$chain_id" != "11155111" ]]; then
    echo "Wrong chain id: $chain_id (expected Sepolia 11155111)" >&2
    exit 1
fi

script_args=(--rpc-url "$SEPOLIA_RPC_URL" --private-key "$SEPOLIA_PRIVATE_KEY" -vv)
if [[ "${SIMULATE:-false}" != "true" ]]; then
    script_args+=(--broadcast)
fi

require_address() {
    local name="$1"
    local value="${!name:-}"
    if [[ ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$value" == "0x0000000000000000000000000000000000000000" ]]; then
        echo "Missing or invalid $name in $ENV_FILE" >&2
        exit 1
    fi
}

run_forge_script() {
    local target="$1"
    local output
    output="$(forge script "$target" "${script_args[@]}" 2>&1)" || {
        printf '%s\n' "$output"
        return 1
    }
    printf '%s\n' "$output"
    LAST_SCRIPT_OUTPUT="$output"
}

output_value() {
    local name="$1"
    printf '%s\n' "$LAST_SCRIPT_OUTPUT" | awk -v key="$name" '$1 == key { value=$2 } END { print value }'
}

save_env_value() {
    local name="$1"
    local value="$2"
    local temp_file="${ENV_FILE}.tmp"
    awk -v key="$name" -v replacement="$name=$value" '
        BEGIN { found=0 }
        $0 ~ "^" key "=" { print replacement; found=1; next }
        { print }
        END { if (!found) print replacement }
    ' "$ENV_FILE" > "$temp_file"
    mv "$temp_file" "$ENV_FILE"
    export "$name=$value"
}

require_output_address() {
    local name="$1"
    local value
    value="$(output_value "$name")"
    if [[ ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        echo "Could not read $name from forge output" >&2
        exit 1
    fi
    save_env_value "$name" "$value"
}

case "${1:-}" in
    check)
        forge build --sizes
        forge test --force --offline --threads 1
        ;;
    seed-ring)
        require_address FEW_FACTORY_ADDR
        require_address FEW_V2_FACTORY_ADDR
        require_address WETH_ADDR
        require_address FW_WETH_ADDR
        forge script scripts/ring-backed/SeedRingTestPool.s.sol:SeedRingTestPool "${script_args[@]}"
        ;;
    deploy)
        require_address POOL_MANAGER_ADDR
        require_address FEW_FACTORY_ADDR
        require_address FEW_V2_FACTORY_ADDR
        forge script scripts/ring-backed/DeployRingBacked.s.sol:DeployRingBacked "${script_args[@]}"
        ;;
    initialize)
        require_address RING_BACKED_HOOK_ADDR
        require_address TOKEN_A_ADDR
        require_address TOKEN_B_ADDR
        forge script scripts/ring-backed/InitializeRingBacked.s.sol:InitializeRingBacked "${script_args[@]}"
        ;;
    add-base-lp)
        require_address RING_BACKED_HOOK_ADDR
        require_address V4_POSITION_MANAGER_ADDR
        require_address PERMIT2_ADDR
        require_address TEST_TOKEN_ADDR
        require_address TOKEN_A_ADDR
        require_address TOKEN_B_ADDR
        forge script scripts/ring-backed/AddBasePosition.s.sol:AddBasePosition "${script_args[@]}"
        ;;
    swap)
        require_address RING_BACKED_HOOK_ADDR
        require_address RING_LP_ROUTER_ADDR
        require_address TOKEN_A_ADDR
        require_address TOKEN_B_ADDR
        if [[ -z "${DEADLINE:-}" ]]; then
            if [[ ! "${DEADLINE_FROM_NOW:-600}" =~ ^[0-9]+$ ]]; then
                echo "DEADLINE_FROM_NOW must be an integer number of seconds" >&2
                exit 1
            fi
            export DEADLINE="$(($(date +%s) + DEADLINE_FROM_NOW))"
        fi
        forge script scripts/ring-backed/SwapRingBacked.s.sol:SwapRingBacked "${script_args[@]}"
        ;;
    admin)
        require_address RING_BACKED_HOOK_ADDR
        forge script scripts/ring-backed/AdminRingBacked.s.sol:AdminRingBacked "${script_args[@]}"
        ;;
    deploy-all)
        if [[ "${SIMULATE:-false}" == "true" ]]; then
            echo "deploy-all cannot use SIMULATE=true because each later step needs contracts broadcast by the previous step" >&2
            exit 1
        fi
        require_address POOL_MANAGER_ADDR
        require_address V4_POSITION_MANAGER_ADDR
        require_address PERMIT2_ADDR
        require_address FEW_FACTORY_ADDR
        require_address FEW_V2_FACTORY_ADDR
        require_address WETH_ADDR
        require_address FW_WETH_ADDR

        if [[ "${RUN_CHECKS:-true}" == "true" ]]; then
            forge build --sizes
            forge test --force --offline --threads 1
        fi

        echo "[1/6] Creating RHT and seeding the Ring fwRHT/fwWETH pair"
        run_forge_script scripts/ring-backed/SeedRingTestPool.s.sol:SeedRingTestPool
        require_output_address TEST_TOKEN_ADDR
        require_output_address FW_TEST_TOKEN_ADDR
        require_output_address FEW_V2_PAIR_ADDR
        token_a="$(output_value TOKEN_A_ADDR)"
        token_b="$(output_value TOKEN_B_ADDR)"
        fw_currency0="$(printf '%s\n' "$LAST_SCRIPT_OUTPUT" | awk '$1 == "FW_PATH" && $2 == "currency0" { value=$3 } END { print value }')"
        fw_currency1="$(printf '%s\n' "$LAST_SCRIPT_OUTPUT" | awk '$1 == "FW_PATH" && $2 == "currency1" { value=$3 } END { print value }')"
        weth_to_test_zero_for_one="$(output_value WETH_TO_TEST_ZERO_FOR_ONE)"
        if [[ "$weth_to_test_zero_for_one" != "true" && "$weth_to_test_zero_for_one" != "false" ]]; then
            echo "Could not read WETH_TO_TEST_ZERO_FOR_ONE from forge output" >&2
            exit 1
        fi
        save_env_value TOKEN_A_ADDR "$token_a"
        save_env_value TOKEN_B_ADDR "$token_b"
        save_env_value FW_PATH "$fw_currency0,$fw_currency1"
        save_env_value ZERO_FOR_ONE "$weth_to_test_zero_for_one"
        require_address TOKEN_A_ADDR
        require_address TOKEN_B_ADDR
        token_a_lower="$(printf '%s' "$TOKEN_A_ADDR" | tr '[:upper:]' '[:lower:]')"
        weth_lower="$(printf '%s' "$WETH_ADDR" | tr '[:upper:]' '[:lower:]')"
        if [[ "$token_a_lower" == "$weth_lower" ]]; then
            # currency0=WETH, currency1=RHT: sqrt(1,000,000 RHT / 1 WETH) * 2^96.
            save_env_value INITIAL_SQRT_PRICE_X96 79228162514264337593543950336000
        else
            # currency0=RHT, currency1=WETH: sqrt(1 WETH / 1,000,000 RHT) * 2^96.
            save_env_value INITIAL_SQRT_PRICE_X96 79228162514264337593543950
        fi

        echo "[2/6] Deploying the Ring-backed Hook, CREATE2 factory and LP router"
        run_forge_script scripts/ring-backed/DeployRingBacked.s.sol:DeployRingBacked
        require_output_address RING_BACKED_FACTORY_ADDR
        require_output_address RING_BACKED_HOOK_ADDR
        require_output_address RING_LP_ROUTER_ADDR

        echo "[3/6] Initializing the Uniswap v4 pool and funding rounding reserves"
        run_forge_script scripts/ring-backed/InitializeRingBacked.s.sol:InitializeRingBacked

        echo "[4/6] Minting the permanent full-range v4 position"
        run_forge_script scripts/ring-backed/AddBasePosition.s.sol:AddBasePosition
        position_token_id="$(output_value V4_POSITION_TOKEN_ID)"
        [[ -n "$position_token_id" ]] && save_env_value V4_POSITION_TOKEN_ID "$position_token_id"

        echo "[5/6] Enabling Ring-backed swaps"
        export ACTION=setPoolLive
        export LIVE=true
        run_forge_script scripts/ring-backed/AdminRingBacked.s.sol:AdminRingBacked
        save_env_value LIVE true

        echo "[6/6] Verifying the deployed contracts"
        live="$(cast call "$RING_BACKED_HOOK_ADDR" 'live()(bool)' --rpc-url "$SEPOLIA_RPC_URL")"
        [[ "$live" == "true" ]] || { echo "Hook pool is not live" >&2; exit 1; }
        pair_code="$(cast code "$FEW_V2_PAIR_ADDR" --rpc-url "$SEPOLIA_RPC_URL")"
        [[ "$pair_code" != "0x" ]] || { echo "FewV2 pair has no bytecode" >&2; exit 1; }

        cat <<SUMMARY

Deployment complete and saved to $ENV_FILE
TEST_TOKEN_ADDR=$TEST_TOKEN_ADDR
FW_TEST_TOKEN_ADDR=$FW_TEST_TOKEN_ADDR
FEW_V2_PAIR_ADDR=$FEW_V2_PAIR_ADDR
RING_BACKED_HOOK_ADDR=$RING_BACKED_HOOK_ADDR
RING_LP_ROUTER_ADDR=$RING_LP_ROUTER_ADDR
V4_POSITION_TOKEN_ID=${V4_POSITION_TOKEN_ID:-unknown}
LIVE=$live

Import TEST_TOKEN_ADDR as RHT in the Sepolia frontend and use WETH_ADDR as the other pool token.
SUMMARY
        ;;
    *)
        echo "Usage: $0 {deploy-all|check|seed-ring|deploy|initialize|add-base-lp|swap|admin}" >&2
        echo "Set SIMULATE=true to simulate a script without broadcasting." >&2
        exit 1
        ;;
esac
