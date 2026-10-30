#!/usr/bin/env node
import fs from 'fs';
import path from 'path';

const defaultBackup = '/home/dannybuntu/work/ws-notes/nostr-verifications/relay-backup-3y-2026-07-06';
const defaultPubkey = '1f9e547c2f31942623b8ad1d07713282e8640fd8cf474e9f79f18ace8af216ed';

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { backup: defaultBackup, pubkey: defaultPubkey };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--backup' || arg === '-b') {
      opts.backup = args[++i];
    } else if (arg === '--pubkey' || arg === '-p') {
      opts.pubkey = args[++i];
    } else if (arg === '--help' || arg === '-h') {
      console.log('Usage: node count-verifications-by-pubkey.mjs [--backup DIR] [--pubkey HEX]');
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return opts;
}

function getTag(event, name) {
  return event.tags?.find(t => t[0] === name)?.[1] ?? '';
}

function increment(map, key) {
  const normalized = key || '(missing)';
  map.set(normalized, (map.get(normalized) ?? 0) + 1);
}

function printCounter(title, map) {
  console.log(`\n${title}:`);
  for (const [key, count] of [...map.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))) {
    console.log(`${String(count).padStart(5)}  ${key}`);
  }
}

function main() {
  const { backup, pubkey } = parseArgs();
  const dir = path.join(backup, 'nostr-verification-events', '30301');
  if (!fs.existsSync(dir)) {
    throw new Error(`No 30301 backup directory found: ${dir}`);
  }

  const mine = [];
  for (const entry of fs.readdirSync(dir)) {
    if (!entry.endsWith('.json')) continue;
    const event = JSON.parse(fs.readFileSync(path.join(dir, entry), 'utf8'));
    if (event.pubkey === pubkey) mine.push(event);
  }

  const byStatus = new Map();
  const byPlatform = new Map();
  const byApp = new Map();
  const byMonth = new Map();
  let missingD = 0;

  for (const event of mine) {
    increment(byStatus, getTag(event, 'status'));
    increment(byPlatform, getTag(event, 'platform'));
    increment(byApp, getTag(event, 'i'));
    const month = event.created_at ? new Date(event.created_at * 1000).toISOString().slice(0, 7) : '(missing)';
    increment(byMonth, month);
    if (!event.tags?.some(t => t[0] === 'd')) missingD++;
  }

  console.log(`Backup: ${backup}`);
  console.log(`Pubkey: ${pubkey}`);
  console.log(`Final verification events by pubkey: ${mine.length}`);
  console.log(`Missing d tag: ${missingD}`);

  printCounter('By status', byStatus);
  printCounter('By platform', byPlatform);
  printCounter('By app', byApp);
  printCounter('By month', byMonth);
}

main();
