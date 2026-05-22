"""Tiny structural check for action.yml — catches the typos that would
break `uses: bellwether-run/ingest-action@v1` for every downstream
consumer at once. Runs in CI via .github/workflows/lint.yml.
"""

from __future__ import annotations

import sys

import yaml


def main() -> int:
    with open("action.yml") as fh:
        spec = yaml.safe_load(fh)

    if not isinstance(spec, dict):
        print("action.yml: not a mapping at top level", file=sys.stderr)
        return 1

    failures: list[str] = []

    if not spec.get("name"):
        failures.append("missing `name`")
    if not spec.get("description"):
        failures.append("missing `description`")
    if spec.get("runs", {}).get("using") != "composite":
        failures.append("`runs.using` must be `composite`")
    inputs = spec.get("inputs") or {}
    if "bellwether_token" not in inputs:
        failures.append("must declare `inputs.bellwether_token`")
    if "api_url" not in inputs:
        failures.append("must declare `inputs.api_url`")

    if failures:
        for f in failures:
            print(f"action.yml: {f}", file=sys.stderr)
        return 1

    print("action.yml: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
