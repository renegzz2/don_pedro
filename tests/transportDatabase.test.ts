import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';
import type { TripPlan } from '../transportTypes';
const root = new URL('../', import.meta.url);
const id = (n:number) => `00000000-0000-4000-8000-${String(n).padStart(12,'0')}`;

test('transport migrations execute in PostgreSQL and enforce reservations, roles, thermal and weight rules', async t => {
    const db=new PGlite();
    try {
        await db.exec(`create schema auth; create role authenticated; create function auth.uid() returns uuid language sql stable as $$ select '${id(999)}'::uuid $$; create function auth.jwt() returns jsonb language sql stable as $$ select jsonb_build_object('app_metadata',jsonb_build_object('role',coalesce(current_setting('test.user_role',true),'ADMINISTRADOR'))) $$;`);
        const schema=readFileSync(new URL('supabase.sql',root),'utf8');
        for(const table of ['usa_proyectos','usa_productos','usa_clientes','usa_lineas_transporte','tipo_unidad','proyecciones_estrategicas','usa_embarques','usa_embarques_detalle','usa_shipment_reports']){
            const prefix=`CREATE TABLE IF NOT EXISTS "public"."${table}" (`;const a=schema.indexOf(prefix),b=schema.indexOf('\n);',a);
            assert.ok(a>=0&&b>a,table);await db.exec(schema.slice(a,b+3));await db.exec(`alter table public.${table} add primary key(id);`);
        }
        const activation=readFileSync(new URL('supabase/activate_20261113.sql',root),'utf8');
        for(const f of ['202611130001_transport_catalog_history.sql','202611130002_multistop_trips.sql','202611130003_historical_receipts.sql','202611130004_weekly_shipment_history.sql','202611130005_fixed_departure_temperature.sql']) assert.ok(activation.includes(readFileSync(new URL(`supabase/migrations/${f}`,root),'utf8').replace(/^begin;\s*/,'').replace(/\s*commit;\s*$/,'')),f+' activation is current');
        for(const file of ['202611110001_commercial_freight_workflow.sql','202611120001_packing_consolidated_transport.sql','../activate_20261113.sql']){
            try { await db.exec(readFileSync(new URL(`supabase/migrations/${file}`,root),'utf8')); }
            catch(e:any){throw new Error(`${file}: ${e.message}`);}
        }
        await db.exec(`insert into usa_proyectos(id,nombre) values('${id(1)}','Arturo'),('${id(2)}','Intermedio');insert into usa_clientes(id,nombre) values('${id(3)}','Sweet Seasons'),('${id(4)}','Cliente B');insert into usa_lineas_transporte(id,nombre) values('${id(5)}','Transportista');
            insert into tipo_unidad(id,unidad,capacidad,carga_util_lb,peso_bruto_max_lb,refrigerada,temperatura_min_f,temperatura_max_f,tara_pallet_kg,limites_ejes_lb) values(1,'Thermo','26 pallets',40000,80000,true,32,65,20,'[12000,34000,34000]');
            insert into usa_productos(id,nombre_del_producto,cajas_pallet_usa,peso_usa,peso_incluye_empaque,limite_tolerable,limite_superior) values('${id(6)}','Serrano',50,10,true,'45',55),('${id(7)}','Melon',50,10,true,'50',61);
            insert into proyecciones_estrategicas(id,proyecto_id,producto_id,client_id,semana_fiscal,planning_year,proyeccion_cajas) values('${id(8)}','${id(1)}','${id(6)}','${id(3)}',46,2026,200),('${id(9)}','${id(2)}','${id(7)}','${id(4)}',46,2026,200);
            update proyecciones_estrategicas set packing_plan='[{"fecha":"2026-11-13","cantidad":200}]';`);
        const plan:TripPlan={id:'',revision:0,scheduledDate:'2026-11-13',unitTypeId:'1',carrierId:id(5),arrivalAt:'2026-11-13T07:00:00-06:00',notes:'',equipment:{id:'1',name:'Thermo',capacity:26,payloadLb:40000,grossLb:80000,refrigerated:true,minF:32,maxF:65,palletTareKg:20},stops:[{id:'a',name:'Arturo',address:'A',at:'2026-11-13T08:00:00-06:00'},{id:'b',name:'Intermedio',address:'B',at:'2026-11-13T10:00:00-06:00'},{id:'c',name:'Sweet',address:'C',at:'2026-11-13T18:00:00-06:00'},{id:'d',name:'Cliente B',address:'D',at:'2026-11-13T20:00:00-06:00'}],cargo:[{id:'cargo-a',kind:'product',projectionId:id(8),projectId:id(1),productId:id(6),clientId:id(3),description:'Serrano',boxes:100,positions:[0,1],loadStopId:'a',unloadStopId:'c'},{id:'cargo-b',kind:'product',projectionId:id(9),projectId:id(2),productId:id(7),clientId:id(4),description:'Melon',boxes:50,positions:[2],loadStopId:'b',unloadStopId:'d'}]};
        const save=async(p:TripPlan,revision=0)=>(await db.query<{save_transport_trip:string}>('select save_transport_trip($1::jsonb,$2)',[JSON.stringify(p),revision])).rows[0].save_transport_trip;
        let tripId='';
        await t.test('reserves one physical journey and persists the initial pickup temperature',async()=>{tripId=await save(plan);const rows=await db.query('select load_id,quantity from usa_programacion_fletes');assert.equal(rows.rows.length,2);assert.ok(rows.rows.every((r:any)=>r.load_id===tripId));const saved=(await db.query<{plan:TripPlan}>('select plan from usa_viajes_planeados where id=$1',[tripId])).rows[0].plan;assert.equal(saved.temperatureF,50);assert.equal(saved.temperatureOriginStopId,'a');});
        await t.test('rejects stale changes and concurrent overbooking',async()=>{await assert.rejects(()=>save({...plan,id:tripId},0),/Otro usuario/);await assert.rejects(()=>save({...plan,cargo:[{...plan.cargo[0],boxes:150,positions:[0,1,2]}]}),/pendientes/);});
        await t.test('allows editing quantities and leaves the exact remainder available',async()=>{await save({...plan,id:tripId,cargo:[{...plan.cargo[0],boxes:50,positions:[0]},plan.cargo[1]]},1);const rows=await db.query<{quantity:number}>('select quantity from usa_programacion_fletes where projection_id=$1',[id(8)]);assert.equal(rows.rows[0].quantity,50);});
        await t.test('a not-yet-loaded journey can correct its initial temperature after catalog changes',async()=>{
            await db.exec('begin;');
            try {
                await db.query('update usa_productos set limite_tolerable=$1 where id=$2',['50.5',id(6)]);
                await save({...plan,id:tripId,temperatureF:52},2);
                const saved=(await db.query<{plan:TripPlan}>('select plan from usa_viajes_planeados where id=$1',[tripId])).rows[0].plan;
                assert.equal(saved.temperatureF,52);
            } finally { await db.exec('rollback;'); }
        });
        await t.test('rejects overlapping positions, incompatible temperature, excessive weight and forged capacities',async()=>{
            await assert.rejects(()=>save({...plan,id:tripId,cargo:[plan.cargo[0],{...plan.cargo[1],positions:[1]}]},2),/misma posición/);
            await db.exec(`update usa_productos set limite_tolerable='55' where id='${id(7)}'`);
            await assert.rejects(()=>save({...plan,id:tripId},2),/temperatura/);await db.exec(`update usa_productos set limite_tolerable='50' where id='${id(7)}'`);
            await db.exec(`update usa_productos set limite_tolerable='51',limite_superior=54 where id='${id(7)}'`);
            await assert.rejects(()=>save({...plan,id:tripId},2),/temperatura de salida/);
            await db.exec(`update usa_productos set limite_tolerable='50',limite_superior=61 where id='${id(7)}'`);
            await db.exec(`update usa_productos set peso_usa=1000 where id='${id(6)}'`);await assert.rejects(()=>save({...plan,id:tripId},2),/peso útil/);await db.exec(`update usa_productos set peso_usa=10 where id='${id(6)}'`);
            await assert.rejects(()=>save({...plan,id:tripId,equipment:{...plan.equipment,payloadLb:999999}},2),/capacidades/);
        });
        await t.test('rejects purchasing role reservations',async()=>{await db.exec("set test.user_role='COMPRAS'");await assert.rejects(()=>save({...plan,id:tripId},2),/Tu rol/);await db.exec("set test.user_role='ADMINISTRADOR'");});
        await t.test('cancellation atomically frees all allocations and writes an audit record',async()=>{await db.query('select cancel_transport_trip($1,2)',[tripId]);assert.equal((await db.query('select * from usa_programacion_fletes')).rows.length,0);assert.equal((await db.query('select * from usa_viajes_auditoria')).rows.length,3);});
        await t.test('actual shipments, receipts and immutable started journeys',async()=>{
            await db.exec(`update proyecciones_estrategicas set planning_year=2025,packing_plan='[{"fecha":"2025-11-13","cantidad":200}]';`);
            const past=structuredClone(plan);past.scheduledDate='2025-11-13';past.arrivalAt='2025-11-13T07:00:00-06:00';past.stops=past.stops.map(s=>({...s,at:s.at.replace('2026-','2025-')}));past.tractorPlates='TRACTOR';past.trailerPlates='CAJA';
            past.equipment={...past.equipment,lengthM:16,kingpinM:1,trailerAxleM:13,fifthWheelM:4,tractorWheelbaseM:4.5,emptyAxlesLb:[10000,10000,10000],axleLimitsLb:[12000,34000,34000]};
            const journey=await save(past);
            const confirm=(stop:string,rev:number,weights:number[]|null=[10000,12000,10000],received:Record<string,number>={})=>db.query('select confirm_transport_stop($1,$2,$3,$4::jsonb,$5,$6::jsonb)',[journey,rev,stop,JSON.stringify(weights),'Ticket / recepción',JSON.stringify(received)]);
            await assert.rejects(()=>confirm('b',1),/orden/);
            await assert.rejects(()=>confirm('a',1),/Embarques/);
            const rows=await db.query<{id:string,projection_id:string}>('select id,projection_id from usa_programacion_fletes where load_id=$1',[journey]);
            for(const schedule of rows.rows){const cargo=past.cargo.find(c=>c.projectionId===schedule.projection_id)!;await db.query('select registrar_embarque_programado($1,$2::jsonb,$3::jsonb)',[schedule.id,JSON.stringify({fecha_embarque:'2025-11-13T08:00:00'}),JSON.stringify([{producto_id:cargo.productId,cantidad_cajas:cargo.boxes}])]);}
            await assert.rejects(()=>confirm('a',1,[13000,12000,10000]),/pesaje/);
            await assert.rejects(()=>confirm('a',1,null),/pesos reales/);
            await confirm('a',1);
            const started=(await db.query<{plan:TripPlan}>('select plan from usa_viajes_planeados where id=$1',[journey])).rows[0].plan;
            await assert.rejects(()=>save({...started,cargo:[{...started.cargo[0],boxes:50,positions:[0]},started.cargo[1]]},2),/recogida/);
            await assert.rejects(()=>save({...started,temperatureF:52},2),/ya está fijada/);
            await assert.rejects(()=>save({...started,cargo:[...started.cargo,{id:'incompatible',kind:'special',projectId:id(2),clientId:id(4),description:'Carga que exige cambiar temperatura',boxes:0,pallets:1,weightKg:100,minF:51,maxF:54,positions:[3],loadStopId:'b',unloadStopId:'d'}]},2),/temperatura de salida/);
            await save({...started,cargo:[...started.cargo,{id:'later',kind:'special',projectId:id(2),clientId:id(4),description:'Recolección añadida después de A',boxes:0,pallets:1,weightKg:100,minF:50,maxF:55,positions:[3],loadStopId:'b',unloadStopId:'d'}]},2);
            const preserved=await db.query<{id:string}>('select id from usa_programacion_fletes where load_id=$1',[journey]);
            assert.deepEqual(preserved.rows.map(r=>r.id).sort(),rows.rows.map(r=>r.id).sort());
            await confirm('b',3);
            await assert.rejects(()=>confirm('c',4,[10000,12000,10000],{'cargo-a':101}),/recibidas/);
            await confirm('c',4,[10000,12000,10000],{'cargo-a':95});
            await confirm('d',5,null,{'cargo-b':50});
            const metrics=await db.query<any>('select * from planning_box_metrics(2026,46)');
            const receipts=await db.query<any>('select * from planning_box_metrics(extract(year from now())::integer+1,46)');
            assert.equal(Number(receipts.rows.find((r:any)=>r.concepto==='cliente_recibido'&&r.client_id===id(3))?.cajas),95);
            assert.equal(Number(metrics.rows.find((r:any)=>r.concepto==='ng_enviado'&&r.producto_id===id(6))?.cajas),100);
            assert.equal((await db.query('select * from usa_viajes_planeados where completed_at is not null')).rows.length,1);
            await assert.rejects(()=>db.query('select cancel_transport_trip($1,6)',[journey]),/iniciado/);
        });
        await t.test('supplies reserve once, special cargo reuses unloaded positions and cancel releases requests',async()=>{
            await db.exec(`insert into usa_solicitudes_insumos(id,project_id,supplier,address,description,pallets,weight_kg,requested_date,reference) values('${id(10)}','${id(1)}','Proveedor','Dirección','Cajas',2,100,'2025-11-13','OC-1');`);
            const supplies:TripPlan={...structuredClone(plan),scheduledDate:'2025-11-13',arrivalAt:'2025-11-13T05:00:00-06:00',stops:[{id:'supplier',name:'Proveedor',address:'A',at:'2025-11-13T06:00:00-06:00'},{id:'packing',name:'Arturo',address:'B',at:'2025-11-13T08:00:00-06:00'},{id:'delivery',name:'Cliente B',address:'C',at:'2025-11-13T18:00:00-06:00'}],cargo:[{id:'supply',kind:'supplies',requestId:id(10),projectId:id(1),description:'Cajas',boxes:0,pallets:2,weightKg:100,ambient:true,positions:[0,1],loadStopId:'supplier',unloadStopId:'packing'},{id:'special',kind:'special',projectId:id(1),clientId:id(4),description:'Carga sin catálogo',boxes:0,pallets:2,weightKg:500,minF:45,maxF:55,positions:[0,1],loadStopId:'packing',unloadStopId:'delivery'}]};
            const tid=await save(supplies);assert.equal((await db.query<any>('select status from usa_solicitudes_insumos where id=$1',[id(10)])).rows[0].status,'asignada');
            await assert.rejects(()=>save(supplies),/reservados/);
            await db.query('select cancel_transport_trip($1,1)',[tid]);assert.equal((await db.query<any>('select status from usa_solicitudes_insumos where id=$1',[id(10)])).rows[0].status,'pendiente');
        });
        await t.test('legacy attribution keeps actual quantities and dates and updates annual metrics',async()=>{
            await db.exec(`insert into usa_embarques(id,fecha_embarque,folio_embarque) values('${id(20)}','2026-11-13T08:00','LEGACY');insert into usa_embarques_detalle(id,embarque_id,producto_id,cantidad_cajas) values('${id(21)}','${id(20)}','${id(6)}',35);`);
            const before=await db.query<any>('select * from planning_box_metrics(2026,46)');
            assert.equal(Number(before.rows.find((r:any)=>r.concepto==='sin_atribuir')?.cajas),35);
            await db.query('select attribute_legacy_shipment($1,$2,$3,null,$4)',[id(21),id(1),id(3),'Remisión original']);
            const after=await db.query<any>('select * from planning_box_metrics(2026,46)');
            assert.equal(Number(after.rows.find((r:any)=>r.concepto==='enviado_anual'&&r.proyecto_id===id(1))?.cajas),35);
            await assert.rejects(()=>db.query('select attribute_legacy_shipment($1,$2,$3,null,$4)',[id(21),id(2),id(4),'Cambio']),/conciliado/);
        });
        await t.test('weekly history respects selected ISO year/week, client, project and actual departure instead of receipts',async()=>{
            await db.exec(readFileSync(new URL('supabase/migrations/202611130004_weekly_shipment_history.sql',root),'utf8'));
            const shipment=async(n:number,date:string,qty:number,project=id(1),client=id(3),status='CONFIRMADO')=>{
                await db.query('insert into usa_embarques(id,fecha_embarque,estatus_embarque) values($1,$2,$3)',[id(n),date,status]);
                await db.query('insert into usa_embarques_detalle(id,embarque_id,producto_id,cantidad_cajas,proyecto_id,client_id) values($1,$2,$3,$4,$5,$6)',[id(n+100),id(n),id(6),qty,project,client]);
            };
            await shipment(30,'2025-11-13',30,id(1),id(4));
            await shipment(31,'2025-11-06',9000);
            await shipment(32,'2024-11-14',7000);
            await shipment(33,'2025-11-13',500,id(2));
            await shipment(34,'2025-11-13',3000,id(1),id(3),' Cancelado ');
            await shipment(35,'2024-12-30',11);
            await shipment(36,'2025-01-01',12);
            await shipment(37,'2025-12-29',4);
            await db.query("insert into usa_historico_cajas(proyecto_id,producto_id,anio,concepto,cajas,referencia) values($1,$2,2025,'ng_enviado',99999,'Referencia anual')",[id(1),id(6)]);
            const query=async(year:number,week:number)=>(await db.query<any>('select * from planning_weekly_history($1,$2)',[year,week])).rows;
            const ng=(rows:any[])=>Number(rows.find(r=>r.concepto==='ng_semana'&&r.proyecto_id===id(1)&&r.producto_id===id(6))?.cajas||0);
            const weekly=await query(2025,46);
            assert.equal(ng(weekly),130);
            assert.equal(Number(weekly.find(r=>r.concepto==='cliente_enviado_semana'&&r.proyecto_id===id(1)&&r.producto_id===id(6)&&r.client_id===id(3))?.cajas),100);
            assert.equal(Number(weekly.find(r=>r.concepto==='cliente_enviado_semana'&&r.proyecto_id===id(1)&&r.producto_id===id(6)&&r.client_id===id(4))?.cajas),30);
            assert.equal(ng(await query(2025,45)),9000);
            assert.equal(ng(await query(2024,46)),7000);
            assert.equal(ng(await query(2026,46)),35);
            assert.equal(ng(await query(2025,1)),23);
            assert.equal(ng(await query(2025,53)),0);
            assert.equal(ng(await query(2026,1)),4);
            await assert.rejects(()=>query(2025,0),/válidos/);
        });
        await t.test('independent sections enforce their write roles and future goals reject past dates',async()=>{
            await db.exec("create type public.user_role as enum('Administrativo');");
            await db.exec(readFileSync(new URL('supabase/migrations/202611170001_planning_sections_future_goals.sql',root),'utf8'));
            await db.exec(readFileSync(new URL('supabase/migrations/202611170001_planning_sections_future_goals.sql',root),'utf8'));
            assert.equal((await db.query("select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid where t.typname='user_role' and e.enumlabel='TRAFICO_RI'")).rows.length,1);
            const dates=(await db.query<{future:string,today:string,past:string}>('select ((now() at time zone \'America/Mexico_City\')::date+21)::text as future,((now() at time zone \'America/Mexico_City\')::date)::text as today,((now() at time zone \'America/Mexico_City\')::date-1)::text as past')).rows[0];
            const create=async(goalId:string,day:string,weekOffset=0)=>db.query(`insert into proyecciones_estrategicas(id,proyecto_id,producto_id,client_id,planning_year,semana_fiscal,proyeccion_cajas,fecha_salida,desglose_diario) values($1,$2,$3,$4,extract(isoyear from $5::date)::integer,extract(week from $5::date)::integer+$6,200,$5::date+time '08:00',jsonb_build_array(jsonb_build_object('fecha',$5::text,'cantidad',200)))`,[goalId,id(1),id(6),id(3),day,weekOffset]);
            await db.exec("set test.user_role='COMERCIAL';");
            await create(id(200),dates.future);await create(id(201),dates.today);
            await assert.rejects(()=>create(id(202),dates.past),/pasados/);
            await assert.rejects(()=>create(id(202),dates.future,1),/semana/);
            await assert.rejects(()=>db.query('update proyecciones_estrategicas set fecha_salida=$1::date where id=$2',[dates.past,id(200)]),/pasados/);
            await assert.rejects(()=>db.query('update proyecciones_estrategicas set fecha_salida=null where id=$1',[id(200)]),/fecha de carga/);
            const nextYear=(await db.query<{day:string}>("select make_date(extract(year from now())::integer+1,1,10)::text as day")).rows[0].day;
            await create(id(202),nextYear);
            const pack=[{fecha:dates.future,cantidad:200}];
            await db.exec("set test.user_role='DIRECCION';");await assert.rejects(()=>db.query('select save_packing_plan($1,$2::jsonb,$3::jsonb)',[id(200),JSON.stringify(pack),'[]']),/Tu rol/);
            await assert.rejects(()=>db.query('update proyecciones_estrategicas set packing_plan=$1::jsonb where id=$2',[JSON.stringify(pack),id(200)]),/Solo el líder/);
            await db.exec("set test.user_role='LIDER_PROYECTO';");await db.query('select save_packing_plan($1,$2::jsonb,$3::jsonb)',[id(200),JSON.stringify(pack),'[]']);
            const route:TripPlan={...structuredClone(plan),scheduledDate:dates.future,arrivalAt:dates.future+'T07:00',stops:[{id:'a',name:'Arturo',address:'A',at:dates.future+'T08:00'},{id:'c',name:'Sweet',address:'B',at:dates.future+'T18:00'}],cargo:[{...plan.cargo[0],projectionId:id(200),boxes:50,positions:[0]}]};
            await assert.rejects(()=>save(route),/Tu rol/);
            await db.exec("set test.user_role='GERENCIA';");await assert.rejects(()=>save(route),/Tu rol/);
            await db.exec("set test.user_role='TRAFICO_RI';");
            const trafficTrip=await save(route);assert.ok(trafficTrip);
            await assert.rejects(()=>db.query('select save_packing_plan($1,$2::jsonb,$2::jsonb)',[id(200),JSON.stringify(pack)]),/Tu rol/);
            await assert.rejects(()=>create(id(203),dates.future),/Tu rol/);
            await db.query('select cancel_transport_trip($1,1)',[trafficTrip]);
            await db.exec('grant usage on schema auth to authenticated;set role authenticated;');
            const request=async(n:number)=>db.query('insert into usa_solicitudes_insumos(id,project_id,supplier,address,description,pallets,weight_kg,requested_date,reference) values($1,$2,$3,$4,$5,1,100,$6,$7)',[id(n),id(1),'Proveedor','Dirección','Cajas',dates.future,'OC']);
            await db.exec("set test.user_role='DIRECCION';");await assert.rejects(()=>request(300),/row-level security/);
            await db.exec("set test.user_role='TRAFICO_RI';");await assert.rejects(()=>request(300),/row-level security/);
            await db.exec("set test.user_role='COMPRAS';");await request(300);
            await db.exec('reset role;');
            await db.exec("set test.user_role='ADMINISTRADOR';");
        });
        await t.test('one shipment stores multiple products and clients with atomic allocation limits and pickup confirmation',async()=>{
            const migration=readFileSync(new URL('supabase/migrations/202611170002_consolidated_shipments.sql',root),'utf8');
            await db.exec(migration); await db.exec(migration);
            const day=(await db.query<{day:string}>("select (now() at time zone 'America/Mexico_City')::date::text as day")).rows[0].day;
            await db.query(`insert into proyecciones_estrategicas(id,proyecto_id,producto_id,client_id,planning_year,semana_fiscal,proyeccion_cajas,fecha_salida)
                values($1,$2,$3,$4,extract(isoyear from $5::date)::integer,extract(week from $5::date)::integer,200,$5::date)`,[id(402),id(1),id(7),id(4),day]);
            for(const goal of [id(201),id(402)]) await db.query('select save_packing_plan($1,$2::jsonb,$3::jsonb)',[goal,JSON.stringify([{fecha:day,cantidad:200}]),'[]']);
            const route:TripPlan={...structuredClone(plan),temperatureF:50,scheduledDate:day,arrivalAt:day+'T00:00',tractorPlates:'TRACTOR',trailerPlates:'CAJA',economicNumber:'E-1',trailerFeet:'53',thermograph:'TG',continuous:true,
                equipment:{...plan.equipment,lengthM:16,kingpinM:1,trailerAxleM:13,fifthWheelM:4,tractorWheelbaseM:4.5,emptyAxlesLb:[10000,10000,10000],axleLimitsLb:[12000,34000,34000]},
                stops:[{id:'a',name:'Arturo',address:'A',at:day+'T00:00'},{id:'c',name:'Clientes',address:'C',at:day+'T23:00'}],
                cargo:[{...plan.cargo[0],projectionId:id(201),boxes:100},{...plan.cargo[1],projectionId:id(402),projectId:id(1),boxes:50,loadStopId:'a',unloadStopId:'c'}]};
            const journey=await save(route);
            const allocations=(await db.query<{id:string,projection_id:string}>('select id,projection_id from usa_programacion_fletes where load_id=$1 order by projection_id',[journey])).rows;
            const details=allocations.map(s=>({schedule_id:s.id,producto_id:s.projection_id===id(201)?id(6):id(7),cantidad_cajas:s.projection_id===id(201)?100:50}));
            const header={fecha_embarque:day+'T00:00',temperatura_viaje:50};
            const register=(items=details,ids=allocations.map(s=>s.id),head=header)=>db.query<{registrar_embarque_consolidado:string}>('select registrar_embarque_consolidado($1,$2,$3,$4::jsonb,$5::jsonb)',[journey,'a',ids,JSON.stringify(head),JSON.stringify(items)]);
            const count=Number((await db.query<{n:string}>('select count(*) as n from usa_embarques')).rows[0].n);
            await assert.rejects(()=>register([{...details[0],cantidad_cajas:1},{...details[1],cantidad_cajas:999}]),/superan/);
            assert.equal(Number((await db.query<{n:string}>('select count(*) as n from usa_embarques')).rows[0].n),count);
            await assert.rejects(()=>register(details,[allocations[0].id]),/cambió/);
            await assert.rejects(()=>register([{...details[0],producto_id:id(7)},details[1]]),/producto/);
            await assert.rejects(()=>register(details,allocations.map(s=>s.id),{...header,temperatura_viaje:51}),/temperatura/);
            await db.exec("set test.user_role='COMPRAS';"); await assert.rejects(()=>register(),/Tu rol/); await db.exec("set test.user_role='ADMINISTRADOR';");
            const shipment=(await register()).rows[0].registrar_embarque_consolidado;
            const saved=(await db.query<any>('select * from usa_embarques_detalle where embarque_id=$1',[shipment])).rows;
            assert.equal(saved.length,2); assert.deepEqual(saved.map(d=>d.client_id).sort(),[id(3),id(4)]);
            assert.deepEqual(saved.map(d=>d.proyeccion_id).sort(),[id(201),id(402)]);
            assert.equal(Number((await db.query<{n:string}>('select count(*) as n from usa_embarques')).rows[0].n),count+1);
            await assert.rejects(()=>register(),/superan/);
            await assert.rejects(()=>db.query('select registrar_embarque_programado($1,$2::jsonb,$3::jsonb)',[details[1].schedule_id,JSON.stringify(header),JSON.stringify([{producto_id:id(7),cantidad_cajas:1}])]),/superan/);
            await assert.rejects(()=>db.query('select cancel_transport_trip($1,1)',[journey]),/embarques/);
            await db.query('select confirm_transport_stop($1,1,$2,$3::jsonb,$4,$5::jsonb)',[journey,'a','[10000,12000,10000]','Ticket','{}']);
            const persisted=(await db.query<{plan:TripPlan}>('select plan from usa_viajes_planeados where id=$1',[journey])).rows[0].plan;
            assert.equal(persisted.economicNumber,'E-1'); assert.equal(persisted.thermograph,'TG'); assert.equal(persisted.continuous,true);
        });
        await t.test('a real departure activates one dispatch, retries are idempotent and intermediate pickups preserve tracking',async()=>{
            const migration=readFileSync(new URL('supabase/migrations/202611170003_active_dispatch_from_shipments.sql',root),'utf8');
            await db.exec(migration); await db.exec(migration);
            assert.equal((await db.query('select * from usa_shipment_reports')).rows.length,0,'Historical departures are not silently reactivated');
            await db.exec('update usa_embarques set estatus_embarque=estatus_embarque;');
            assert.equal((await db.query('select * from usa_shipment_reports')).rows.length,0,'Correcting historical headers does not create active trips');
            const day=(await db.query<{day:string}>("select (now() at time zone 'America/Mexico_City')::date::text as day")).rows[0].day;
            for(const [goal,product,project,client] of [[501,6,1,3],[502,7,1,4],[503,6,2,4]]) {
                await db.query(`insert into proyecciones_estrategicas(id,proyecto_id,producto_id,client_id,planning_year,semana_fiscal,proyeccion_cajas,fecha_salida)
                    values($1,$2,$3,$4,extract(isoyear from $5::date)::integer,extract(week from $5::date)::integer,200,$5::date)`,[id(goal),id(project),id(product),id(client),day]);
                await db.query('select save_packing_plan($1,$2::jsonb,$3::jsonb)',[id(goal),JSON.stringify([{fecha:day,cantidad:200}]),'[]']);
            }
            const route:TripPlan={...structuredClone(plan),temperatureF:50,scheduledDate:day,arrivalAt:day+'T00:00',tractorPlates:'TR',trailerPlates:'CJ',
                equipment:{...plan.equipment,lengthM:16,kingpinM:1,trailerAxleM:13,fifthWheelM:4,tractorWheelbaseM:4.5,emptyAxlesLb:[10000,10000,10000],axleLimitsLb:[12000,34000,34000]},
                stops:[{id:'a',name:'Arturo',address:'A',at:day+'T00:00'},{id:'b',name:'Intermedio',address:'B',at:day+'T00:01'},{id:'c',name:'Clientes',address:'C',at:day+'T23:00'}],
                cargo:[{...plan.cargo[0],projectionId:id(501),boxes:100},{...plan.cargo[1],projectionId:id(502),projectId:id(1),boxes:50,loadStopId:'a',unloadStopId:'c'},
                    {...plan.cargo[0],id:'later',projectionId:id(503),projectId:id(2),clientId:id(4),boxes:50,positions:[3],loadStopId:'b'}]};
            const journey=await save(route);
            assert.equal((await db.query('select * from usa_shipment_reports')).rows.length,0,'A plan alone is not an active dispatch');
            const allocations=(await db.query<{id:string,projection_id:string}>('select id,projection_id from usa_programacion_fletes where load_id=$1 order by projection_id',[journey])).rows;
            const details=allocations.map((s,i)=>({schedule_id:s.id,producto_id:s.projection_id===id(502)?id(7):id(6),cantidad_cajas:i===0?100:50}));
            const header={submission_id:id(700),fecha_embarque:day+'T00:00',temperatura_viaje:50,placas_tractor:'TR',placas_caja:'CJ',nombre_operador:'Operador',economico:'E1',pies:'53',termografo:'TG1',termo_continuo:'Sí'};
            const register=(stop='a',items=details.slice(0,2),head=header)=>db.query<{registrar_embarque_consolidado:string}>('select registrar_embarque_consolidado($1,$2,$3,$4::jsonb,$5::jsonb)',[journey,stop,items.map(d=>d.schedule_id),JSON.stringify(head),JSON.stringify(items)]);
            const before=(await db.query<{n:number}>('select count(*)::integer as n from usa_embarques')).rows[0].n;
            await db.exec('alter table usa_shipment_reports add constraint simulated_dispatch_failure check(total_real_boxes<0) not valid;');
            await assert.rejects(()=>register(),/simulated_dispatch_failure/);
            assert.equal((await db.query<{n:number}>('select count(*)::integer as n from usa_embarques')).rows[0].n,before,'Dispatch failure rolls back the physical shipment');
            await db.exec('alter table usa_shipment_reports drop constraint simulated_dispatch_failure;');
            const shipment=(await register()).rows[0].registrar_embarque_consolidado;
            assert.equal((await register()).rows[0].registrar_embarque_consolidado,shipment);
            await assert.rejects(()=>register('a',[{...details[0],cantidad_cajas:99},details[1]]),/otros datos/);
            let report=(await db.query<any>('select * from usa_shipment_reports where source_load_id=$1',[journey])).rows[0];
            assert.equal(report.logistic_status,'En ruta'); assert.equal(Number(report.total_real_boxes),150);
            assert.equal(report.products.length,2); assert.deepEqual(report.client_ids.sort(),[id(3),id(4)]);
            assert.equal(report.thermograph_serial,'TG1'); assert.equal(report.tive_tracker_id,null);
            assert.equal(report.source_shipment_ids.length,1); assert.equal(report.products[0].realQty,100);
            await db.exec('grant select,insert,update,delete on usa_shipment_reports to authenticated;set role authenticated;');
            await db.exec("set test.user_role='TRAFICO_RI';");
            await db.query("update usa_shipment_reports set comments='Seguimiento',logistic_status='En Tránsito',driver_phone='555',freight_cost=125,tive_tracker_id='TIVE-REAL' where id=$1",[report.id]);
            await assert.rejects(()=>db.query("update usa_shipment_reports set products='[]' where id=$1",[report.id]),/se corrigen/);
            await assert.rejects(()=>db.query("update usa_shipment_reports set ideal_temp=48 where id=$1",[report.id]),/se corrigen/);
            await assert.rejects(()=>db.query('delete from usa_shipment_reports where id=$1',[report.id]),/salidas vinculadas/);
            await assert.rejects(()=>db.query("insert into usa_shipment_reports(trip_id,source_load_id) values('FALSO',$1)",[id(888)]),/se crea desde/);
            await assert.rejects(()=>db.query('select sync_usa_dispatch($1)',[journey]),/permission denied/);
            await assert.rejects(()=>db.query('select registrar_embarque_consolidado_base($1,$2,$3,$4::jsonb,$5::jsonb)',[journey,'a',[],JSON.stringify(header),'[]']),/permission denied/);
            await db.exec("set test.user_role='COMPRAS';");
            await assert.rejects(()=>db.query("update usa_shipment_reports set comments='No autorizado' where id=$1",[report.id]),/Tu rol/);
            await db.exec("reset role;set test.user_role='ADMINISTRADOR';");
            await db.query('select confirm_transport_stop($1,1,$2,$3::jsonb,$4,$5::jsonb)',[journey,'a','[10000,12000,10000]','Ticket','{}']);
            await register('b',[details[2]],{...header,submission_id:id(701),fecha_embarque:day+'T00:01'});
            report=(await db.query<any>('select * from usa_shipment_reports where source_load_id=$1',[journey])).rows[0];
            assert.equal((await db.query('select * from usa_shipment_reports')).rows.length,1);
            assert.equal(Number(report.total_real_boxes),200); assert.equal(report.source_shipment_ids.length,2);
            assert.equal(report.products.length,3); assert.equal(report.source_manifest.length,3);
            assert.equal(report.logistic_status,'En Tránsito'); assert.equal(report.comments,'Seguimiento'); assert.equal(report.tive_tracker_id,'TIVE-REAL');
            assert.ok(report.route_plan.stops[0].completedAt); assert.equal(Number(report.freight_cost),125);
            assert.deepEqual(report.project_ids.sort(),[id(1),id(2)]);
        });
        await t.test('authenticated callers cannot bypass RPCs to forge plans or call private validation',async()=>{
            await db.exec('grant usage on schema auth to authenticated;set role authenticated;');
            await assert.rejects(()=>db.query('insert into usa_viajes_planeados(scheduled_date,plan) values($1,$2::jsonb)',['2026-11-13',JSON.stringify(plan)]),/permission denied/);
            await assert.rejects(()=>db.query('select validate_transport_plan($1::jsonb,null)',[JSON.stringify(plan)]),/permission denied/);
            await db.exec('reset role;');
        });
    } finally { await db.close(); }
});
