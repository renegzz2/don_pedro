import test from 'node:test';
import assert from 'node:assert/strict';
import { shipmentLoads, shipmentTransport, resolveShipmentSchedule } from '../utils/shipmentPlanning';
import type { FreightSchedule } from '../types';
import type { TripPlan } from '../transportTypes';

const rows = [
    {id:'s1',loadId:'trip',projectionId:'g1',scheduledDate:'2026-11-18',carrierId:'carrier',quantity:600,proyeccion:{productoId:'serrano',clientId:'sweet'}},
    {id:'s2',loadId:'trip',projectionId:'g2',scheduledDate:'2026-11-18',carrierId:'carrier',quantity:35,proyeccion:{productoId:'shishito',clientId:'other'}},
    {id:'s3',loadId:'trip',projectionId:'g3',scheduledDate:'2026-11-18',carrierId:'carrier',quantity:50,proyeccion:{productoId:'serrano',clientId:'sweet'}},
] as FreightSchedule[];
const trip = {id:'trip',equipment:{name:'Thermo 53 pies'},tractorPlates:'TRACTOR',trailerPlates:'CAJA',temperatureF:50,economicNumber:'123',thermograph:'T1',continuous:false,
    cargo:[{projectionId:'g1',loadStopId:'a'},{projectionId:'g2',loadStopId:'a'},{projectionId:'g3',loadStopId:'b'}]} as TripPlan;
test('a unit includes all its products and clients, and keeps intermediate pickups separate',()=>{
    const loads=shipmentLoads(rows,[trip],'2026-11-18','sweet');
    assert.equal(loads.length,2);
    assert.deepEqual(loads[0].schedules.map(s=>s.id),['s1','s2']);
    assert.equal(loads[1].stopId,'b');
    assert.equal(shipmentLoads(rows,[trip],'2026-11-19','sweet').length,0);
});
test('legacy consolidated loads group by load ID while unrelated standalone freights stay separate',()=>{
    const loads=shipmentLoads([...rows,{...rows[0],id:'legacy',loadId:undefined}],[],'2026-11-18','sweet');
    assert.equal(loads.length,2); assert.equal(loads[0].schedules.length,3); assert.equal(loads[1].schedules.length,1);
});
test('planning prefill preserves zero degrees and explicit non-continuous mode, leaves unknown values blank',()=>{
    const fields=shipmentTransport({...trip,temperatureF:0});
    assert.equal(fields.temperature,0); assert.equal(fields.continuous,'No'); assert.equal(fields.feet,'53');
    assert.equal(fields.tractor,'TRACTOR'); assert.equal(fields.economic,'123'); assert.equal(fields.thermograph,'T1');
    assert.equal(shipmentTransport().temperature,''); assert.equal(shipmentTransport().continuous,'');
});
test('identical products for different goals require explicit attribution',()=>{
    assert.equal(resolveShipmentSchedule(rows,'serrano'),undefined);
    assert.equal(resolveShipmentSchedule(rows,'serrano','s3')?.id,'s3');
    assert.equal(resolveShipmentSchedule(rows,'shishito')?.id,'s2');
    assert.equal(resolveShipmentSchedule(rows,'shishito','s1'),undefined);
});
