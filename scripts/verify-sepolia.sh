#!/usr/bin/env bash
# Verify deployed contract source code on Sepolia Etherscan.
#
# Usage:
#   ./scripts/verify-sepolia.sh
#
# Requires (from .env or exported):
#   ETHERSCAN_API_KEY   - Etherscan API key
#   SEPOLIA_RPC_URL     - Sepolia RPC (optional, only for pre-checks)
#
# Addresses are pinned to the 2026-08-26 deployment recorded in
# ringshareliq-sepolia-20260826.md. Override via env vars (see below) to verify
# a different deployment.

set -euo pipefail

cd "$(dirname "$0")/.."

# ── Load .env if present (does not override already-exported vars) ─────────
if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
fi

: "${ETHERSCAN_API_KEY:?ETHERSCAN_API_KEY is required (get one at https://etherscan.io/myapikey)}"

# ── Addresses (override via env) ───────────────────────────────────────────
ALLOWLISTED_FACTORY_ADDR="${ALLOWLISTED_FACTORY_ADDR:-0x25e63DB69e8d100A147656cfe1d3b87F4cd088ef}"
HOOK_ADDR="${HOOK_ADDR:-0x744e0Fd70A64990215A63C9e91fb328f9EC0EaC0}"
ROUTER_ADDR="${ROUTER_ADDR:-0xE0CC9a73c69B8F7468d08d2b8e029C7A633639b9}"
POOL_MANAGER_ADDR="${POOL_MANAGER_ADDR:-0xE03A1074c86CFeDd5C142C4F04F1a1536e203543}"
FEW_FACTORY_ADDR="${FEW_FACTORY_ADDR:-0x226e65279E177A779522864Ce1dE40c85E2C08A5}"
OWNER_ADDR="${OWNER_ADDR:-0x87555dd0e101817c1bc7867e32451b080C55f596}"
MAX_GAS="${MAX_GAS:-1000000}"
HOOK_CREATION_CODE_HASH="${HOOK_CREATION_CODE_HASH:-0xd88bdab32efd4bc3e4c925fd0b7ba82f449ecca56f0d93584a02b5af8ee93552}"

CHAIN="sepolia"
VERIFIER="etherscan"
# Etherscan V2 unified API (V1 is deprecated). V2 takes chainid as a query param.
VERIFIER_URL="https://api.etherscan.io/v2/api?chainid=11155111"
SOLC_VERSION="0.8.26"

# ── Helper: run forge verify-contract and check result ─────────────────────
verify() {
    local label="$1"
    local addr="$2"
    local contract="$3"
    local ctor_args="$4"

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Verifying $label"
    echo "    address : $addr"
    echo "    contract: $contract"
    echo "════════════════════════════════════════════════════════════════"

    if forge verify-contract \
        --chain-id 11155111 \
        --verifier "$VERIFIER" \
        --verifier-url "$VERIFIER_URL" \
        --compiler-version "v$SOLC_VERSION" \
        --constructor-args "$ctor_args" \
        --watch \
        "$addr" "$contract" 2>&1; then
        echo "  ✅ $label verified"
    else
        echo "  ❌ $label verification FAILED (see output above)"
        return 1
    fi
}

# ── Compute ABI-encoded constructor args ───────────────────────────────────
# AllowlistedFactory(bytes32[] creationCodeHashes)  -> 1-element array
FACTORY_CTOR=$(cast abi-encode "f(bytes32[])" "[$HOOK_CREATION_CODE_HASH]")

# RingShareLiqHook(IPoolManager, uint32, address, IFewFactory)
HOOK_CTOR=$(cast abi-encode "f(address,uint32,address,address)" \
    "$POOL_MANAGER_ADDR" "$MAX_GAS" "$OWNER_ADDR" "$FEW_FACTORY_ADDR")

# PoolSwapTest(IPoolManager)  -- from v4-core
ROUTER_CTOR=$(cast abi-encode "f(address)" "$POOL_MANAGER_ADDR")

# ── Run verifications ──────────────────────────────────────────────────────
FAIL=0

verify "AllowlistedFactory" \
    "$ALLOWLISTED_FACTORY_ADDR" \
    "src/factory/AllowlistedFactory.sol:AllowlistedFactory" \
    "$FACTORY_CTOR" || FAIL=1

verify "RingShareLiqHook" \
    "$HOOK_ADDR" \
    "src/hooks/RingShareLiqHook.sol:RingShareLiqHook" \
    "$HOOK_CTOR" || FAIL=1

verify "PoolSwapTest (router)" \
    "$ROUTER_ADDR" \
    "lib/v4-core/src/test/PoolSwapTest.sol:PoolSwapTest" \
    "$ROUTER_CTOR" || FAIL=1

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
if [[ "$FAIL" -eq 0 ]]; then
    echo "  All contracts verified on Sepolia Etherscan ✅"
    echo ""
    echo "  AllowlistedFactory: https://sepolia.etherscan.io/address/$ALLOWLISTED_FACTORY_ADDR#code"
    echo "  RingShareLiqHook  : https://sepolia.etherscan.io/address/$HOOK_ADDR#code"
    echo "  PoolSwapTest      : https://sepolia.etherscan.io/address/$ROUTER_ADDR#code"
else
    echo "  Some verifications failed ❌ — check output above."
fi
echo "════════════════════════════════════════════════════════════════"
exit "$FAIL"
