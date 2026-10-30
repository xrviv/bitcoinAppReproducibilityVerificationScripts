#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import { getVerificationReplaceableKey } from '/home/dannybuntu/work/walletScrutinyCom/src/verifications_common.mjs';

const defaultInput = '/home/dannybuntu/work/ws-notes/nostr-verifications/2026-07-06-missing-d-kind30301-edge-cache-events.json';
const defaultOut = '/home/dannybuntu/work/ws-notes/nostr-verifications/2026-07-06-missing-d-restore-plan.json';
const defaultPubkey = '1f9e547c2f31942623b8ad1d07713282e8640fd8cf474e9f79f18ace8af216ed';

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    input: defaultInput,
    out: defaultOut,
    pubkey: defaultPubkey,
    includeAllPubkeys: false,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--input' || arg === '-i') {
      opts.input = args[++i];
    } else if (arg === '--out' || arg === '-o') {
      opts.out = args[++i];
    } else if (arg === '--pubkey' || arg === '-p') {
      opts.pubkey = args[++i];
    } else if (arg === '--all-pubkeys') {
      opts.includeAllPubkeys = true;
    } else if (arg === '--help' || arg === '-h') {
      console.log(`Usage: node restore-missing-d-verifications-dry-run.mjs [options]

Dry-run only. Reads cached kind 30301 events that are missing d tags and computes
the deterministic replacement d tag now used by WalletScrutiny master.

Options:
  --input FILE       Cached missing-d event JSON array
  --out FILE         Restore plan JSON output
  --pubkey HEX       Limit to events authored by this pubkey
  --all-pubkeys      Include all cached pubkeys in the plan
`);
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

function getTags(event, name) {
  return event.tags?.filter(t => t[0] === name).map(t => t[1]).filter(Boolean) ?? [];
}

function withoutExistingDTag(tags) {
  return tags.filter(tag => tag[0] !== 'd');
}

function withDTagFirst(event, dTagValue) {
  return [['d', dTagValue], ...withoutExistingDTag(event.tags ?? [])];
}

function summarizeEvent(event, newTags) {
  const hashes = getTags({ ...event, tags: newTags }, 'x');
  return {
    old_id: event.id,
    old_created_at: event.created_at,
    pubkey: event.pubkey,
    kind: event.kind,
    status: getTag({ ...event, tags: newTags }, 'status'),
    app: getTag({ ...event, tags: newTags }, 'i'),
    version: getTag({ ...event, tags: newTags }, 'version'),
    platform: getTag({ ...event, tags: newTags }, 'platform'),
    hashes,
    old_d: getTag(event, 'd') || null,
    new_d: getTag({ ...event, tags: newTags }, 'd'),
    tags_preview: newTags,
  };
}

function buildPlan(events, opts) {
  const selected = events
    .filter(event => event.kind === 30301)
    .filter(event => opts.includeAllPubkeys || event.pubkey === opts.pubkey)
    .filter(event => !event.tags?.some(t => t[0] === 'd'));

  const plan = [];
  const skipped = [];

  for (const event of selected) {
    const appId = getTag(event, 'i');
    const version = getTag(event, 'version');
    const platform = getTag(event, 'platform');
    const hashes = getTags(event, 'x');
    const missing = [];
    if (!appId) missing.push('i');
    if (!version) missing.push('version');
    if (!platform) missing.push('platform');
    if (!hashes.length) missing.push('x');

    if (missing.length) {
      skipped.push({ id: event.id, pubkey: event.pubkey, missing });
      continue;
    }

    const newD = getVerificationReplaceableKey(appId, version, platform, hashes);
    const newTags = withDTagFirst(event, newD);
    plan.push({
      ...summarizeEvent(event, newTags),
      unsigned_template: {
        kind: event.kind,
        created_at: event.created_at,
        content: event.content,
        tags: newTags,
      },
    });
  }

  return { selected_count: selected.length, plan, skipped };
}

function main() {
  const opts = parseArgs();
  const events = JSON.parse(fs.readFileSync(opts.input, 'utf8'));
  const result = {
    generated_at: new Date().toISOString(),
    mode: 'dry-run',
    note: 'This does not publish or sign. Adding a d tag changes the event id and requires re-signing by the original author.',
    input: opts.input,
    output: opts.out,
    pubkey_filter: opts.includeAllPubkeys ? null : opts.pubkey,
    source_event_count: events.length,
    ...buildPlan(events, opts),
  };

  fs.mkdirSync(path.dirname(opts.out), { recursive: true });
  fs.writeFileSync(opts.out, `${JSON.stringify(result, null, 2)}\n`);

  console.log(`Input events: ${events.length}`);
  console.log(`Selected missing-d events: ${result.selected_count}`);
  console.log(`Plan entries: ${result.plan.length}`);
  console.log(`Skipped incomplete events: ${result.skipped.length}`);
  console.log(`Wrote: ${opts.out}`);
  console.log('Dry-run only: no signing, no publishing.');
}

main();
