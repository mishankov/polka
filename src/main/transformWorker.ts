import { parentPort, workerData } from 'node:worker_threads';
import {
  runTransform,
  transforms,
  validatePipeline,
  type TransformStep,
} from '../services/transforms';
const { items, steps } = workerData as {
  items: { id: string; name: string; input: unknown; revision?: number }[];
  steps: TransformStep[];
};
const results: any[] = [];
let completed = 0,
  outputBytes = 0;
try {
  validatePipeline(steps);
  for (const item of items) {
    let value = item.input;
    const warnings: string[] = [];
    let index = 0;
    try {
      for (const step of steps) {
        index++;
        const result = runTransform(step.operation, value, step.options);
        value = result.output;
        warnings.push(...result.warnings.filter((w): w is string => !!w));
        parentPort!.postMessage({
          type: 'progress',
          completed: ++completed,
          total: items.length * steps.length,
          current: item.name,
        });
      }
      const size = Buffer.byteLength(JSON.stringify(value));
      outputBytes += size;
      if (outputBytes > 32 * 1024 * 1024) throw Error('Суммарный результат превышает 32 МБ');
      results.push({
        id: item.id,
        name: item.name,
        revision: item.revision,
        output: value,
        outputType: transforms.find((t) => t.id === steps.at(-1)!.operation)!.output,
        warnings: [...new Set(warnings)],
      });
    } catch (error) {
      completed = (results.length + 1) * steps.length;
      results.push({
        id: item.id,
        name: item.name,
        revision: item.revision,
        error: `Шаг ${index}: ${error instanceof Error ? error.message : String(error)}`,
      });
      parentPort!.postMessage({
        type: 'progress',
        completed,
        total: items.length * steps.length,
        current: item.name,
      });
    }
  }
  parentPort!.postMessage({ type: 'done', results });
} catch (error) {
  parentPort!.postMessage({
    type: 'error',
    error: error instanceof Error ? error.message : String(error),
  });
}
