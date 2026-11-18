import test from 'node:test';
import assert from 'node:assert/strict';
import { commercialQuantityForDay, fiscalPeriod, freightForDeparture, localDateTime } from '../utils/commercialPlanning';
import type { FreightSchedule, StrategicProjection } from '../types';

test('the ISO week year stays correct when January belongs to the previous year', () => {
    assert.deepEqual(fiscalPeriod(new Date(2027, 0, 1)), { year: 2026, week: 53 });
    assert.deepEqual(fiscalPeriod(new Date(2026, 10, 11)), { year: 2026, week: 46 });
});

test('daily commercial demand uses dated quantities, including multiple departures on one day', () => {
    const goal = { proyeccionCajas: 990, lunes: 800, desgloseDiario: [
        { fecha: '2026-11-11T08:00', cantidad: 300 },
        { fecha: '2026-11-11T14:00', cantidad: 200 },
        { fecha: '2026-11-12T08:00', cantidad: 490 }
    ] } as StrategicProjection;
    assert.equal(commercialQuantityForDay(goal, '2026-11-11'), 500);
    assert.equal(commercialQuantityForDay(goal, '2026-11-12'), 490);
    assert.equal(commercialQuantityForDay(goal, '2026-11-13'), 0);
});

test('an explicit zero quantity does not fall back to the entire weekly goal', () => {
    const goal = { proyeccionCajas: 990, desgloseDiario: [{ fecha: '2026-11-11T08:00', cantidad: 0 }] } as StrategicProjection;
    assert.equal(commercialQuantityForDay(goal, '2026-11-11'), 0);
});

test('legacy projections with a single departure retain their commercial demand', () => {
    const goal = { proyeccionCajas: 990, fechaSalida: '2026-11-11' } as StrategicProjection;
    assert.equal(commercialQuantityForDay(goal, '2026-11-11'), 990);
    assert.equal(commercialQuantityForDay(goal, '2026-11-12'), 0);
    assert.equal(localDateTime(new Date(2026, 10, 11, 8, 5)), '2026-11-11T08:05');
});

test('Embarques only offers freight scheduled for the selected client and real departure day', () => {
    const schedules = [
        { id: 'match', carrierId: 'carrier-a', scheduledDate: '2026-11-11', proyeccion: { clientId: 'client-a' } },
        { id: 'wrong-client', carrierId: 'carrier-b', scheduledDate: '2026-11-11', proyeccion: { clientId: 'client-b' } },
        { id: 'wrong-day', carrierId: 'carrier-c', scheduledDate: '2026-11-12', proyeccion: { clientId: 'client-a' } }
    ] as FreightSchedule[];
    assert.deepEqual(freightForDeparture(schedules, '2026-11-11', 'client-a').map(s => s.id), ['match']);
    assert.deepEqual(freightForDeparture(schedules, '2026-11-13', 'client-a'), []);
});
