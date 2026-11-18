import test from 'node:test';
import assert from 'node:assert/strict';
import { consolidateLoads } from '../utils/packingPlanning';
import { commercialQuantityForDay } from '../utils/commercialPlanning';
import type { ProductoDB, StrategicProjection } from '../types';
const day = '2026-11-12';
const products = [{ id: 'a', cajasPalletUsa: 60 }, { id: 'b', cajasPalletUsa: 40 }] as ProductoDB[];
const types = [{ id: 'small', name: 'Torton', capacity: 10 }, { id: 'large', name: 'Thermo', capacity: 26 }];
const goal = (id: string, product: string, boxes: number) => ({ id, productoId: product, proyectoId: 'project', proyeccionCajas: boxes, packingPlan: [{ fecha: day, cantidad: boxes }] }) as StrategicProjection;

test('a new commercial goal does not reserve transport before packing is planned', () => {
    const g = { ...goal('1', 'a', 600), packingPlan: [], fechaSalida: day, desgloseDiario: [{ fecha: day, cantidad: 600 }] };
    assert.equal(commercialQuantityForDay(g, day), 0);
    assert.deepEqual(consolidateLoads([g], day, products, types), []);
});
test('different products share a single unit and retain their box allocations', () => {
    const loads = consolidateLoads([goal('1', 'a', 300), goal('2', 'b', 200)], day, products, types);
    assert.equal(loads.length, 1);
    assert.equal(loads[0].unit.id, 'small');
    assert.equal(loads[0].pallets, 10);
    assert.deepEqual(loads[0].allocations.map(a => a.quantity), [300, 200]);
});
test('overflow creates another unit without losing boxes or exceeding capacity', () => {
    const loads = consolidateLoads([goal('1', 'a', 1500), goal('2', 'b', 120)], day, products, types);
    assert.equal(loads.length, 2);
    assert.deepEqual(loads.map(l => l.pallets), [26, 2]);
    assert.equal(loads.flatMap(l => l.allocations).reduce((n, a) => n + a.quantity, 0), 1620);
    assert.ok(loads.every(l => l.pallets <= l.unit.capacity));
});
test('goals of the same product share partial pallets while different products do not', () => {
    const same = consolidateLoads([goal('1', 'a', 20), goal('2', 'a', 30)], day, products, types);
    assert.equal(same[0].pallets, 1);
    const different = consolidateLoads([goal('1', 'a', 20), goal('2', 'b', 30)], day, products, types);
    assert.equal(different[0].pallets, 2);
});
test('existing bookings and other days are excluded from new suggestions', () => {
    const loads = consolidateLoads([goal('1', 'a', 600)], day, products, types, { '1': 300 });
    assert.equal(loads[0].allocations[0].quantity, 300);
    assert.deepEqual(consolidateLoads([goal('1', 'a', 600)], '2026-11-13', products, types), []);
});
test('unknown pallet capacity fails explicitly instead of silently assuming a conversion', () => {
    assert.throws(() => consolidateLoads([goal('1', 'missing', 600)], day, products, types), /Configura/);
});
test('large single-product goals split over several units including an exact-capacity load', () => {
    const loads = consolidateLoads([goal('1', 'a', 3120)], day, products, types);
    assert.equal(loads.length, 2);
    assert.deepEqual(loads.map(l => l.pallets), [26, 26]);
});

test('different projects cannot be placed in the same unit', () => {
    assert.throws(() => consolidateLoads([goal('1', 'a', 300), { ...goal('2', 'b', 200), proyectoId: 'other' }], day, products, types), /mismo proyecto/);
});

test('three plus two pallets upgrade from a pickup to one Thermo 43 for both products', () => {
    const fleet = [
        { id: 'pickup', name: 'Camioneta 3.5 Ton', capacity: 3 },
        { id: 'thermo43', name: 'Thermo 43 pies', capacity: 20 },
        { id: 'thermo48', name: 'Thermo 48 pies', capacity: 22 },
        { id: 'thermo53', name: 'Thermo 53 pies', capacity: 26 }
    ];
    const loads = consolidateLoads([goal('1', 'a', 180), goal('2', 'b', 80)], day, products, fleet);
    assert.equal(loads.length, 1);
    assert.equal(loads[0].unit.id, 'thermo43');
    assert.equal(loads[0].pallets, 5);
    assert.deepEqual(loads[0].allocations.map(a => a.projectionId), ['1', '2']);
});
