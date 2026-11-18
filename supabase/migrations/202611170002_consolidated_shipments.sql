-- Apply after 202611170001_planning_sections_future_goals.sql.
begin;

do $$
begin
    if to_regprocedure('public.save_transport_trip(jsonb,integer)') is null then
        raise exception 'Aplica primero las migraciones de programación hasta 202611170001.';
    end if;
    if position('''TRAFICO_RI''' in pg_get_functiondef('public.save_transport_trip(jsonb,integer)'::regprocedure))=0 then
        raise exception 'Aplica primero 202611170001_planning_sections_future_goals.sql.';
    end if;
end $$;

alter table public.usa_embarques
    add column if not exists load_id uuid,
    add column if not exists pickup_stop_id text;
alter table public.usa_embarques_detalle
    add column if not exists schedule_id uuid references public.usa_programacion_fletes(id);
create index if not exists shipment_detail_schedule_idx on public.usa_embarques_detalle(schedule_id);
update public.usa_embarques_detalle d set schedule_id=e.schedule_id
from public.usa_embarques e where e.id=d.embarque_id and d.schedule_id is null and e.schedule_id is not null;

create or replace function public.attribute_scheduled_shipment_detail()
returns trigger language plpgsql set search_path=public as $$
declare g public.proyecciones_estrategicas; shipment public.usa_embarques; freight public.usa_programacion_fletes;
begin
    select * into shipment from public.usa_embarques where id=new.embarque_id;
    new.schedule_id:=coalesce(new.schedule_id,shipment.schedule_id);
    if new.schedule_id is not null then
        select * into freight from public.usa_programacion_fletes where id=new.schedule_id;
        if not found or (shipment.load_id is not null and freight.load_id is distinct from shipment.load_id)
            or (shipment.load_id is null and new.schedule_id is distinct from shipment.schedule_id) then
            raise exception 'La asignación no pertenece a la unidad del embarque.';
        end if;
        select * into g from public.proyecciones_estrategicas where id=freight.projection_id;
        if new.producto_id is distinct from g.producto_id then raise exception 'El producto no corresponde a la asignación.'; end if;
        new.proyecto_id:=g.proyecto_id; new.client_id:=g.client_id; new.proyeccion_id:=g.id;
        new.attribution_reference:='Flete vinculado';
    end if;
    return new;
end $$;

-- Retain the installed role rules and legacy entry point, changing only the
-- allocation lookups to use the detail link for multi-product shipments.
do $$
declare definition text; updated text; signature text;
begin
    foreach signature in array array[
        'public.registrar_embarque_programado(uuid,jsonb,jsonb)',
        'public.confirm_transport_stop(uuid,integer,text,jsonb,text,jsonb)',
        'public.validate_commercial_freight()'
    ] loop
        definition:=pg_get_functiondef(signature::regprocedure);
        updated:=replace(definition,'where e.schedule_id = freight.id','where coalesce(d.schedule_id,e.schedule_id) = freight.id');
        updated:=replace(updated,'where e.schedule_id=scheduled','where coalesce(d.schedule_id,e.schedule_id)=scheduled');
        updated:=replace(updated,'select 1 from public.usa_embarques where schedule_id = old.id',
            'select 1 from public.usa_embarques_detalle d join public.usa_embarques e on e.id=d.embarque_id where coalesce(d.schedule_id,e.schedule_id) = old.id');
        -- Already rewritten on a second execution.
        if updated=definition and position('coalesce(d.schedule_id,e.schedule_id)' in definition)=0 then
            raise exception 'Versión de función inesperada: %. Aplica primero las migraciones anteriores.',signature;
        end if;
        execute updated;
    end loop;
end $$;

create or replace function public.registrar_embarque_consolidado(
    p_load_id uuid, p_stop_id text, p_schedule_ids uuid[], p_header jsonb, p_details jsonb
) returns uuid language plpgsql security definer set search_path=public as $$
declare
    trip public.usa_viajes_planeados; freight public.usa_programacion_fletes;
    goal public.proyecciones_estrategicas; c jsonb; stop jsonb;
    shipment_id uuid:=gen_random_uuid(); first_schedule uuid; carrier uuid;
    real_departure timestamp:=(p_header->>'fecha_embarque')::timestamp;
    requested numeric; shipped numeric; clients uuid[]; destinations text;
    expected uuid[]; supplied uuid[];
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role',''))
        not in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR','ADMINISTRATIVO') then
        raise exception 'Tu rol no puede registrar embarques.';
    end if;
    if real_departure is null or real_departure > (now() at time zone 'America/Mexico_City')+interval '5 minutes' then
        raise exception 'Captura la salida real; no puede ser futura.';
    end if;
    if coalesce(cardinality(p_schedule_ids),0)=0 or jsonb_typeof(p_details) is distinct from 'array' or jsonb_array_length(p_details)=0 then
        raise exception 'Selecciona la unidad y captura al menos una tarima.';
    end if;
    select array_agg(distinct sid order by sid) into supplied from unnest(p_schedule_ids) sid;
    if cardinality(supplied)<>cardinality(p_schedule_ids) then raise exception 'Asignaciones duplicadas.'; end if;
    if p_load_id is not null then
        select * into trip from public.usa_viajes_planeados where id=p_load_id for update;
        if found then
            select value into stop from jsonb_array_elements(trip.plan->'stops') where value->>'id'=p_stop_id;
            if stop is null or stop->>'completedAt' is not null then raise exception 'Selecciona un punto de carga pendiente del viaje.'; end if;
            if (trip.plan->>'temperatureF')::numeric is not null and
                (p_header->>'temperatura_viaje')::numeric is distinct from (trip.plan->>'temperatureF')::numeric then
                raise exception 'La temperatura debe coincidir con la fijada en programación.';
            end if;
            select array_agg(s.id order by s.id) into expected from public.usa_programacion_fletes s
            where s.load_id=p_load_id and exists(select 1 from jsonb_array_elements(trip.plan->'cargo') a
                where a->>'kind'='product' and (a->>'projectionId')::uuid=s.projection_id and a->>'loadStopId'=p_stop_id);
        else
            -- Loads created before the multistop workflow have no journey JSON.
            select array_agg(id order by id) into expected from public.usa_programacion_fletes
            where load_id=p_load_id and scheduled_date=real_departure::date;
        end if;
    else
        if cardinality(supplied)<>1 then raise exception 'Selecciona un único flete sin viaje consolidado.'; end if;
        expected:=supplied;
    end if;
    if expected is distinct from supplied then raise exception 'La unidad cambió. Actualiza la programación antes de capturar.'; end if;
    perform id from public.usa_programacion_fletes where id=any(supplied) order by id for update;
    if (select count(*) from public.usa_programacion_fletes where id=any(supplied))<>cardinality(supplied) then raise exception 'El flete ya no está disponible.'; end if;
    if exists(select 1 from public.usa_programacion_fletes s where s.id=any(supplied)
        and (s.load_id is distinct from p_load_id or s.scheduled_date<>real_departure::date)) then
        raise exception 'La unidad o el día real de salida no coincide con la programación.';
    end if;
    select id,carrier_id into first_schedule,carrier from public.usa_programacion_fletes where id=any(supplied) order by id limit 1;
    if exists(select 1 from public.usa_programacion_fletes where id=any(supplied) and carrier_id<>carrier) then raise exception 'La unidad tiene proveedores distintos.'; end if;
    if exists(select 1 from jsonb_array_elements(p_details) d where
        not coalesce((d->>'schedule_id')::uuid=any(supplied),false) or coalesce((d->>'cantidad_cajas')::numeric,0)<=0) then
        raise exception 'Cada tarima debe tener una asignación de la unidad y cajas positivas.';
    end if;
    for freight in select * from public.usa_programacion_fletes where id=any(supplied) order by id loop
        select * into goal from public.proyecciones_estrategicas where id=freight.projection_id;
        if goal.client_id is null then raise exception 'La meta no tiene cliente.'; end if;
        if exists(select 1 from jsonb_array_elements(p_details) d where (d->>'schedule_id')::uuid=freight.id
            and (d->>'producto_id')::uuid is distinct from goal.producto_id) then raise exception 'El producto no corresponde a su meta.'; end if;
        select coalesce(sum((d->>'cantidad_cajas')::numeric),0) into requested from jsonb_array_elements(p_details) d where (d->>'schedule_id')::uuid=freight.id;
        select coalesce(sum(d.cantidad_cajas),0) into shipped from public.usa_embarques_detalle d join public.usa_embarques e on e.id=d.embarque_id where coalesce(d.schedule_id,e.schedule_id)=freight.id;
        if shipped+requested>freight.quantity then raise exception 'Las cajas superan la cantidad programada para un producto / cliente.'; end if;
    end loop;
    select array_agg(distinct g.client_id),string_agg(distinct cl.nombre,', ')
    into clients,destinations from public.usa_programacion_fletes s join public.proyecciones_estrategicas g on g.id=s.projection_id
    join public.usa_clientes cl on cl.id=g.client_id where s.id=any(supplied);
    insert into public.usa_embarques(id,fecha_embarque,folio_embarque,schedule_id,load_id,pickup_stop_id,client_id,carrier_id,
        linea_transporte,nombre_operador,placas_caja,placas_tractor,temperatura_viaje,destino,economico,pies,termografo,termo_continuo,
        estatus_embarque,alerta_inspeccion_pt,diferencias_auditoria,foto_remision,foto_termografo,foto_diesel,foto_refacciones,foto_temperatura)
    values(shipment_id,real_departure,p_header->>'folio_embarque',first_schedule,p_load_id,p_stop_id,
        case when cardinality(clients)=1 then clients[1] else null end,carrier,
        (select nombre from public.usa_lineas_transporte where id=carrier),p_header->>'nombre_operador',p_header->>'placas_caja',p_header->>'placas_tractor',
        (p_header->>'temperatura_viaje')::numeric,destinations,p_header->>'economico',p_header->>'pies',p_header->>'termografo',p_header->>'termo_continuo',
        'EN REVISIÓN RI',coalesce((p_header->>'alerta_inspeccion_pt')::boolean,false),p_header->'diferencias_auditoria',
        p_header->>'foto_remision',p_header->>'foto_termografo',p_header->>'foto_diesel',p_header->>'foto_refacciones',p_header->>'foto_temperatura');
    insert into public.usa_embarques_detalle(embarque_id,schedule_id,numero_pallet,producto_id,remision,mid,lote_pt,cantidad_cajas)
    select shipment_id,(d->>'schedule_id')::uuid,d->>'numero_pallet',(d->>'producto_id')::uuid,d->>'remision',d->>'mid',d->>'lote_pt',(d->>'cantidad_cajas')::numeric
    from jsonb_array_elements(p_details) d;
    return shipment_id;
end $$;
revoke all on function public.registrar_embarque_consolidado(uuid,text,uuid[],jsonb,jsonb) from public;
grant execute on function public.registrar_embarque_consolidado(uuid,text,uuid[],jsonb,jsonb) to authenticated;

commit;
