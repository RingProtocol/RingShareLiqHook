#!/usr/bin/env python3
"""Turn verbose Foundry scenario logs into compact, human-readable reports."""

from __future__ import annotations

import re
import sys
from decimal import Decimal


FIELD = re.compile(r"^\s{2}([A-Z][A-Z0-9_]*)(?:\s+(.*))?$")
PASS = re.compile(r"^\[PASS\]\s+([^ ]+)")
SUMMARY = re.compile(r"^(Ran |Suite result:|Error:|Failing tests:|Encountered )")


def amount(raw: str, symbol: str) -> str:
    try:
        value = Decimal(raw.split()[0]) / Decimal(10**18)
    except Exception:
        return raw
    rendered = f"{value:,.12f}".rstrip("0").rstrip(".")
    return f"{rendered} {symbol}"


def signed_delta(before: str, after: str, symbol: str) -> str:
    change = Decimal(after.split()[0]) - Decimal(before.split()[0])
    sign = "+" if change >= 0 else "-"
    rendered = f"{abs(change) / Decimal(10**18):,.12f}".rstrip("0").rstrip(".")
    return f"{sign}{rendered} {symbol}"


def row(label: str, left: str, right: str | None = None) -> None:
    if right is None:
        print(f"  {label:<25} {left}")
    else:
        print(f"  {label:<25} {left:<30} {right}")


def render(data: dict[str, str], passed: bool = True) -> None:
    if not data or "TRADE" not in data:
        return
    zero_for_one = data.get("ZERO_FOR_ONE") == "true"
    input_symbol, output_symbol = ("RHT", "WETH") if zero_for_one else ("WETH", "RHT")
    title = data["TRADE"]
    print()
    print("┌" + "─" * 76 + "┐")
    print(f"│ {title[:74]:<74} │")
    print("├" + "─" * 76 + "┤")

    if "QUOTE_FAILED_SELECTOR" in data:
        row("Result", f"QUOTE FAILED ({data['QUOTE_FAILED_SELECTOR']})")
        print("└" + "─" * 76 + "┘")
        return

    row("Mode", "exact input" if data.get("EXACT_INPUT") == "true" else "exact output")
    row("User", amount(data["ACTUAL_USER_INPUT"], input_symbol), "→ " + amount(data["ACTUAL_USER_OUTPUT"], output_symbol))
    row("Ring execution", amount(data["QUOTE_RING_INPUT"], input_symbol), "→ " + amount(data["QUOTE_RING_OUTPUT"], output_symbol))
    base_out = data.get("QUOTE_BASE_OUTPUT", "0")
    share = Decimal(data.get("QUOTE_BASE_OUTPUT_SHARE_BPS", "0").split()[0]) / Decimal(100)
    row("Permanent LP output", amount(base_out, output_symbol), f"({share:.2f}% of user output)")
    row("JIT liquidity (raw)", data.get("QUOTE_JIT_LIQUIDITY", "0").split()[0])

    if data.get("QUOTE_RING_OUTPUT", "0").split()[0] == "0":
        row("Warning", "RING NOT USED; permanent LP filled 100%")

    print("├" + "─" * 76 + "┤")
    row(
        "Permanent LP RHT",
        amount(data["BASE_LP_TOKEN0_BEFORE"], "RHT"),
        "→ " + amount(data["BASE_LP_TOKEN0_AFTER"], "RHT")
        + "  "
        + signed_delta(data["BASE_LP_TOKEN0_BEFORE"], data["BASE_LP_TOKEN0_AFTER"], "RHT"),
    )
    row(
        "Permanent LP WETH",
        amount(data["BASE_LP_TOKEN1_BEFORE"], "WETH"),
        "→ " + amount(data["BASE_LP_TOKEN1_AFTER"], "WETH")
        + "  "
        + signed_delta(data["BASE_LP_TOKEN1_BEFORE"], data["BASE_LP_TOKEN1_AFTER"], "WETH"),
    )
    row(
        "Ring reserve RHT",
        amount(data["RING_RHT_BEFORE"], "RHT"),
        "→ " + amount(data["RING_RHT_AFTER"], "RHT"),
    )
    row(
        "Ring reserve WETH",
        amount(data["RING_WETH_BEFORE"], "WETH"),
        "→ " + amount(data["RING_WETH_AFTER"], "WETH"),
    )
    row("v4 tick", data.get("V4_TICK_BEFORE", "?"), "→ " + data.get("V4_TICK_AFTER", "?"))
    row("Status", "PASS" if passed else "FAIL")
    print("└" + "─" * 76 + "┘")


def main() -> None:
    current: dict[str, str] = {}
    pending_key: str | None = None
    passed = True
    summaries: list[str] = []

    for raw_line in sys.stdin:
        line = raw_line.rstrip("\n")
        match = FIELD.match(line)
        if match:
            key, value = match.groups()
            value = value or ""
            if key == "TRADE" and "TRADE" in current:
                render(current, passed)
                current = {}
                passed = True
            if value:
                current[key] = value
                pending_key = None
            else:
                pending_key = key
            continue
        if pending_key and line.strip():
            current[pending_key] = line.strip()
            pending_key = None
            continue
        pass_match = PASS.match(line)
        if pass_match:
            if "TRADE" in current:
                render(current, True)
                current = {}
            continue
        if line.startswith("[FAIL"):
            passed = False
        if SUMMARY.match(line):
            summaries.append(line)

    render(current, passed)
    print()
    print("Foundry summary")
    print("─" * 77)
    for line in summaries[-4:]:
        print(line)


if __name__ == "__main__":
    main()
