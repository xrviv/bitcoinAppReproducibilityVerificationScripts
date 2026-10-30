#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';

const require = createRequire('/home/dannybuntu/work/walletScrutinyCom/package.json');
const WebSocket = require('ws');

const eventRelayUrls = [
  'wss://relay.nostr.info/',
  'wss://nostr.mom/',
  'wss://relay.primal.net/',
  'wss://relay.damus.io/',
  'wss://nos.lol/',
];

const opinionKind = 30023;
const codeSnippetKind = 1337;
const relayScannedKinds = [1063, 9401, 30301, 30801, 30802, codeSnippetKind, 31871];
const verificationKinds = relayScannedKinds;
const defaultOut = '/home/dannybuntu/work/ws-notes/nostr-verifications/relay-backup-3y-2026-07-06';
const defaultDays = 1095;
const pageLimit = 500;
const timeoutMs = 20000;

const knownWalletScrutinyPubkeys = [
  '168b7a2cd8bb9205c3f574de540606d6f4c46717c5164f47373fdcce2b9cd335',
  '1f9e547c2f31942623b8ad1d07713282e8640fd8cf474e9f79f18ace8af216ed',
  '6274e238b289e1b2e98e4e6ce600dcc0cb2e2c03db9b850260ff8bdd6bbf2a45',
  '46fcbe3065eaf1ae7811465924e48923363ff3f526bd6f73d7c184b16bd8ce4d',
  '03b5036dc3db82604307c1964d2b926417a91c3b11ef75ba6ca55019e9b7a62a',
];

function loadSeedAuthors() {
  const authors = new Set(knownWalletScrutinyPubkeys);
  const roots = [
    '/home/dannybuntu/work/walletScrutinyCom/backup/nostr-verification-events',
    '/home/dannybuntu/work/ws-notes/nostr-verifications/relay-backup-3y-2026-07-06/nostr-verification-events',
  ];
  for (const root of roots) {
    if (!fs.existsSync(root)) continue;
    for (const kindDir of fs.readdirSync(root)) {
      const dir = path.join(root, kindDir);
      if (!fs.statSync(dir).isDirectory()) continue;
      for (const file of fs.readdirSync(dir)) {
        if (!file.endsWith('.json')) continue;
        try {
          const event = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
          if (event?.pubkey) authors.add(event.pubkey);
        } catch {}
      }
    }
  }
  return [...authors];
}


function parseArgs() {
  const args = process.argv.slice(2);
  const opts = { days: defaultDays, out: defaultOut };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--days' || arg === '-d') {
      opts.days = Number.parseInt(args[++i], 10);
    } else if (arg === '--out' || arg === '-o') {
      opts.out = args[++i];
    } else if (arg === '--help' || arg === '-h') {
      console.log('Usage: node ws-nostr-backup-current.mjs [--days N] [--out DIR]');
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isFinite(opts.days) || opts.days <= 0) throw new Error('--days must be a positive number');
  if (!opts.out) throw new Error('--out is required');
  return opts;
}

function eventPath(baseDir, event) {
  const eventTypeDir = event.kind === opinionKind ? 'nostr-opinion-events' : 'nostr-verification-events';
  return path.join(baseDir, eventTypeDir, String(event.kind), `${event.id}.json`);
}

function ensureDirs(baseDir) {
  for (const kind of verificationKinds) {
    fs.mkdirSync(path.join(baseDir, 'nostr-verification-events', String(kind)), { recursive: true });
  }
  fs.mkdirSync(path.join(baseDir, 'nostr-opinion-events', String(opinionKind)), { recursive: true });
}

function getTag(event, name) {
  return event.tags?.find(t => t[0] === name)?.[1];
}

function isValidWalletScrutinyEvent(event) {
  if (!event || !event.id || !event.kind) return false;
  if (event.kind === opinionKind) {
    const hasNostrOpinion = event.tags?.some(t => t[0] === 't' && t[1] === 'nostrOpinion');
    const hasWalletScrutiny = event.tags?.some(t => t[0] === 't' && (t[1] === 'WalletScrutiny' || t[1] === 'WalletScrutiny.com'));
    return Boolean(hasNostrOpinion && hasWalletScrutiny);
  }
  return getTag(event, 'client') === 'WalletScrutiny.com';
}

function fetchPage(relayUrl, filter) {
  return new Promise(resolve => {
    const events = [];
    let done = false;
    let ws;
    const timer = setTimeout(() => finish('timeout'), timeoutMs);

    function finish(reason) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { ws?.close(); } catch {}
      const oldest = events.length ? Math.min(...events.map(e => e.created_at ?? Infinity)) : null;
      resolve({ events, oldest, reason });
    }

    ws = new WebSocket(relayUrl);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', `ws-backup-${Date.now()}`, { ...filter, limit: pageLimit }])));
    ws.on('message', data => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[2]) events.push(msg[2]);
        if (msg[0] === 'EOSE') finish('eose');
      } catch {}
    });
    ws.on('error', () => finish('error'));
    ws.on('close', () => finish('close'));
  });
}

async function fetchAllFromRelay(relayUrl, filter, since) {
  const all = new Map();
  let until;
  let pages = 0;

  while (true) {
    pages++;
    const pageFilter = until ? { ...filter, until } : filter;
    const { events, oldest, reason } = await fetchPage(relayUrl, pageFilter);

    for (const event of events) if (!all.has(event.id)) all.set(event.id, event);
    process.stdout.write(`    page ${pages}: ${events.length} events (${reason})\n`);

    if (events.length < pageLimit || oldest === null) break;
    const nextUntil = oldest - 1;
    if (nextUntil < since) break;
    if (until !== undefined && nextUntil >= until) break;
    until = nextUntil;
  }

  return [...all.values()];
}

function fetchIdsFromRelay(relayUrl, ids) {
  return new Promise(resolve => {
    const events = [];
    let done = false;
    let ws;
    const timer = setTimeout(() => finish('timeout'), timeoutMs);

    function finish(reason) {
      if (done) return;
      done = true;
      clearTimeout(timer);
      try { ws?.close(); } catch {}
      resolve({ events, reason });
    }

    ws = new WebSocket(relayUrl);
    ws.on('open', () => ws.send(JSON.stringify(['REQ', `ws-id-backup-${Date.now()}`, { ids }])));
    ws.on('message', data => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg[0] === 'EVENT' && msg[2]) events.push(msg[2]);
        if (msg[0] === 'EOSE') finish('eose');
      } catch {}
    });
    ws.on('error', () => finish('error'));
    ws.on('close', () => finish('close'));
  });
}

async function fetchReferencedFileAttachments(relayUrls, ids) {
  const found = new Map();
  const batchSize = 100;
  const batches = [];
  for (let i = 0; i < ids.length; i += batchSize) batches.push(ids.slice(i, i + batchSize));

  for (const relay of relayUrls) {
    console.log(`\nRelay: ${relay}`);
    console.log('  Filter: referenced-file-attachments');
    let relayFound = 0;
    for (let i = 0; i < batches.length; i++) {
      const { events, reason } = await fetchIdsFromRelay(relay, batches[i]);
      relayFound += events.length;
      for (const event of events) if (!found.has(event.id)) found.set(event.id, event);
      process.stdout.write(`    id batch ${i + 1}/${batches.length}: ${events.length} events (${reason})\n`);
    }
    console.log(`  referenced-file-attachments: ${relayFound} raw events`);
  }

  return [...found.values()];
}

async function main() {
  const { days, out } = parseArgs();
  const since = Math.floor((Date.now() - days * 24 * 60 * 60 * 1000) / 1000);

  ensureDirs(out);
  console.log(`Output: ${out}`);
  console.log(`Since: ${since} (${new Date(since * 1000).toISOString()})`);
  console.log(`Relays: ${eventRelayUrls.join(', ')}`);
  const authorPubkeys = loadSeedAuthors();
  console.log(`Author pubkeys: ${authorPubkeys.length}`);

  const seen = new Map();
  const filters = [
    { name: 'walletscrutiny-events', filter: { kinds: relayScannedKinds, since, authors: authorPubkeys } },
    { name: 'walletscrutiny-opinions', filter: { kinds: [opinionKind], since, '#t': ['nostrOpinion'], authors: authorPubkeys } },
  ];

  for (const relay of eventRelayUrls) {
    console.log(`\nRelay: ${relay}`);
    for (const { name, filter } of filters) {
      console.log(`  Filter: ${name}`);
      const events = await fetchAllFromRelay(relay, filter, since);
      console.log(`  ${name}: ${events.length} raw events`);
      for (const event of events) if (!seen.has(event.id)) seen.set(event.id, event);
    }
  }

  const referencedFileIds = new Set();
  for (const event of seen.values()) {
    if (!isValidWalletScrutinyEvent(event)) continue;
    for (const tag of event.tags ?? []) {
      if (tag[0] === 'file-attachment' && tag[1]) referencedFileIds.add(tag[1]);
    }
  }

  console.log(`\nReferenced file-attachment ids: ${referencedFileIds.size}`);
  if (referencedFileIds.size > 0) {
    const attachmentEvents = await fetchReferencedFileAttachments(eventRelayUrls, [...referencedFileIds]);
    for (const event of attachmentEvents) if (!seen.has(event.id)) seen.set(event.id, event);
  }

  let saved = 0;
  let existing = 0;
  let invalid = 0;
  const byKind = {};

  for (const event of seen.values()) {
    if (!isValidWalletScrutinyEvent(event)) {
      invalid++;
      continue;
    }
    const file = eventPath(out, event);
    if (fs.existsSync(file)) existing++;
    else {
      fs.writeFileSync(file, JSON.stringify(event, null, 2));
      saved++;
    }
    byKind[event.kind] = (byKind[event.kind] || 0) + 1;
  }

  const summary = {
    generated_at: new Date().toISOString(),
    days,
    since,
    output: out,
    relays: eventRelayUrls,
    author_pubkeys: authorPubkeys,
    raw_unique_events: seen.size,
    valid_walletscrutiny_events: Object.values(byKind).reduce((a, b) => a + b, 0),
    referenced_file_attachment_ids: referencedFileIds.size,
    saved,
    existing,
    invalid,
    by_kind: byKind,
  };
  fs.writeFileSync(path.join(out, 'backup-summary.json'), JSON.stringify(summary, null, 2));

  console.log('\nSummary:');
  console.log(JSON.stringify(summary, null, 2));
}

main().catch(error => {
  console.error(error);
  process.exit(1);
});
