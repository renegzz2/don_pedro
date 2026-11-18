import test from 'node:test';
import assert from 'node:assert/strict';
import { UserRole, View } from '../types';
import { PLANNING_SECTIONS, planningSectionAccess, initialViewForRole } from '../utils/planningAccess';
import { defaultGoalDay, planningWeekDays, requestedGoalPeriod } from '../utils/commercialPlanning';

test('each new section is restricted to its designated role and administrator',()=>{
    const designated=new Map([[View.PACKING_PLANNING,UserRole.LIDER_PROYECTO],[View.SUPPLY_COLLECTION,UserRole.COMPRAS],[View.TRANSPORT_PLANNING,UserRole.TRAFICO_RI]]);
    for(const section of PLANNING_SECTIONS)for(const role of Object.values(UserRole))assert.equal(planningSectionAccess(section.view,role),role===UserRole.ADMINISTRADOR||role===designated.get(section.view),`${role}: ${section.view}`);
    assert.equal(planningSectionAccess(View.STRATEGIC_PLANNING,UserRole.COMERCIAL),undefined);
});
test('operational roles land in their independent section',()=>{
    assert.equal(initialViewForRole(UserRole.COMPRAS),View.SUPPLY_COLLECTION);
    assert.equal(initialViewForRole(UserRole.TRAFICO_RI),View.TRANSPORT_PLANNING);
    assert.equal(initialViewForRole(UserRole.LIDER_PROYECTO),View.PACKING_PLANNING);
});
test('new goals accept today, later weeks and the next ISO year, but not yesterday',()=>{
    assert.deepEqual(requestedGoalPeriod('2026-11-17','2026-11-17'),{year:2026,week:47});
    assert.deepEqual(requestedGoalPeriod('2026-12-01','2026-11-17'),{year:2026,week:49});
    assert.deepEqual(requestedGoalPeriod('2027-01-04','2026-11-17'),{year:2027,week:1});
    assert.throws(()=>requestedGoalPeriod('2026-11-16','2026-11-17'),/pasados/);
    assert.throws(()=>requestedGoalPeriod('2026-02-30','2026-11-17'),/válida/);
});
test('editing an existing historical goal does not silently create a new past date',()=>{
    assert.deepEqual(requestedGoalPeriod('2026-11-13','2026-11-17','2026-11-13'),{year:2026,week:46});
    assert.throws(()=>requestedGoalPeriod('2026-11-12','2026-11-17','2026-11-13'),/pasados/);
});
test('new goal defaults preserve a selected future week and dates cross year boundaries correctly',()=>{
    assert.equal(defaultGoalDay(2026,49,'2026-11-17'),'2026-11-30');
    assert.equal(defaultGoalDay(2026,47,'2026-11-17'),'2026-11-17');
    assert.equal(defaultGoalDay(2026,46,'2026-11-17'),'2026-11-17');
    assert.equal(planningWeekDays(2026,1)[2].dateString,'2025-12-29');
    assert.equal(planningWeekDays(2027,1)[2].dateString,'2027-01-04');
});
