import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Run the actual Swift classifier against device fixtures, without touching audio hardware.
test(
  'native microphone detection requires device-backed input, not screenshot sound IO',
  { skip: process.platform !== 'darwin' },
  async () => {
    const directory = await mkdtemp(join(tmpdir(), 'everything-media-probe-test-'));
    const execute = promisify(execFile);
    try {
      const source = await readFile(new URL('../native/MediaProbe.swift', import.meta.url), 'utf8');
      const marker = '// CLI entry point.';
      assert.equal(source.split(marker).length, 2);
      const fixture = `
func check(_ name: String, _ expected: String, _ processes: [AudioObjectID]?,
           _ running: [AudioObjectID:UInt32], _ devices: [AudioObjectID:[AudioObjectID]],
           _ streams: [AudioObjectID:[AudioObjectID]]) {
 let actual = microphoneState(processes: processes, runningInput: { running[$0] },
                              inputDevices: { devices[$0] }, inputStreams: { streams[$0] })
 precondition(actual == expected, "\\(name): \\(actual), expected \\(expected)")
}
check("No audio", "inactive", [], [:], [:], [:])
check("Screenshot shutter / CoreSpeech without devices", "inactive", [1], [1:1], [1:[]], [:])
check("Playback on a duplex device", "inactive", [1], [1:0], [1:[10]], [10:[100]])
check("Device with no input streams", "inactive", [1], [1:1], [1:[10]], [10:[]])
check("Microphone input", "active", [1], [1:1], [1:[10]], [10:[100]])
check("Virtual microphone input", "active", [1], [1:1], [1:[20]], [20:[200]])
check("Screenshot plus a real microphone", "active", [1,2], [1:1,2:1], [1:[],2:[10]], [10:[100]])
check("Unreadable process list", "unknown", nil, [:], [:], [:])
check("Unreadable activity", "unknown", [1], [:], [:], [:])
check("Unreadable device list", "unknown", [1], [1:1], [:], [:])
check("Unreadable streams", "unknown", [1], [1:1], [1:[10]], [:])
check("One failing process cannot hide real input", "active", [1,2], [2:1], [2:[10]], [10:[100]])
print("12 native microphone cases passed")
`;
      const file = join(directory, 'main.swift');
      const binary = join(directory, 'test-media-probe');
      await writeFile(file, source.split(marker)[0] + fixture);
      await execute('swiftc', [
        file,
        '-o',
        binary,
        '-framework',
        'CoreAudio',
        '-framework',
        'CoreMediaIO',
        '-framework',
        'AVFoundation',
      ]);
      const { stdout } = await execute(binary);
      assert.match(stdout, /12 native microphone cases passed/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);
