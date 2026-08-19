#!/usr/bin/env python3
"""Apply local slither patches for Solidity 0.8.35 ERC-7201 storage layout support.

slither 0.11.5 crashes while parsing the ERC-7201 `layout at erc7201("...")`
storage layout syntax. Two patches are required, with a strict causal order:

  - find_variable.py: guard against `source_mapping=None` so that building the
    VariableNotFound message does not raise AttributeError first (which would
    truncate the real VariableNotFound).
  - contract.py: catch that VariableNotFound and, only for the erc7201 case,
    set the parsed storage layout to None and continue analysis.

The script is idempotent: re-running after patching prints already-patched and
exits 0. If an anchor is missing, slither may have changed/fixed its source and
this script must be reviewed; the script exits 1 in that case.

Standard library only.
"""

import os
import sys


def locate_slither_dir():
    import slither

    return os.path.dirname(slither.__file__)


# (relative path, anchor, replacement, patched-state marker)
PATCHES = [
    (
        os.path.join("solc_parsing", "declarations", "contract.py"),
        (
            '        if "storageLayout" in attributes:\n'
            "            # For now we care only about the actual value, hence we immediately parse the expression\n"
            "            # and ConstantFold it later on since it could be using a TopLevel variable\n"
            "            self._storage_layout_parsed_expression = parse_expression(\n"
            '                attributes["storageLayout"]["baseSlotExpression"], self\n'
            "            )"
        ),
        (
            '        if "storageLayout" in attributes:\n'
            "            # For now we care only about the actual value, hence we immediately parse the expression\n"
            "            # and ConstantFold it later on since it could be using a TopLevel variable\n"
            "            try:\n"
            "                self._storage_layout_parsed_expression = parse_expression(\n"
            '                    attributes["storageLayout"]["baseSlotExpression"], self\n'
            "                )\n"
            "            except VariableNotFound as e:\n"
            "                # Solidity 0.8.35+ erc7201() storage layout is not supported by slither yet\n"
            '                if "erc7201" not in str(e):\n'
            "                    raise\n"
            "                self._storage_layout_parsed_expression = None"
        ),
        "            except VariableNotFound as e:",
    ),
    (
        os.path.join("solc_parsing", "expressions", "find_variable.py"),
        (
            "    raise VariableNotFound(\n"
            '        f"Variable not found: {var_name} (context {contract} {contract.source_mapping.to_detailed_str()})"\n'
            "    )"
        ),
        (
            "    raise VariableNotFound(\n"
            '        f"Variable not found: {var_name} (context {contract} {contract.source_mapping.to_detailed_str() if contract and contract.source_mapping else \'unavailable\'})"\n'
            "    )"
        ),
        "if contract and contract.source_mapping else",
    ),
]


def main():
    base = locate_slither_dir()
    print(f"slither install dir: {base}")

    for rel_path, anchor, replacement, patched_marker in PATCHES:
        path = os.path.join(base, rel_path)
        print(f"\n--- {rel_path} ---")

        if not os.path.isfile(path):
            print(f"ERROR: target file not found: {path}")
            sys.exit(1)

        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        if patched_marker in content:
            print("status: already-patched (no change)")
            continue

        if anchor not in content:
            print(
                "ERROR: anchor not found. slither may have fixed or changed its "
                "source for this file. Review this script against the installed "
                f"slither version before re-running.\n  file: {path}"
            )
            sys.exit(1)

        new_content = content.replace(anchor, replacement, 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)

        print("status: before=unpatched -> after=patched")

    print("\nDone.")


if __name__ == "__main__":
    main()
