import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { releaseVersion } from './release-version.mjs';

/** Versioned release notes travel in the same feed item as the authenticated archive. */
export async function readReleaseNotes(version, path = `release-notes/${version}.json`) {
  const notes = JSON.parse(await readFile(path, 'utf8'));
  for (const language of ['ru', 'en']) {
    if (
      typeof notes?.[language] !== 'string' ||
      !notes[language].trim() ||
      notes[language].length > 20_000
    )
      throw Error(
        `Release notes must include nonempty ru and en text (at most 20,000 characters each): ${path}`,
      );
  }
  return { ru: notes.ru.trim(), en: notes.en.trim() };
}

export function releaseNotesMarkdown(notes) {
  return `## Русский\n\n${notes.ru}\n\n## English\n\n${notes.en}\n`;
}

async function main() {
  try {
    if (process.argv[2] === '--version' && process.argv.length === 4) {
      console.log(releaseVersion(process.argv[3]));
    } else {
      const [tag, output, source] = process.argv.slice(2);
      if (!tag || !output || process.argv.length > 5)
        throw Error('Usage: node scripts/release-notes.mjs TAG OUTPUT.md [SOURCE.json]');
      const notes = await readReleaseNotes(releaseVersion(tag), source);
      await writeFile(output, releaseNotesMarkdown(notes));
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

// No npm dependencies or signing secrets: this also runs on the Ubuntu preparation job.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) void main();
