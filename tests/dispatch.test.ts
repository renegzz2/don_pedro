import test from 'node:test';
import assert from 'node:assert/strict';
import {canManageUsaDispatch,isActiveUsaDispatch,dispatchFollowupPatch,trafficViews,dispatchNextStop,dispatchIncidents,dispatchTargetIds} from '../utils/dispatch';
import {UserRole,View,type UsaShipmentReport} from '../types';
test('traffic can monitor USA operations and active trips do not disappear at a year boundary',()=>{
    assert.ok(trafficViews.includes(View.USA_SHIPMENTS)); assert.ok(trafficViews.includes(View.TIVE_MAP));
    assert.equal(canManageUsaDispatch(UserRole.TRAFICO_RI),true);
    assert.equal(canManageUsaDispatch(UserRole.COMPRAS),false);
    assert.equal(isActiveUsaDispatch('En ruta'),true);
    assert.equal(isActiveUsaDispatch(' Finalizado '),false);
    assert.equal(isActiveUsaDispatch('CANCELADO'),false);
});
test('navigation advances past real pickups and confirmed deliveries without claiming GPS coordinates',()=>{
    const report={routePlan:{stops:[{id:'supplier'},{id:'a'},{id:'client1',completedAt:'actual'},{id:'b'},{id:'client2'}]},sourceManifest:[{pickupStopId:'a'}]} as UsaShipmentReport;
    assert.equal(dispatchNextStop(report)?.id,'b');
    report.sourceManifest=[{pickupStopId:'a'},{pickupStopId:'b'}] as any;
    assert.equal(dispatchNextStop(report)?.id,'client2');
});
test('follow-up edits cannot overwrite cargo, equipment, departure or original temperature',()=>{
    assert.deepEqual(dispatchFollowupPatch({comments:'Ubicación confirmada',tiveTrackerId:null,idealTemp:0,products:[],realDepartureDate:'otro',tractorPlates:'otra',driverPhone:'555'}),
        {comments:'Ubicación confirmada',tiveTrackerId:null,driverPhone:'555'});
});
test('text-backed incident history remains available after refreshing the dispatch',()=>{
    const history=[{type:'Demora',description:'Inspección',timestamp:'2026-11-18T12:00',location:'Cruce'}];
    assert.deepEqual(dispatchIncidents(JSON.stringify(history)),history);
    assert.deepEqual(dispatchIncidents(history),history); assert.deepEqual(dispatchIncidents('inválido'),[]);
});
test('GPS estimates target the next pickup or client, preserving ambiguity instead of choosing a random customer',()=>{
    const report={routePlan:{stops:[{id:'a'},{id:'b'},{id:'c'}],cargo:[{loadStopId:'b',projectId:'project-b',unloadStopId:'c',clientId:'client-c'}]},sourceManifest:[{pickupStopId:'a'}]} as UsaShipmentReport;
    assert.equal(dispatchTargetIds(report).projectId,'project-b');
    report.sourceManifest=[{pickupStopId:'b'}] as any;
    assert.equal(dispatchTargetIds(report).clientId,'client-c');
    report.routePlan!.cargo.push({unloadStopId:'c',clientId:'another'} as any);
    assert.equal(dispatchTargetIds(report).clientId,undefined);
});
