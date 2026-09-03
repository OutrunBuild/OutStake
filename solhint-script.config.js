// script dispatch
const base = require("./solhint.config");

module.exports = {
    ...base,
    rules: {
        ...base.rules,
        // Deployment scripts print operator-facing diagnostics; console output costs no on-chain gas.
        "no-console": "off",
        // Script revert strings are operator-facing diagnostics; the 32-char limit is a prod gas concern.
        "reason-string": "off",
        // Gas rules model deployed-bytecode costs; script bytecode is never deployed.
        "gas-calldata-parameters": "off",
        "gas-custom-errors": "off",
        "gas-increment-by-one": "off",
        "gas-length-in-loops": "off",
        "gas-small-strings": "off"
    }
};
