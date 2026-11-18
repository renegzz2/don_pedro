begin;

do $$ begin
    if to_regprocedure('public.trip_departure_temperature(jsonb)') is null then
        raise exception 'Aplica primero 202611130005_fixed_departure_temperature.sql y sus migraciones anteriores.';
    end if;
end $$;

-- JWT app_metadata.role is the application's authority. Also register the label
-- in the legacy profile enum when that enum exists.
do $$ begin
    if exists(select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typname='user_role') then
        alter type public.user_role add value if not exists 'TRAFICO_RI';
    end if;
end $$;

drop policy if exists compras_insert on public.usa_solicitudes_insumos;
create policy compras_insert on public.usa_solicitudes_insumos for insert to authenticated with check (
    status='pendiente' and created_by=auth.uid() and upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) in ('COMPRAS','ADMINISTRADOR')
);

-- Enforce creation dates on the server as well as in the form. Historical rows
-- remain editable when their existing dates are not changed.
create or replace function public.validate_new_goal_date() returns trigger
language plpgsql set search_path=public as $$
declare today date:=(now() at time zone 'America/Mexico_City')::date; requested date; item jsonb; date_changed boolean;
begin
    -- SQL maintenance/import sessions have no end-user identity.
    if auth.uid() is null then return new;end if;
    if tg_op='INSERT' then
        if upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('COMERCIAL','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede crear metas comerciales.';end if;
        if new.fecha_salida is null then raise exception 'Selecciona la fecha de carga de la meta.';end if;
        date_changed:=true;
    else
        date_changed:=new.fecha_salida is distinct from old.fecha_salida;
    end if;
    if date_changed and new.fecha_salida is null then raise exception 'Selecciona la fecha de carga de la meta.';end if;
    requested:=new.fecha_salida::date;
    if date_changed and requested<today then raise exception 'No se pueden crear metas para días pasados. Selecciona hoy o una fecha futura.';end if;
    if requested is not null and (tg_op='INSERT' or date_changed or new.planning_year is distinct from old.planning_year or new.semana_fiscal is distinct from old.semana_fiscal) then
        if extract(isoyear from requested)::integer<>new.planning_year or extract(week from requested)::integer<>new.semana_fiscal then raise exception 'El año y semana de la meta deben corresponder a su fecha de carga.';end if;
    end if;
    if tg_op='INSERT' or new.desglose_diario is distinct from old.desglose_diario then
        for item in select value from jsonb_array_elements(coalesce(new.desglose_diario::jsonb,'[]'::jsonb)) loop
            if (item->>'fecha')::date<today then
                if tg_op='INSERT' then raise exception 'No se pueden crear metas para días pasados.';end if;
                if not exists(select 1 from jsonb_array_elements(coalesce(old.desglose_diario::jsonb,'[]'::jsonb)) d where (d->>'fecha')::date=(item->>'fecha')::date) then raise exception 'No se pueden agregar días pasados a una meta.';end if;
            end if;
        end loop;
    end if;
    return new;
end $$;
drop trigger if exists validate_new_goal_date on public.proyecciones_estrategicas;
create trigger validate_new_goal_date before insert or update on public.proyecciones_estrategicas for each row execute function public.validate_new_goal_date();

-- Section-specific permissions for operational writes.
create or replace function public.validate_packing_plan() returns trigger
language plpgsql set search_path = public as $$
declare item jsonb; total numeric := 0; day date;
begin
    if tg_op = 'UPDATE' and new.packing_plan is not distinct from old.packing_plan and new.proyeccion_cajas is not distinct from old.proyeccion_cajas then return new; end if;
    if ((tg_op = 'UPDATE' and new.packing_plan is distinct from old.packing_plan) or (tg_op = 'INSERT' and new.packing_plan <> '[]'::jsonb))
       and upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('LIDER_PROYECTO','ADMINISTRADOR') then
        raise exception 'Solo el líder de empaque o Dirección puede distribuir cajas.';
    end if;
    if jsonb_typeof(new.packing_plan) <> 'array' then raise exception 'La programación debe ser una lista de días.'; end if;
    if exists(select 1 from jsonb_array_elements(new.packing_plan) d group by (d->>'fecha')::date having count(*) > 1) then
        raise exception 'Captura una sola cantidad por día para esta meta.';
    end if;
    for item in select * from jsonb_array_elements(new.packing_plan) loop
        day := (item->>'fecha')::date;
        if day is null or extract(week from day)::integer <> new.semana_fiscal or extract(isoyear from day)::integer <> new.planning_year then
            raise exception 'Programa las cajas dentro de la semana de la meta.';
        end if;
        if (item->>'cantidad') is null or (item->>'cantidad')::numeric <= 0 or (item->>'cantidad')::numeric <> trunc((item->>'cantidad')::numeric) then
            raise exception 'Las cajas deben ser enteras y positivas.';
        end if;
        total := total + (item->>'cantidad')::numeric;
    end loop;
    if total > new.proyeccion_cajas then raise exception 'La programación de empaque supera la meta comercial.'; end if;
    if exists (select 1 from public.usa_programacion_fletes s where s.projection_id = new.id group by scheduled_date
        having sum(s.quantity) > (select coalesce(sum((d->>'cantidad')::numeric),0) from jsonb_array_elements(new.packing_plan) d where (d->>'fecha')::date = s.scheduled_date)) then
        raise exception 'Retira los fletes del día antes de reducir su programación de empaque.';
    end if;
    return new;
end $$;

create or replace function public.save_packing_plan(p_goal_id uuid, p_plan jsonb, p_expected jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare goal public.proyecciones_estrategicas;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('LIDER_PROYECTO','ADMINISTRADOR') then raise exception 'Tu rol no puede programar empaque.'; end if;
    select * into goal from public.proyecciones_estrategicas where id = p_goal_id for update;
    if not found then raise exception 'La meta ya no existe.'; end if;
    if goal.packing_plan is distinct from p_expected then raise exception 'Otro usuario cambió la programación. Actualiza y vuelve a intentarlo.'; end if;
    update public.proyecciones_estrategicas set packing_plan = p_plan where id = p_goal_id;
end $$;

create or replace function public.save_transport_trip(p_plan jsonb,p_expected_revision integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid:=coalesce(nullif(p_plan->>'id','')::uuid,gen_random_uuid()); oldrow public.usa_viajes_planeados; nextrev integer; c jsonb; s jsonb; prior jsonb; item public.usa_programacion_fletes; load_day date; arrival timestamptz; thermal jsonb; previous_thermal jsonb; origin_completed boolean;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('TRAFICO_RI','ADMINISTRADOR') then raise exception 'Tu rol no puede programar viajes.'; end if;
    -- Serialize reservations on both old and new parent goals before locking the journey.
    perform id from public.proyecciones_estrategicas where id in (
        select (a->>'projectionId')::uuid from jsonb_array_elements(p_plan->'cargo') a where a->>'kind'='product'
        union select s.projection_id from public.usa_programacion_fletes s where s.load_id=tid
    ) order by id for update;
    select * into oldrow from public.usa_viajes_planeados where id=tid for update;
    if found then
        if oldrow.revision is distinct from p_expected_revision then raise exception 'Otro usuario modificó el viaje. Actualiza e intenta de nuevo.'; end if;
        if exists(select 1 from jsonb_array_elements(oldrow.plan->'stops') z where z->>'completedAt' is not null) and (p_plan->'equipment',p_plan->>'carrierId',p_plan->>'tractorPlates',p_plan->>'trailerPlates') is distinct from (oldrow.plan->'equipment',oldrow.plan->>'carrierId',oldrow.plan->>'tractorPlates',oldrow.plan->>'trailerPlates') then raise exception 'No se puede cambiar el equipo o proveedor después de iniciar el viaje.'; end if;
        for s in select value from jsonb_array_elements(oldrow.plan->'stops') where value->>'completedAt' is not null loop
            select value into prior from jsonb_array_elements(p_plan->'stops') where value->>'id'=s->>'id';
            if prior is distinct from s or (select ord from jsonb_array_elements(p_plan->'stops') with ordinality d(v,ord) where v->>'id'=s->>'id') is distinct from (select ord from jsonb_array_elements(oldrow.plan->'stops') with ordinality d(v,ord) where v->>'id'=s->>'id') then raise exception 'No modifiques paradas ya confirmadas ni insertes paradas antes de ellas.'; end if;
        end loop;
        for c in select value from jsonb_array_elements(oldrow.plan->'cargo') where value->>'loadStopId' in (select value->>'id' from jsonb_array_elements(oldrow.plan->'stops') where value->>'completedAt' is not null) loop
            select value into prior from jsonb_array_elements(p_plan->'cargo') where value->>'id'=c->>'id';
            if prior is distinct from c then raise exception 'La carga ya recogida no puede modificarse; solo se pueden añadir recolecciones futuras.'; end if;
        end loop;
        nextrev:=oldrow.revision+1;
    else
        if p_expected_revision is distinct from 0 then raise exception 'El viaje ya no existe.'; end if;
        nextrev:=1;
    end if;
    -- Completion is recorded only by confirm_transport_stop, never by a plan edit.
    for s in select value from jsonb_array_elements(p_plan->'stops') where value->>'completedAt' is not null loop
        if oldrow.id is null or not exists(select 1 from jsonb_array_elements(oldrow.plan->'stops') a where a=s) then raise exception 'No se pueden confirmar paradas desde el editor.'; end if;
    end loop;
    if exists(select 1 from jsonb_array_elements(p_plan->'cargo') a where a->>'loadStopId' in (select value->>'id' from jsonb_array_elements(p_plan->'stops') where value->>'completedAt' is not null) and not exists(select 1 from jsonb_array_elements(coalesce(oldrow.plan->'cargo','[]')) b where b=a)) then raise exception 'Una nueva carga debe recogerse en una parada futura.'; end if;
    p_plan:=jsonb_set(jsonb_set(p_plan,'{id}',to_jsonb(tid::text)),'{revision}',to_jsonb(nextrev));
    if (p_plan->>'scheduledDate')::date is distinct from left(p_plan->'stops'->0->>'at',10)::date then raise exception 'La fecha del viaje debe coincidir con la primera parada.'; end if;
    if not exists(select 1 from public.usa_lineas_transporte where id=(p_plan->>'carrierId')::uuid) then raise exception 'Selecciona proveedor de transporte.'; end if;
    perform id from public.usa_solicitudes_insumos where id in (select (a->>'requestId')::uuid from jsonb_array_elements(p_plan->'cargo') a where a->>'kind'='supplies') order by id for update;
    thermal:=public.trip_departure_temperature(p_plan);
    if oldrow.id is not null then
        previous_thermal:=public.trip_departure_temperature(oldrow.plan - 'temperatureF');
        select exists(select 1 from jsonb_array_elements(oldrow.plan->'stops') z where z->>'id'=previous_thermal->>'originStopId' and z->>'completedAt' is not null) into origin_completed;
        if origin_completed and oldrow.plan->>'temperatureF' is null and p_plan->>'temperatureF' is null then raise exception 'Confirma la temperatura de salida registrada en el punto A; no se puede inferir para un viaje iniciado.';end if;
        if origin_completed and oldrow.plan->>'temperatureF' is not null and ((thermal->>'value')::numeric is distinct from (oldrow.plan->>'temperatureF')::numeric or thermal->>'originStopId' is distinct from previous_thermal->>'originStopId') then raise exception 'La temperatura del punto A ya está fijada y no se puede cambiar para una recolección intermedia.';end if;
    end if;
    p_plan:=jsonb_set(jsonb_set(p_plan,'{temperatureF}',thermal->'value'),'{temperatureOriginStopId}',thermal->'originStopId');
    perform public.validate_transport_plan(p_plan,tid);
    -- Keep scale tickets and actual history server-owned.
    p_plan:=jsonb_set(p_plan,'{scaleTickets}',coalesce(oldrow.plan->'scaleTickets','[]'::jsonb));
    insert into public.usa_viajes_planeados(id,revision,scheduled_date,plan) values(tid,nextrev,(p_plan->>'scheduledDate')::date,p_plan)
    on conflict(id) do update set revision=excluded.revision,scheduled_date=excluded.scheduled_date,plan=excluded.plan,updated_at=now();
    perform set_config('app.transport_trip_write',tid::text,true);
    -- Existing shipped allocations are preserved unchanged. Only edited/unshipped rows are replaced.
    for item in select * from public.usa_programacion_fletes where load_id=tid loop
        select value into c from jsonb_array_elements(p_plan->'cargo') a where value->>'kind'='product' and (value->>'projectionId')::uuid=item.projection_id;
        select value into s from jsonb_array_elements(p_plan->'stops') a where value->>'id'=c->>'loadStopId';
        if c is null or item.quantity<>(c->>'boxes')::integer or item.scheduled_date<>left(s->>'at',10)::date or item.unit_type_id<>(p_plan->>'unitTypeId')::bigint or item.carrier_id<>(p_plan->>'carrierId')::uuid or item.arrival_at<>public.transport_at(p_plan->>'arrivalAt') then
            delete from public.usa_programacion_fletes where id=item.id;
        end if;
    end loop;
    for c in select value from jsonb_array_elements(p_plan->'cargo') where value->>'kind'='product' loop
        select value into s from jsonb_array_elements(p_plan->'stops') where value->>'id'=c->>'loadStopId';load_day:=left(s->>'at',10)::date;
        if not exists(select 1 from public.usa_programacion_fletes where load_id=tid and projection_id=(c->>'projectionId')::uuid and scheduled_date=load_day) then
            insert into public.usa_programacion_fletes(load_id,projection_id,scheduled_date,arrival_at,carrier_id,quantity,unit_label,unit_type_id)
            values(tid,(c->>'projectionId')::uuid,load_day,public.transport_at(p_plan->>'arrivalAt'),(p_plan->>'carrierId')::uuid,(c->>'boxes')::integer,'1 '||(select unidad from public.tipo_unidad where id=(p_plan->>'unitTypeId')::bigint),(p_plan->>'unitTypeId')::bigint);
        end if;
    end loop;
    update public.usa_solicitudes_insumos r set status=case when exists(select 1 from jsonb_array_elements(p_plan->'cargo') a where a->>'requestId'=r.id::text) then case when r.status='entregada' then 'entregada' else 'asignada' end else 'pendiente' end
    where r.id in (select (a->>'requestId')::uuid from jsonb_array_elements(p_plan->'cargo') a where a->>'kind'='supplies' union select (a->>'requestId')::uuid from jsonb_array_elements(coalesce(oldrow.plan->'cargo','[]')) a where a->>'kind'='supplies');
    insert into public.usa_viajes_auditoria(trip_id,action,plan) values(tid,case when oldrow.id is null then 'creado' else 'modificado' end,p_plan);
    return tid;
end $$;

create or replace function public.cancel_transport_trip(p_trip_id uuid,p_expected_revision integer)
returns void language plpgsql security definer set search_path=public as $$
declare t public.usa_viajes_planeados;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('TRAFICO_RI','ADMINISTRADOR') then raise exception 'Tu rol no puede cancelar viajes.'; end if;
    perform id from public.proyecciones_estrategicas where id in (select projection_id from public.usa_programacion_fletes where load_id=p_trip_id) order by id for update;
    select * into t from public.usa_viajes_planeados where id=p_trip_id for update;
    if not found or t.revision is distinct from p_expected_revision then raise exception 'El viaje cambió. Actualiza.'; end if;
    if exists(select 1 from jsonb_array_elements(t.plan->'stops') s where s->>'completedAt' is not null) then raise exception 'No se puede cancelar un viaje iniciado.'; end if;
    perform set_config('app.transport_trip_write',p_trip_id::text,true);
    delete from public.usa_programacion_fletes where load_id=p_trip_id;
    update public.usa_solicitudes_insumos set status='pendiente' where id in (select (a->>'requestId')::uuid from jsonb_array_elements(t.plan->'cargo') a where a->>'kind'='supplies');
    delete from public.usa_viajes_planeados where id=p_trip_id;
    insert into public.usa_viajes_auditoria(trip_id,action,plan) values(p_trip_id,'cancelado',t.plan);
end $$;

create or replace function public.confirm_transport_stop(p_trip_id uuid,p_expected_revision integer,p_stop_id text,p_weights jsonb,p_reference text,p_received jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare t public.usa_viajes_planeados; s jsonb;c jsonb; next_stop text; idx integer; weights numeric[]; limits jsonb; u public.tipo_unidad; shipped numeric; scheduled uuid; needs_scale boolean; received numeric;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('TRAFICO_RI','ADMINISTRADOR') then raise exception 'Tu rol no puede confirmar operaciones.'; end if;
    select * into t from public.usa_viajes_planeados where id=p_trip_id for update;
    if not found or t.revision is distinct from p_expected_revision then raise exception 'El viaje cambió. Actualiza.'; end if;
    select value->>'id',ord::integer-1,value into next_stop,idx,s from jsonb_array_elements(t.plan->'stops') with ordinality a(value,ord) where value->>'completedAt' is null order by ord limit 1;
    if next_stop is distinct from p_stop_id then raise exception 'Confirma las paradas en el orden del recorrido.'; end if;
    if public.transport_at(s->>'at')>now()+interval '5 minutes' then raise exception 'No puedes confirmar una parada futura.'; end if;
    if coalesce(trim(p_reference),'')='' then raise exception 'Indica una referencia de báscula/recepción.'; end if;
    perform public.validate_transport_plan(t.plan,t.id);
    select * into u from public.tipo_unidad where id=(t.plan->>'unitTypeId')::bigint;
    select exists(select 1 from jsonb_array_elements(t.plan->'cargo') a where (select ord from jsonb_array_elements(t.plan->'stops') with ordinality q(v,ord) where v->>'id'=a->>'loadStopId')<=idx+1 and (select ord from jsonb_array_elements(t.plan->'stops') with ordinality q(v,ord) where v->>'id'=a->>'unloadStopId')>idx+1) into needs_scale;
    if needs_scale then
        if coalesce(trim(t.plan->>'tractorPlates'),'')='' or coalesce(trim(t.plan->>'trailerPlates'),'')='' then raise exception 'Identifica las placas del tractor y de la caja antes de salir.'; end if;
        if t.plan->'equipment'->>'kingpinM' is null or t.plan->'equipment'->>'trailerAxleM' is null or t.plan->'equipment'->>'fifthWheelM' is null or t.plan->'equipment'->>'tractorWheelbaseM' is null or t.plan->'equipment'->>'lengthM' is null or jsonb_array_length(coalesce(t.plan->'equipment'->'emptyAxlesLb','[]'))<>3 then raise exception 'Completa geometría y tara por ejes antes de salir con carga.'; end if;
        if jsonb_typeof(p_weights) is distinct from 'array' or jsonb_array_length(p_weights)<>3 or exists(select 1 from jsonb_array_elements(p_weights) a where a='null'::jsonb or (a::text)::numeric<=0) then raise exception 'Registra pesos reales positivos de los tres grupos de ejes.'; end if;
        limits:=u.limites_ejes_lb;
        if limits is null or jsonb_array_length(limits)<>3 then raise exception 'Configura los límites por ejes.'; end if;
        if exists(select 1 from jsonb_array_elements_text(p_weights) with ordinality a(v,ord) where v::numeric>(limits->>(ord::integer-1))::numeric) or (select sum(v::numeric) from jsonb_array_elements_text(p_weights) a(v))>u.peso_bruto_max_lb or (select sum(v::numeric) from jsonb_array_elements_text(p_weights) a(v))-(select sum(v::numeric) from jsonb_array_elements_text(t.plan->'equipment'->'emptyAxlesLb') a(v))>u.carga_util_lb then raise exception 'El pesaje real supera los límites del equipo.'; end if;
    end if;
    for c in select value from jsonb_array_elements(t.plan->'cargo') where value->>'kind'='product' and value->>'loadStopId'=p_stop_id loop
        select id into scheduled from public.usa_programacion_fletes where load_id=t.id and projection_id=(c->>'projectionId')::uuid;
        select coalesce(sum(d.cantidad_cajas),0) into shipped from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id where e.schedule_id=scheduled and d.producto_id=(c->>'productId')::uuid;
        if shipped<>(c->>'boxes')::numeric then raise exception 'Embarques debe registrar las cajas reales de cada producto antes de confirmar la salida.'; end if;
    end loop;
    for c in select value from jsonb_array_elements(t.plan->'cargo') where value->>'kind'='supplies' and value->>'unloadStopId'=p_stop_id loop
        update public.usa_solicitudes_insumos set status='entregada' where id=(c->>'requestId')::uuid;
    end loop;
    for c in select value from jsonb_array_elements(t.plan->'cargo') where value->>'kind'='product' and value->>'unloadStopId'=p_stop_id loop
        received:=(p_received->>(c->>'id'))::numeric;
        if received is null or received<0 or received<>trunc(received) or received>(c->>'boxes')::numeric then raise exception 'Captura las cajas realmente recibidas por cada cliente (sin superar las embarcadas).'; end if;
        insert into public.usa_recepciones_cliente(trip_id,cargo_id,proyecto_id,producto_id,client_id,cajas,referencia) values(t.id,c->>'id',(c->>'projectId')::uuid,(c->>'productId')::uuid,(c->>'clientId')::uuid,received::integer,p_reference);
    end loop;
    t.plan:=jsonb_set(t.plan,array['stops',idx::text,'completedAt'],to_jsonb(now()));
    t.plan:=jsonb_set(t.plan,'{revision}',to_jsonb(t.revision+1));
    if needs_scale then t.plan:=jsonb_set(t.plan,'{scaleTickets}',coalesce(t.plan->'scaleTickets','[]')||jsonb_build_array(jsonb_build_object('stopId',p_stop_id,'weightsLb',p_weights,'reference',p_reference,'at',now())));end if;
    update public.usa_viajes_planeados set plan=t.plan,revision=t.revision+1,updated_at=now(),completed_at=case when not exists(select 1 from jsonb_array_elements(t.plan->'stops') a where a->>'completedAt' is null) then now() else null end where id=t.id;
    insert into public.usa_viajes_auditoria(trip_id,action,plan) values(t.id,'parada_confirmada: '||p_reference,t.plan);
end $$;

create or replace function public.remove_consolidated_load(p_schedule_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare freight public.usa_programacion_fletes;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('TRAFICO_RI','ADMINISTRADOR') then raise exception 'Tu rol no puede retirar transporte.'; end if;
    select * into freight from public.usa_programacion_fletes where id = p_schedule_id;
    if not found then raise exception 'La unidad ya no existe.'; end if;
    -- Match the reservation lock order (goal, then schedules).
    perform id from public.proyecciones_estrategicas where id in (select projection_id from public.usa_programacion_fletes where id = freight.id or load_id = freight.load_id) order by id for update;
    delete from public.usa_programacion_fletes where id = freight.id or load_id = freight.load_id;
end $$;

commit;
