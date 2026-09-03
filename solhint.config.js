module.exports = {
    extends: "solhint:recommended",
    rules: {
        "compiler-version": ["error", "^0.8.28"],
        "func-name-mixedcase": "off",
        "func-visibility": ["error", { ignoreConstructors: true }],
        "function-max-lines": "off",
        "gas-calldata-parameters": "error",
        "gas-indexed-events": "off",
        "gas-increment-by-one": "error",
        "gas-length-in-loops": "error",
        "gas-multitoken1155": "error",
        "gas-small-strings": "error",
        "gas-strict-inequalities": "off",
        "gas-struct-packing": "off",
        "immutable-vars-naming": "off",
        "import-path-check": "off",
        "max-states-count": "off",
        "no-empty-blocks": "off",
        "no-inline-assembly": "off",
        "use-natspec": "off",
        "var-name-mixedcase": "off"
    }
};
