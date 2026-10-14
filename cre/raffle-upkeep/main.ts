// CRE workflow that replaces Chainlink Automation for the Raffle: on a cron schedule it reads `checkUpkeep` and, when
// upkeep is needed, sends a report to RaffleUpkeepReceiver, which calls `performUpkeep`.
import {
  bytesToHex,
  cre,
  encodeCallMsg,
  EVMClient,
  getNetwork,
  LAST_FINALIZED_BLOCK_NUMBER,
  prepareReportRequest,
  Runner,
  TxStatus,
  type Runtime,
} from "@chainlink/cre-sdk";
import {
  decodeFunctionResult,
  encodeAbiParameters,
  encodeFunctionData,
  isAddress,
  parseAbi,
  zeroAddress,
  type Address,
} from "viem";
import { z } from "zod";

// The SDK needs the schema's input and output types to match, so addresses stay strings (cast where used).
const address = z
  .string()
  .refine((value) => isAddress(value) && value !== zeroAddress, "must be a deployed contract address");

const configSchema = z.object({
  chainSelectorName: z.string(),
  raffleAddress: address,
  receiverAddress: address,
  // Cron expression with seconds; CRE's shortest interval is 30 seconds.
  schedule: z.string(),
  // Gas for the forwarder's call into the receiver, which runs performUpkeep and the VRF request.
  writeGasLimit: z.string(),
});
type Config = z.infer<typeof configSchema>;

const raffleAbi = parseAbi(["function checkUpkeep(bytes) view returns (bool upkeepNeeded, bytes performData)"]);

function evmClientFor(config: Config): EVMClient {
  const network = getNetwork({ chainFamily: "evm", chainSelectorName: config.chainSelectorName });
  if (!network) throw new Error(`Network not found: ${config.chainSelectorName}`);
  return new EVMClient(network.chainSelector.selector);
}

const onCronTrigger = (runtime: Runtime<Config>): string => {
  const config = runtime.config;
  const evmClient = evmClientFor(config);

  // Every node in the DON must see the same state, so CRE reads at the last finalized block. On Sepolia that lags
  // the head by about 13 minutes; the receiver re-checks on-chain and skips reports that have gone stale.
  const result = evmClient
    .callContract(runtime, {
      call: encodeCallMsg({
        from: zeroAddress,
        to: config.raffleAddress as Address,
        data: encodeFunctionData({ abi: raffleAbi, functionName: "checkUpkeep", args: ["0x"] }),
      }),
      blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
    })
    .result();
  const [upkeepNeeded] = decodeFunctionResult({
    abi: raffleAbi,
    functionName: "checkUpkeep",
    data: bytesToHex(result.data),
  });

  if (!upkeepNeeded) {
    runtime.log("Upkeep not needed; skipping.");
    return "skipped";
  }

  // The report names the raffle, so a receiver bound to a different raffle rejects it.
  const report = runtime
    .report(prepareReportRequest(encodeAbiParameters([{ type: "address" }], [config.raffleAddress as Address])))
    .result();
  const write = evmClient
    .writeReport(runtime, {
      receiver: config.receiverAddress,
      report,
      gasConfig: { gasLimit: config.writeGasLimit },
    })
    .result();
  if (write.txStatus !== TxStatus.SUCCESS) {
    throw new Error(`Report write failed: ${write.errorMessage || write.txStatus}`);
  }

  // Empty (0x) in a dry-run simulation, which prepares the transaction without sending it.
  const txHash = bytesToHex(write.txHash ?? new Uint8Array());
  runtime.log(`Upkeep report sent: ${txHash}`);
  return txHash;
};

function initWorkflow(config: Config) {
  return [cre.handler(new cre.capabilities.CronCapability().trigger({ schedule: config.schedule }), onCronTrigger)];
}

export async function main() {
  const runner = await Runner.newRunner<Config>({ configSchema });
  await runner.run(initWorkflow);
}

main();
