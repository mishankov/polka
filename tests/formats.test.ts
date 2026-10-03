import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { runTransform } from '../src/services/transforms';
import { FormatRunner } from '../src/services/formatRunner';
const run = (operation: string, input: unknown) => runTransform(operation, input).output;
test('JSON and YAML preserve data, diagnose malformed input and preserve YAML comments when formatting', () => {
  const data = { title: 'Привет 🌍', values: [true, null, 42], nested: { text: '<hello>&' } };
  const yaml = run('json.yaml', JSON.stringify(data)) as string;
  assert.deepEqual(run('yaml.parse', yaml), data);
  assert.deepEqual(JSON.parse(run('yaml.json', yaml) as string), data);
  assert.deepEqual(run('yaml.validate', yaml), { valid: true });
  assert.match(run('yaml.format', '# comment\na: 1\n') as string, /# comment/);
  assert.equal(run('json.format', '{"a":1}'), '{\n  "a": 1\n}');
  assert.throws(() => run('json.parse', '{broken'));
  assert.throws(() => run('yaml.parse', 'a: [broken'), /YAML/);
  assert.throws(() => run('yaml.parse', 'a: 1\na: 2'), /unique/);
  assert.throws(() => run('yaml.parse', 'a: !unknown foo'), /YAML/);
  assert.throws(() => run('yaml.json', 'value: .nan'), /NaN/);
  assert.throws(() => run('yaml.json', 'a: &a [*a]'), /циклических/);
  const bomb =
    'a: &a [1,2,3,4,5,6,7,8,9]\nb: &b [*a,*a,*a,*a,*a,*a,*a,*a,*a]\nc: &c [*b,*b,*b,*b,*b,*b,*b,*b,*b]\nd: [*c,*c,*c,*c,*c,*c,*c,*c,*c]';
  assert.throws(() => run('yaml.json', bomb), /alias|resource/i);
});
test('XML validates, preserves attributes and escapes text, and blocks external entities', () => {
  const source = '<root id="001"><item>hello &amp; world</item></root>';
  const data = run('xml.parse', source);
  assert.deepEqual(data, { root: { item: 'hello & world', '@_id': '001' } });
  assert.deepEqual(run('xml.parse', run('json.xml', JSON.stringify(data))), data);
  assert.deepEqual(run('xml.validate', run('xml.format', source)), { valid: true });
  assert.match(
    run('xml.format', '<root><!--keep--><item>x</item></root>') as string,
    /<!--keep-->/,
  );
  assert.throws(() => run('xml.parse', '<a></b>'), /XML/);
  assert.throws(
    () => run('xml.parse', '<!DOCTYPE x [<!ENTITY y SYSTEM "file:///etc/passwd">]><x>&y;</x>'),
    /DTD/,
  );
  assert(runTransform('xml.json', source).warnings.length > 0);
});
test('Base64 and hex distinguish Unicode text from binary and reject malformed input', () => {
  const text = 'Привет 🌍';
  for (const format of ['base64', 'hex']) {
    assert.equal(run(`${format}.decode`, run(`${format}.encode`, text)), text);
    assert.deepEqual(
      run(`${format}.bytes`, run(`bytes.${format}`, [0, 255, 128, 1])),
      [0, 255, 128, 1],
    );
    assert.throws(() => run(`${format}.decode`, run(`bytes.${format}`, [255])), /UTF-8/);
  }
  for (const input of ['%%%=', 'a===', 'AA=A', 'AAA'])
    assert.throws(() => run('base64.decode', input), /Base64/);
  for (const input of ['f', '0g', '00 11']) assert.throws(() => run('hex.decode', input), /Hex/);
  assert.throws(() => run('bytes.hex', [256]), /байтов/);
  assert.equal((run('hex.decode', '61'.repeat(250000)) as string).length, 250000);
  assert.throws(() => run('base64.encode', 'a'.repeat(1024 * 1024)), /1 МиБ/);
  assert.throws(() => run('image.rotate', 'x'), /Неизвестная/);
});
const workerPath = fileURLToPath(new URL('../out/main/transformWorker.js', import.meta.url));
test(
  'format worker returns results, cancels work and stays available after parser errors',
  { skip: !existsSync(workerPath) },
  async () => {
    const runner = new FormatRunner(workerPath);
    try {
      assert.equal((await runner.run('hex.decode', '6869')).output, 'hi');
      await assert.rejects(runner.run('yaml.parse', 'a: [broken'), /YAML/);
      const controller = new AbortController();
      const pending = runner.run('json.format', '{}', controller.signal);
      controller.abort();
      await assert.rejects(pending, /отменена/);
      assert.equal((await runner.run('json.format', '{}')).output, '{}');
    } finally {
      runner.close();
    }
  },
);
