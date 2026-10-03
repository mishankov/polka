import { parentPort, workerData } from 'node:worker_threads';
import { runTransform } from '../services/transforms';
try {
  parentPort!.postMessage({ result: runTransform(workerData.operation, workerData.input) });
} catch (error) {
  parentPort!.postMessage({ error: error instanceof Error ? error.message : String(error) });
}
