import { readFileSync, writeFileSync } from 'node:fs';
const root = new URL('../', import.meta.url);
const files = ['202611130001_transport_catalog_history.sql','202611130002_multistop_trips.sql','202611130003_historical_receipts.sql','202611130004_weekly_shipment_history.sql','202611130005_fixed_departure_temperature.sql'];
const sections = files.map(file => '-- ' + file + '\n' + readFileSync(new URL('supabase/migrations/' + file, root), 'utf8').replace(/^begin;\s*/, '').replace(/\s*commit;\s*$/, ''));
writeFileSync(new URL('supabase/activate_20261113.sql', root), '-- Run once after the 20261111 and 20261112 migrations. All changes are atomic.\nbegin;\n\n' + sections.join('\n\n') + '\n\ncommit;\n');
console.log('SQL de activación actualizado desde las cinco migraciones.');
