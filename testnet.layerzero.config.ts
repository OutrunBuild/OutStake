import { EndpointId } from "@layerzerolabs/lz-definitions";
const base_sepoliaContract = {
    eid: EndpointId.BASESEP_V2_TESTNET,
    contractName: "OutrunUniversalPrincipalToken",
};
const bsc_testnetContract = {
    eid: EndpointId.BSC_V2_TESTNET,
    contractName: "OutrunUniversalPrincipalToken",
};
const scroll_sepoliaContract = {
    eid: EndpointId.SCROLL_V2_TESTNET,
    contractName: "OutrunUniversalPrincipalToken",
};
export default {
    contracts: [
        { contract: base_sepoliaContract },
        { contract: bsc_testnetContract },
        { contract: scroll_sepoliaContract },
    ],
    connections: [
        {
            from: base_sepoliaContract,
            to: bsc_testnetContract,
            config: {
                sendLibrary: "0xC1868e054425D378095A003EcbA3823a5D0135C9",
                receiveLibraryConfig: {
                    receiveLibrary: "0x12523de19dc41c91F7d2093E0CFbB76b17012C8d",
                    gracePeriod: 0,
                },
                sendConfig: {
                    executorConfig: {
                        maxMessageSize: 10000,
                        executor: "0x8A3D588D9f6AC041476b094f97FF94ec30169d3D",
                    },
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ["0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: base_sepoliaContract,
            to: scroll_sepoliaContract,
            config: {
                sendLibrary: "0xC1868e054425D378095A003EcbA3823a5D0135C9",
                receiveLibraryConfig: {
                    receiveLibrary: "0x12523de19dc41c91F7d2093E0CFbB76b17012C8d",
                    gracePeriod: 0,
                },
                sendConfig: {
                    executorConfig: {
                        maxMessageSize: 10000,
                        executor: "0x8A3D588D9f6AC041476b094f97FF94ec30169d3D",
                    },
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: bsc_testnetContract,
            to: base_sepoliaContract,
            config: {
                sendLibrary: "0x55f16c442907e86D764AFdc2a07C2de3BdAc8BB7",
                receiveLibraryConfig: {
                    receiveLibrary: "0x188d4bbCeD671A7aA2b5055937F79510A32e9683",
                    gracePeriod: 0,
                },
                sendConfig: {
                    executorConfig: {
                        maxMessageSize: 10000,
                        executor: "0x31894b190a8bAbd9A067Ce59fde0BfCFD2B18470",
                    },
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ["0x0eE552262f7B562eFcED6DD4A7e2878AB897d405"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0x0eE552262f7B562eFcED6DD4A7e2878AB897d405"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: bsc_testnetContract,
            to: scroll_sepoliaContract,
            config: {
                sendLibrary: "0x55f16c442907e86D764AFdc2a07C2de3BdAc8BB7",
                receiveLibraryConfig: {
                    receiveLibrary: "0x188d4bbCeD671A7aA2b5055937F79510A32e9683",
                    gracePeriod: 0,
                },
                sendConfig: {
                    executorConfig: {
                        maxMessageSize: 10000,
                        executor: "0x31894b190a8bAbd9A067Ce59fde0BfCFD2B18470",
                    },
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ["0x0eE552262f7B562eFcED6DD4A7e2878AB897d405"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0x0eE552262f7B562eFcED6DD4A7e2878AB897d405"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: scroll_sepoliaContract,
            to: base_sepoliaContract,
            config: {
                sendLibrary: "0x21f1C2B131557c3AebA918D590815c47Dc4F20aa",
                receiveLibraryConfig: {
                    receiveLibrary: "0xf2dB23f9eA1311E9ED44E742dbc4268de4dB0a88",
                    gracePeriod: 0,
                },
                sendConfig: {
                    executorConfig: {
                        maxMessageSize: 10000,
                        executor: "0xD0D47C34937DdbeBBe698267a6BbB1dacE51198D",
                    },
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0xb186F85d0604FE58af2Ea33fE40244f5EEF7351B"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0xb186F85d0604FE58af2Ea33fE40244f5EEF7351B"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: scroll_sepoliaContract,
            to: bsc_testnetContract,
            config: {
                sendLibrary: "0x21f1C2B131557c3AebA918D590815c47Dc4F20aa",
                receiveLibraryConfig: {
                    receiveLibrary: "0xf2dB23f9eA1311E9ED44E742dbc4268de4dB0a88",
                    gracePeriod: 0,
                },
                sendConfig: {
                    executorConfig: {
                        maxMessageSize: 10000,
                        executor: "0xD0D47C34937DdbeBBe698267a6BbB1dacE51198D",
                    },
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ["0xb186F85d0604FE58af2Ea33fE40244f5EEF7351B"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ["0xb186F85d0604FE58af2Ea33fE40244f5EEF7351B"],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
    ],
};
