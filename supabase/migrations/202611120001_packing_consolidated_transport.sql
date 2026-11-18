begin;

alter table public.proyecciones_estrategicas add column if not exists packing_plan jsonb not null default '[]'::jsonb;
alter table public.usa_programacion_fletes add column if not exists load_id uuid;
alter table public.usa_programacion_fletes add column if not exists unit_type_id bigint references public.tipo_unidad(id);
create index if not exists usa_fletes_load on public.usa_programacion_fletes(load_id);

-- Preserve existing transport commitments; unassigned commercial goals await the leader.
update public.proyecciones_estrategicas g set packing_plan = coalesce((
    select jsonb_agg(jsonb_build_object('fecha', d.scheduled_date::text, 'cantidad', d.quantity) order by d.scheduled_date)
    from (select scheduled_date, sum(quantity) quantity from public.usa_programacion_fletes where projection_id = g.id group by scheduled_date) d
), '[]'::jsonb);

create or replace function public.validate_packing_plan() returns trigger
language plpgsql set search_path = public as $$
declare item jsonb; total numeric := 0; day date;
begin
    if tg_op = 'UPDATE' and new.packing_plan is not distinct from old.packing_plan and new.proyeccion_cajas is not distinct from old.proyeccion_cajas then return new; end if;
    if tg_op = 'UPDATE' and new.packing_plan is distinct from old.packing_plan
       and upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('LIDER_PROYECTO','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then
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
create trigger validate_packing_plan before insert or update on public.proyecciones_estrategicas for each row execute function public.validate_packing_plan();

create or replace function public.save_packing_plan(p_goal_id uuid, p_plan jsonb, p_expected jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare goal public.proyecciones_estrategicas;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('LIDER_PROYECTO','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede programar empaque.'; end if;
    select * into goal from public.proyecciones_estrategicas where id = p_goal_id for update;
    if not found then raise exception 'La meta ya no existe.'; end if;
    if goal.packing_plan is distinct from p_expected then raise exception 'Otro usuario cambió la programación. Actualiza y vuelve a intentarlo.'; end if;
    update public.proyecciones_estrategicas set packing_plan = p_plan where id = p_goal_id;
end $$;

create or replace function public.book_consolidated_load(p_day date, p_carrier uuid, p_arrival timestamptz, p_unit_id bigint, p_allocations jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
    load uuid := gen_random_uuid(); goal public.proyecciones_estrategicas; item jsonb;
    project uuid; cap numeric; label text; pallets numeric; planned numeric; booked numeric;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede programar transporte.'; end if;
    if p_day is null or p_arrival is null or p_carrier is null or p_allocations is null or jsonb_typeof(p_allocations) <> 'array' or jsonb_array_length(p_allocations) = 0 then raise exception 'Captura los datos de la unidad.'; end if;
    -- Lock in a consistent order and recheck demand after concurrent reservations.
    perform id from public.proyecciones_estrategicas where id in (select (a->>'projection_id')::uuid from jsonb_array_elements(p_allocations) a) order by id for update;
    select unidad, floor(substring(capacidad from '([0-9]+(?:\.[0-9]+)?)')::numeric) into label, cap from public.tipo_unidad where id = p_unit_id;
    if cap is null or cap < 1 then raise exception 'Configura la capacidad en pallets del transporte.'; end if;
    if exists(select 1 from jsonb_array_elements(p_allocations) a group by a->>'projection_id' having count(*) > 1) then raise exception 'Una meta no debe repetirse en la unidad.'; end if;
    for item in select * from jsonb_array_elements(p_allocations) loop
        select * into goal from public.proyecciones_estrategicas where id = (item->>'projection_id')::uuid;
        if not found or goal.client_id is null then raise exception 'La meta debe existir y tener cliente.'; end if;
        if project is null then project := goal.proyecto_id; end if;
        if project is distinct from goal.proyecto_id then raise exception 'Solo se consolidan metas del mismo proyecto.'; end if;
        if coalesce((item->>'quantity')::numeric,0) <= 0 or (item->>'quantity')::numeric <> trunc((item->>'quantity')::numeric) then raise exception 'Captura cajas enteras positivas.'; end if;
        select coalesce(sum((d->>'cantidad')::numeric),0) into planned from jsonb_array_elements(goal.packing_plan) d where (d->>'fecha')::date = p_day;
        select coalesce(sum(quantity),0) into booked from public.usa_programacion_fletes where projection_id = goal.id and scheduled_date = p_day;
        if booked + (item->>'quantity')::numeric > planned then raise exception 'La carga supera las cajas programadas por empaque. Actualiza el calendario.'; end if;
        if not exists(select 1 from public.usa_productos where id = goal.producto_id and cajas_pallet_usa > 0) then raise exception 'Configura las cajas por pallet del producto.'; end if;
    end loop;
    select sum(ceil(t.boxes / p.cajas_pallet_usa::numeric)) into pallets from (
        select g.producto_id, sum((a->>'quantity')::numeric) boxes from jsonb_array_elements(p_allocations) a
        join public.proyecciones_estrategicas g on g.id = (a->>'projection_id')::uuid group by g.producto_id
    ) t join public.usa_productos p on p.id = t.producto_id;
    if pallets > cap then raise exception 'La carga supera la capacidad de la unidad.'; end if;
    insert into public.usa_programacion_fletes(projection_id, scheduled_date, arrival_at, carrier_id, quantity, unit_label, load_id, unit_type_id)
    select (a->>'projection_id')::uuid, p_day, p_arrival, p_carrier, (a->>'quantity')::integer, '1 ' || label, load, p_unit_id from jsonb_array_elements(p_allocations) a;
    return load;
end $$;

create or replace function public.remove_consolidated_load(p_schedule_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare freight public.usa_programacion_fletes;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede retirar transporte.'; end if;
    select * into freight from public.usa_programacion_fletes where id = p_schedule_id;
    if not found then raise exception 'La unidad ya no existe.'; end if;
    -- Match the reservation lock order (goal, then schedules).
    perform id from public.proyecciones_estrategicas where id in (select projection_id from public.usa_programacion_fletes where id = freight.id or load_id = freight.load_id) order by id for update;
    delete from public.usa_programacion_fletes where id = freight.id or load_id = freight.load_id;
end $$;

revoke all on function public.save_packing_plan(uuid,jsonb,jsonb) from public;
revoke all on function public.book_consolidated_load(date,uuid,timestamptz,bigint,jsonb) from public;
revoke all on function public.remove_consolidated_load(uuid) from public;
grant execute on function public.save_packing_plan(uuid,jsonb,jsonb) to authenticated;
grant execute on function public.book_consolidated_load(date,uuid,timestamptz,bigint,jsonb) to authenticated;
grant execute on function public.remove_consolidated_load(uuid) to authenticated;

create or replace function public.validate_commercial_freight() returns trigger
language plpgsql set search_path = public as $$
declare
    goal public.proyecciones_estrategicas;
    daily_quantity numeric := 0;
    booked numeric;
begin
    if tg_op = 'DELETE' then
        if exists (select 1 from public.usa_embarques where schedule_id = old.id) then
            raise exception 'El flete ya tiene embarques y no se puede eliminar.';
        end if;
        return old;
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from public.usa_embarques where schedule_id = old.id) then
        raise exception 'El flete ya tiene embarques y no se puede modificar.';
    end if;
    select * into goal from public.proyecciones_estrategicas where id = new.projection_id for update;
    if goal.client_id is null then raise exception 'Comercial debe seleccionar el cliente de la meta.'; end if;
    if extract(week from new.scheduled_date)::integer <> goal.semana_fiscal
       or extract(isoyear from new.scheduled_date)::integer <> goal.planning_year then
        raise exception 'El día del flete debe pertenecer a la semana de la meta.';
    end if;
    select coalesce(sum((item->>'cantidad')::numeric), 0) into daily_quantity
    from jsonb_array_elements(goal.packing_plan) item
    where (item->>'fecha')::date = new.scheduled_date;
    select coalesce(sum(quantity), 0) into booked from public.usa_programacion_fletes
    where projection_id = new.projection_id and scheduled_date = new.scheduled_date and id <> new.id;
    if new.quantity + booked > coalesce(daily_quantity, 0) then
        raise exception 'Los fletes superan las cajas programadas por empaque para ese día.';
    end if;
    return new;
end $$;

-- Apply the capacity rule to table writes too, including clients outside this UI.
create or replace function public.validate_consolidated_capacity() returns trigger
language plpgsql set search_path = public as $$
declare project uuid; cap numeric; pallets numeric;
begin
    if tg_op = 'UPDATE' and old.load_id is not null and new is distinct from old then
        raise exception 'Retira la unidad consolidada y vuelve a programarla para cambiar su carga.';
    end if;
    if new.load_id is null then return new; end if;
    perform pg_advisory_xact_lock(hashtextextended(new.load_id::text, 0));
    select proyecto_id into project from public.proyecciones_estrategicas where id = new.projection_id;
    if exists(select 1 from public.usa_programacion_fletes s join public.proyecciones_estrategicas g on g.id = s.projection_id
        where s.load_id = new.load_id and s.id <> new.id and
        (g.proyecto_id, s.scheduled_date, s.carrier_id, s.arrival_at, s.unit_type_id) is distinct from
        (project, new.scheduled_date, new.carrier_id, new.arrival_at, new.unit_type_id)) then
        raise exception 'Una unidad consolidada debe compartir proyecto, día, proveedor, llegada y tipo.';
    end if;
    select floor(substring(capacidad from '([0-9]+(?:\.[0-9]+)?)')::numeric) into cap from public.tipo_unidad where id = new.unit_type_id;
    if cap is null or cap < 1 then raise exception 'La unidad debe tener capacidad en pallets.'; end if;
    if exists(select 1 from (
        select new.projection_id projection_id union all select projection_id from public.usa_programacion_fletes where load_id = new.load_id and id <> new.id
    ) a join public.proyecciones_estrategicas g on g.id = a.projection_id join public.usa_productos p on p.id = g.producto_id where coalesce(p.cajas_pallet_usa,0) <= 0) then
        raise exception 'Configura las cajas por pallet del producto.';
    end if;
    select sum(ceil(t.boxes / p.cajas_pallet_usa::numeric)) into pallets from (
        select g.producto_id, sum(a.quantity) boxes from (
            select new.projection_id projection_id, new.quantity quantity
            union all select projection_id, quantity from public.usa_programacion_fletes where load_id = new.load_id and id <> new.id
        ) a join public.proyecciones_estrategicas g on g.id = a.projection_id group by g.producto_id
    ) t join public.usa_productos p on p.id = t.producto_id;
    if pallets > cap then raise exception 'La carga supera la capacidad de la unidad.'; end if;
    return new;
end $$;
create trigger validate_consolidated_capacity before insert or update on public.usa_programacion_fletes for each row execute function public.validate_consolidated_capacity();

commit;
