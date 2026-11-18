import test from 'node:test';
import assert from 'node:assert/strict';
import { metricBoxes, type BoxMetric } from '../utils/planningMetrics';
import type { StrategicProjection } from '../types';
const goal={id:'goal1',proyectoId:'p',productoId:'prod'}as StrategicProjection;
const fact=(concepto:string,cajas:number,client_id:string|null=null,projection_id:string|null=null)=>({proyecto_id:'p',producto_id:'prod',client_id,projection_id,anio:2025,concepto,cajas})as BoxMetric;
test('client history uses the selected client, preserving an explicit zero versus missing history',()=>{const rows=[fact('cliente_recibido',125,'sweet'),fact('cliente_recibido',0,'other')];assert.equal(metricBoxes(rows,goal,'cliente_recibido','sweet'),125);assert.equal(metricBoxes(rows,goal,'cliente_recibido','other'),0);assert.equal(metricBoxes(rows,goal,'cliente_recibido','missing'),null);});
test('annual shipments sum across clients while actual shipped boxes belong only to their goal',()=>{const rows=[fact('enviado_anual',50,'sweet'),fact('enviado_anual',80,'other'),fact('real_meta',35,'sweet','goal1'),fact('real_meta',70,'other','goal2')];assert.equal(metricBoxes(rows,goal,'enviado_anual'),130);assert.equal(metricBoxes(rows,goal,'real_meta'),35);assert.equal(metricBoxes(rows,{...goal,id:'goal2'},'real_meta'),70);});
test('weekly comparison uses shipments for the selected client, never annual references or receipts',()=>{
    const rows=[fact('ng_semana',130),fact('cliente_enviado_semana',100,'sweet'),fact('cliente_enviado_semana',30,'other'),fact('ng_enviado',9000),fact('cliente_recibido',7777,'sweet')];
    assert.equal(metricBoxes(rows,goal,'ng_semana'),130);
    assert.equal(metricBoxes(rows,goal,'cliente_enviado_semana','sweet'),100);
    assert.equal(metricBoxes(rows,goal,'cliente_enviado_semana','other'),30);
    assert.equal(metricBoxes(rows,goal,'cliente_enviado_semana','missing'),0);
    assert.equal(metricBoxes([],goal,'ng_semana'),0);
});
