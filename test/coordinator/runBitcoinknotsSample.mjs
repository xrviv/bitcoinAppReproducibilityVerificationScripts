#!/usr/bin/env node

/**
 * Sample queue runner for Bitcoin Knots.
 *
 * Reads `data/verification-queue.json`, filters for desktop/bitcoinknots items,
 * pulls the `targets:` list from `_desktop/bitcoinknots.md`, and invokes
 * `verify_bitcoinknots.sh` once per target. Intended as a prototype for the
 * Phase 2 coordinator.
 */

import { readFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { spawnSync } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const siteRoot =
  process.env.WS_SITE_ROOT ||
  join(__dirname, '..', '..', '..', 'walletScrutinyCom');
const queuePath = join(siteRoot, 'data', 'verification-queue.json');
const mdPath = join(siteRoot, '_desktop', 'bitcoinknots.md');
const scriptPath = join(__dirname, '..', 'desktop', 'verify_bitcoinknots.sh');

function parseFrontmatter(content) {
  const match = content.match(/^---\n([\s\S]*?)\n---/);
  if (!match) return {};

  const lines = match[1].split('\n');
  const data = {};
  let currentKey = null;

  for (const rawLine of lines) {
    const line = rawLine.trimEnd();
    const keyMatch = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);

    if (keyMatch) {
      currentKey = keyMatch[1];
      const value = keyMatch[2].trim();
      if (value) {
        data[currentKey] = value;
        currentKey = null;
      } else {
        data[currentKey] = [];
      }
      continue;
    }

    if (line.startsWith('- ') && currentKey) {
      if (!Array.isArray(data[currentKey])) data[currentKey] = [];
      data[currentKey].push(line.slice(2).trim());
    }
  }

  return data;
}

function normalizeTarget(entry) {
  if (!entry) return '';

  const trimmed = entry.trim();
  if (!trimmed) return '';

  // If already looks like a Guix host triple, return as-is
  if (/^[A-Za-z0-9._-]+-(linux-gnu|apple-darwin|w64-mingw32)$/.test(trimmed)) {
    return trimmed;
  }

  const withoutExt = trimmed.replace(/\.(tar\.gz|tar\.xz|zip|exe|dmg)$/i, '');

  const knownMappings = {
    'x86_64-linux-gnu': 'x86_64-linux-gnu',
    'aarch64-linux-gnu': 'aarch64-linux-gnu',
    'arm-linux-gnueabihf': 'arm-linux-gnueabihf',
    'powerpc64-linux-gnu': 'powerpc64-linux-gnu',
    'powerpc64le-linux-gnu': 'powerpc64le-linux-gnu',
    'riscv64-linux-gnu': 'riscv64-linux-gnu',
    'x86_64-apple-darwin': 'x86_64-apple-darwin',
    'arm64-apple-darwin': 'arm64-apple-darwin',
    'x86_64-w64-mingw32': 'x86_64-w64-mingw32',
    'win64-setup-pgpverifiable': 'x86_64-w64-mingw32',
    'win64-pgpverifiable': 'x86_64-w64-mingw32',
    'win64-codesigning': 'x86_64-w64-mingw32',
    'source': 'source'
  };

  if (knownMappings[withoutExt]) {
    return knownMappings[withoutExt];
  }

  if (knownMappings[trimmed]) {
    return knownMappings[trimmed];
  }

  return trimmed;
}

function readTargets() {
  if (!existsSync(mdPath)) {
    throw new Error(`Markdown file not found: ${mdPath}`);
  }
  const content = readFileSync(mdPath, 'utf8');
  const frontmatter = parseFrontmatter(content);
  const rawTargets = Array.isArray(frontmatter.targets) ? frontmatter.targets : [];
  const targets = rawTargets
    .map(normalizeTarget)
    .filter(Boolean);
  const version = frontmatter.version || '';
  return { targets, version };
}

function readQueue() {
  if (!existsSync(queuePath)) {
    console.warn(`Queue file not found: ${queuePath}`);
    return [];
  }
  try {
    const payload = JSON.parse(readFileSync(queuePath, 'utf8'));
    return Array.isArray(payload.queue) ? payload.queue : [];
  } catch (err) {
    console.warn(`Failed to parse queue file: ${err.message}`);
    return [];
  }
}

function run() {
  const { targets, version: frontmatterVersion } = readTargets();
  if (targets.length === 0) {
    console.error('No targets defined in bitcoinknots.md front matter.');
    process.exit(1);
  }

  const queueItems = readQueue().filter(
    item =>
      item.platform === 'desktop' &&
      item.appId === 'bitcoinknots'
  );

  if (queueItems.length === 0) {
    console.log('No pending queue items for bitcoinknots. Running with front matter version only.');
  }

  const versionsToRun = new Set();
  if (frontmatterVersion) versionsToRun.add(frontmatterVersion);
  queueItems.forEach(item => {
    if (item.version) versionsToRun.add(item.version);
  });

  if (versionsToRun.size === 0) {
    console.error('No version available (queue/front matter both missing).');
    process.exit(1);
  }

  for (const version of versionsToRun) {
    console.log(`\n=== Processing Bitcoin Knots v${version} ===`);
    for (const target of targets) {
      const args = ['--target', target, '-v', version];
      console.log(`\n→ Running ${scriptPath} ${args.join(' ')}`);
      const result = spawnSync(scriptPath, args, { stdio: 'inherit' });
      if (result.error) {
        console.error(`Failed to spawn script for target ${target}: ${result.error.message}`);
        continue;
      }
      console.log(`← Target ${target} exit code: ${result.status}`);
    }
  }
}

run();
