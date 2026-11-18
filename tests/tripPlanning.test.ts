import test from 'node:test';
import assert from 'node:assert/strict';
import type { ProductoDB, StrategicProjection } from '../types';
import type { TripPlan, TransportSpec } from '../transportTypes';
import { evaluateTrip, initialTrip, suggestTrips, thermalRange, balanceTrip, KG_TO_LB } from '../utils/tripPlanning';
const day='2026-11-13';
const products=[{id:'a',nombreDelProducto:'Serrano',cajasPalletUsa:50,pesoUsa:10,pesoIncluyeEmpaque:true,limiteTolerable:'45',limiteSuperior:55,almacenadoFrio:true},{id:'b',nombreDelProducto:'Sandia',cajasPalletUsa:50,pesoUsa:20,pesoIncluyeEmpaque:true,limiteTolerable:'50',limiteSuperior:61,almacenadoFrio:true}] as ProductoDB[];
const unit:TransportSpec={id:'thermo',name:'Thermo',capacity:26,payloadLb:40000,grossLb:80000,refrigerated:true,minF:32,maxF:65,palletTareKg:20};
const goal=(id:string,product:string,boxes:number,client='client-a')=>({id,proyectoId:'project',productoId:product,clientId:client,proyeccionCajas:boxes,packingPlan:[{fecha:day,cantidad:boxes}]})as StrategicProjection;
const plan=(goals=[goal('1','a',100),goal('2','b',150,'client-b')])=>{const p=initialTrip(goals,day,unit);p.cargo.forEach(c=>c.description=products.find(p=>p.id===c.productId)!.nombreDelProducto);return p;};
test('different clients share one journey while retaining separate pallet identities',()=>{const result=evaluateTrip(plan(),products);assert.equal(result.errors.length,0);assert.equal(result.segments[0].pallets.length,5);assert.deepEqual(new Set(result.pallets.map(p=>p.clientId)),new Set(['client-a','client-b']));});
test('upper temperature is excluded and a common interval is required for the entire load',()=>{assert.throws(()=>thermalRange([{minF:45,maxF:50},{minF:50,maxF:55}]),/No existe/);assert.throws(()=>thermalRange([{minF:30,maxF:40},{minF:35,maxF:50},{minF:45,maxF:55}]),/No existe/);assert.equal(thermalRange([{minF:45,maxF:55},{minF:50,maxF:61}])?.suggested,52.5);});
test('suggestions upgrade one combined load to the smallest equipment satisfying pallet and weight limits',()=>{const units=[{...unit,id:'pickup',name:'Camioneta',capacity:4,payloadLb:9000},{...unit,id:'thermo43',name:'Thermo43',capacity:20}];const result=suggestTrips([goal('1','a',150),goal('2','b',100)],day,products,units);assert.equal(result.issues.length,0);assert.equal(result.suggestions.length,1);assert.equal(result.suggestions[0].unitTypeId,'thermo43');});
test('weight can split a load even when pallet space remains',()=>{const result=suggestTrips([goal('1','b',300)],day,products,[{...unit,payloadLb:4500}]);assert.ok(result.suggestions.length>1);assert.equal(result.suggestions.flatMap(p=>p.cargo).reduce((n,c)=>n+c.boxes,0),300);assert.ok(result.suggestions.every(p=>evaluateTrip(p,products).segments.every(s=>s.weightLb<=4500)));});
test('remaining suggestions exclude the exact booked boxes',()=>{const result=suggestTrips([goal('1','a',100)],day,products,[unit],{'1':80});assert.equal(result.suggestions[0].cargo[0].boxes,20);});
test('missing weight and packaging metadata blocks confirmation, rather than assuming pounds',()=>{const result=evaluateTrip(plan(),products.map(p=>({...p,pesoIncluyeEmpaque:undefined})));assert.ok(result.errors.some(e=>e.includes('peso bruto')));});
test('supplies unload before produce, releasing the same pallet positions',()=>{const p=plan([goal('1','a',100)]);p.equipment={...unit,capacity:2};p.stops.unshift({id:'supplier',name:'Proveedor',address:'A',at:`${day}T06:00`});p.cargo.push({id:'supplies',kind:'supplies',requestId:'r',projectId:'project',description:'Cajas',boxes:0,pallets:2,weightKg:100,ambient:true,loadStopId:'supplier',unloadStopId:'p-project'});const result=evaluateTrip(p,products);assert.equal(result.errors.length,0);assert.deepEqual(result.segments.map(s=>s.pallets.length),[2,2]);assert.equal(result.segments[0].weightLb,100*KG_TO_LB);});
test('later pickups must accept the original temperature even after the initial cargo is unloaded',()=>{const p=plan([goal('1','a',100)]);p.stops.push({id:'last',name:'Cliente C',address:'C',at:day+'T22:00'});p.cargo.push({id:'custom',kind:'special',projectId:'project',clientId:'c',description:'Producto especial',boxes:0,pallets:1,weightKg:200,minF:60,maxF:65,loadStopId:'c-client-a',unloadStopId:'last'});const result=evaluateTrip(p,products);assert.equal(result.departure.value,50);assert.ok(result.errors.some(e=>e.includes('temperatura de salida')));});

test('future collections reserve positions and overlapping manual positions are rejected',()=>{const p=plan();p.cargo[0].positions=[0,1];p.cargo[1].positions=[0,2,3];assert.ok(evaluateTrip(p,products).errors.some(e=>e.includes('superpuestos')));});
test('axle estimates account for tare, moment arms and do not simply halve cargo weight',()=>{const p=plan([goal('1','a',100)]);p.equipment={...unit,lengthM:16,kingpinM:1,trailerAxleM:13,fifthWheelM:4,tractorWheelbaseM:4.5,emptyAxlesLb:[10000,10000,10000],axleLimitsLb:[12000,34000,34000]};const result=evaluateTrip(p,products);const s=result.segments[0];assert.equal(result.errors.length,0);assert.ok(s.axles);assert.ok(Math.abs(s.axles!.reduce((n,v)=>n+v,0)-(30000+s.weightLb))<0.001);assert.notEqual(s.axles![1],s.axles![2]);p.equipment.axleLimitsLb=[10000,10000,10000];assert.ok(evaluateTrip(p,products).errors.some(e=>e.includes('grupo de ejes')));});
test('automatic balancing moves heavy pallets until every axle group fits',()=>{
    const p=plan([goal('1','a',100)]);const heavy=products.map(product=>({...product,pesoUsa:30}));
    p.equipment={...unit,capacity:8,lengthM:16,kingpinM:1,trailerAxleM:13,fifthWheelM:4,tractorWheelbaseM:4.5,emptyAxlesLb:[10000,10000,10000],axleLimitsLb:[10500,34000,34000]};
    assert.ok(evaluateTrip(p,heavy).errors.some(e=>e.includes('ejes')));
    const balanced=balanceTrip(p,heavy);assert.equal(evaluateTrip(balanced,heavy).errors.length,0);
});
test('intermediate cargo cannot force a new setpoint just because the thermal intervals overlap',()=>{
    const p=plan([goal('1','a',100)]);p.stops.splice(1,0,{id:'pickup-b',name:'Punto B',address:'B',at:day+'T10:00'});
    p.cargo.push({id:'later',kind:'special',projectId:'project',clientId:'client-a',description:'Carga B',boxes:0,pallets:1,weightKg:100,minF:51,maxF:54,loadStopId:'pickup-b',unloadStopId:'c-client-a'});
    const result=evaluateTrip(p,products);assert.equal(result.departure.value,50);assert.ok(result.errors.some(e=>e.includes('temperatura de salida')));
    p.temperatureF=52;assert.equal(evaluateTrip(p,products).errors.length,0);
    p.temperatureF=54;assert.ok(evaluateTrip(p,products).errors.some(e=>e.includes('temperatura de salida')));
});
test('temperature remains constant across stops and pre-packing supplies do not define it',()=>{
    const p=plan([goal('1','a',100)]);p.temperatureF=50;
    p.stops.unshift({id:'sup',name:'Proveedor',address:'S',at:day+'T06:00'});
    p.cargo.push({id:'supplies',kind:'supplies',requestId:'r',projectId:'project',description:'Cajas',boxes:0,pallets:1,weightKg:50,ambient:true,loadStopId:'sup',unloadStopId:'p-project'});
    const result=evaluateTrip(p,products);assert.equal(result.departure.originStopId,'p-project');assert.equal(result.departure.value,50);
    assert.ok(result.segments.filter(s=>s.temperature).every(s=>s.temperature!.suggested===50));
});
test('an invalid initial temperature reports the entered value and allows correction within the initial range',()=>{
    const p=plan();p.temperatureF=45;
    const invalid=evaluateTrip(p,products);
    assert.equal(invalid.departure.value,45);
    assert.ok(invalid.errors.some(e=>e.includes('50 ≤ T < 55')));
    assert.ok(!invalid.errors.some(e=>e.includes('sin confirmar')));
    p.temperatureF=52.5;
    assert.equal(evaluateTrip(p,products).errors.length,0);
});
