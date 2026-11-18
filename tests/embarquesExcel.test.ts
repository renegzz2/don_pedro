import test from 'node:test';
import assert from 'node:assert/strict';
import * as XLSX from 'xlsx';
import { extractTransportFields, parseContinuous, parseTemperature } from '../utils/embarquesExcel';

test('a real xlsx round trip extracts editable transport data from labels and tabular headers', () => {
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([
        ['Operador:', '', 'Ana López'],
        ['Placas tractor', 'Placas caja', 'Económico'],
        ['TR-8821', 'CJ-4011', '00123'],
        ['Pies: 53'],
        ['Termógrafo', 'T-450'],
        ['Temp. programada (°F)', '-5.5 °F'],
        ['Termo en continuo', 'Sí']
    ]), 'Datos');
    XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet([
        ['PRODUCTO', 'CAJAS', 'PALLET'], ['Cebolla', 45, '01']
    ]), 'Layout');
    const loaded = XLSX.read(XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' }), { type: 'buffer' });
    const fields = extractTransportFields(loaded.SheetNames.map(name => XLSX.utils.sheet_to_json(loaded.Sheets[name], { header: 1, defval: '' }) as unknown[][]));
    assert.equal(fields.operador, 'Ana López');
    assert.equal(fields.placasTractor, 'TR-8821');
    assert.equal(fields.placasCaja, 'CJ-4011');
    assert.equal(fields.economico, '00123');
    assert.equal(fields.pies, '53');
    assert.equal(fields.termografo, 'T-450');
    assert.equal(parseTemperature(fields.temperatura!), -5.5);
    assert.equal(parseContinuous(fields.continuo!), 'Sí');
});

test('zero temperature and a negative continuous flag remain valid values', () => {
    assert.equal(parseTemperature('0 °F'), 0);
    assert.equal(parseTemperature('-2,5'), -2.5);
    assert.equal(parseContinuous('NO'), 'No');
    assert.equal(parseContinuous('pendiente'), undefined);
});

test('pallet-only workbooks leave transport fields absent rather than inventing values', () => {
    assert.deepEqual(extractTransportFields([[['PRODUCTO', 'CAJAS', 'PALLET'], ['Cebolla', 45, 1]]]), {});
});
