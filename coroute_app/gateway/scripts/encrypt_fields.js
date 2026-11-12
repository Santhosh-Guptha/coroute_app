'use strict';
/**
 * 3.57 one-off (optional): encrypts every protected field now instead of waiting for the lazy migration
 * (src/field_crypto.js re-encrypts a document the first time it is read). Safe to run more than once, safe while
 * the gateways run (compare-and-replace: a document changed meanwhile is skipped and done by the next read).
 *
 *   node scripts/encrypt_fields.js            # dry run: counts only
 *   node scripts/encrypt_fields.js --write    # re-encrypts users and convoy_riders
 *
 * Needs DATA_ENC_KEY (and DATA_ENC_KEYS_PREVIOUS for values written with older keys). Take a backup first
 * (scripts/backup_restore.js or the Object Storage backup job). Prints counts only, never values.
 */
const { createSoda } = require('../src/app');
const { fieldCryptoFromConfig, FIELD_SPEC } = require('../src/field_crypto');
const config = require('../src/config');

(async () => {
  const write = process.argv.includes('--write');
  const fc = fieldCryptoFromConfig(config, console);
  if (!fc.enabled) { console.error('DATA_ENC_KEY is not set: nothing to do.'); process.exit(2); }
  const soda = createSoda(); // raw client: documents as stored
  for (const coll of Object.keys(FIELD_SPEC).filter((c) => FIELD_SPEC[c].lazy)) {
    let seen = 0; let todo = 0; let done = 0; let skipped = 0;
    for await (const page of soda.scan(coll, { pageSize: 200 })) {
      for (const row of page) {
        seen++;
        if (!fc.docNeedsMigration(coll, row.value)) continue;
        todo++;
        if (!write) continue;
        if (await soda.compareAndReplace(coll, row.key, row.value, fc.migrateDoc(coll, row.value))) done++; else skipped++;
      }
    }
    console.log(`${coll}: ${seen} documents, ${todo} to encrypt${write ? `, ${done} encrypted, ${skipped} changed meanwhile (left to the lazy migration)` : ' (dry run)'}`);
  }
  if (fc.missingKids.size) console.error(`Values with unknown key ids: ${[...fc.missingKids].join(', ')} — set DATA_ENC_KEYS_PREVIOUS.`);
})().catch((e) => { console.error(e.message); process.exit(1); });
