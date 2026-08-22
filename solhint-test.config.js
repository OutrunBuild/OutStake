const base = require("./solhint.config");

module.exports = {
    ...base,
    rules: {
        ...base.rules,
        "avoid-low-level-calls": "off",
        "check-send-result": "off",
        // Parametrized invariant suites encode fuzz parameters in contract names (Test_18_6).
        "contract-name-capwords": "off",
        "gas-custom-errors": "off",
        "gas-calldata-parameters": "off",
        "gas-increment-by-one": "off",
        "gas-length-in-loops": "off",
        "gas-strict-inequalities": "off",
        "gas-small-strings": "off",
        "multiple-sends": "off",
        "no-console": "off",
        "one-contract-per-file": "off",
        // Test revert strings are self-describing failure diagnostics; the 32-char limit is a prod gas concern.
        "reason-string": "off"
    }
};
