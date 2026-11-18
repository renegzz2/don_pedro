-- Comercial -> Tráfico -> Jefe -> Embarques. Apply before deploying the UI.
begin;

alter table public.proyecciones_estrategicas add column if not exists planning_year integer;
update public.proyecciones_estrategicas
set planning_year = extract(isoyear from coalesce(created_at, now()))::integer
where planning_year is null;
alter table public.proyecciones_estrategicas alter column planning_year set default extract(isoyear from now())::integer;
alter table public.proyecciones_estrategicas alter column planning_year set not null;

create table if not exists public.usa_programacion_fletes (
    id uuid primary key default gen_random_uuid(),
    projection_id uuid not null references public.proyecciones_estrategicas(id) on delete restrict,
    scheduled_date date not null,
    arrival_at timestamptz not null,
    carrier_id uuid not null references public.usa_lineas_transporte(id),
    quantity integer not null check (quantity > 0),
    unit_label text not null check (length(trim(unit_label)) > 0),
    notes text not null default '',
    created_at timestamptz not null default now()
);
create index if not exists usa_fletes_projection_date on public.usa_programacion_fletes(projection_id, scheduled_date);
alter table public.usa_programacion_fletes enable row level security;
create policy "Authenticated planning read" on public.usa_programacion_fletes for select to authenticated using (true);
create policy "Traffic planning insert" on public.usa_programacion_fletes for insert to authenticated with check (
    upper(coalesce(auth.jwt()->'app_metadata'->>'role', ''))
    in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR')
);
create policy "Traffic planning update" on public.usa_programacion_fletes for update to authenticated using (
    upper(coalesce(auth.jwt()->'app_metadata'->>'role', ''))
    in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR')
) with check (
    upper(coalesce(auth.jwt()->'app_metadata'->>'role', ''))
    in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR')
);
create policy "Traffic planning delete" on public.usa_programacion_fletes for delete to authenticated using (
    upper(coalesce(auth.jwt()->'app_metadata'->>'role', ''))
    in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR')
);
grant select, insert, update, delete on public.usa_programacion_fletes to authenticated;

alter table public.usa_embarques
    add column if not exists schedule_id uuid references public.usa_programacion_fletes(id),
    add column if not exists client_id uuid references public.usa_clientes(id),
    add column if not exists carrier_id uuid references public.usa_lineas_transporte(id),
    add column if not exists economico text,
    add column if not exists pies text,
    add column if not exists termografo text,
    add column if not exists termo_continuo text;
alter table public.usa_embarques_detalle add column if not exists numero_pallet text;

-- Tráfico necesita ver los embarques vinculados para que el
-- trigger impida modificar o eliminar un flete utilizado.
grant select on public.usa_embarques to authenticated;

alter table public.usa_embarques enable row level security;

create policy "Traffic shipment read"
on public.usa_embarques
for select
to authenticated
using (
    upper(coalesce(
        auth.jwt()->'app_metadata'->>'role',
        ''
    )) in (
        'GERENCIA',
        'SUBGERENCIA',
        'COORDINADOR',
        'DIRECCION',
        'SUBDIRECCION',
        'ADMINISTRADOR'
    )
);
-- Serialize writes on the parent goal so two dispatchers cannot exceed its quantity.
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
    if jsonb_array_length(coalesce(goal.desglose_diario::jsonb, '[]'::jsonb)) > 0 then
        select coalesce(sum((item->>'cantidad')::numeric), 0) into daily_quantity
        from jsonb_array_elements(goal.desglose_diario::jsonb) item
        where left(item->>'fecha', 10) = new.scheduled_date::text;
    elsif coalesce(goal.lunes,0)+coalesce(goal.martes,0)+coalesce(goal.miercoles,0)+coalesce(goal.jueves,0)+coalesce(goal.viernes,0)+coalesce(goal.sabado,0)+coalesce(goal.domingo,0) > 0 then
        daily_quantity := case extract(isodow from new.scheduled_date)
            when 1 then goal.lunes when 2 then goal.martes when 3 then goal.miercoles
            when 4 then goal.jueves when 5 then goal.viernes when 6 then goal.sabado else goal.domingo end;
    elsif goal.fecha_salida::date = new.scheduled_date then daily_quantity := goal.proyeccion_cajas;
    end if;
    select coalesce(sum(quantity), 0) into booked from public.usa_programacion_fletes
    where projection_id = new.projection_id and scheduled_date = new.scheduled_date and id <> new.id;
    if new.quantity + booked > coalesce(daily_quantity, 0) then
        raise exception 'Los fletes superan las cajas solicitadas por Comercial para ese día.';
    end if;
    return new;
end $$;
create trigger validate_commercial_freight before insert or update or delete on public.usa_programacion_fletes
for each row execute function public.validate_commercial_freight();

-- Preserve the commercial request once Traffic has allocated trucks to it.
create or replace function public.protect_scheduled_commercial_goal() returns trigger
language plpgsql set search_path = public as $$
begin
    if exists(select 1 from public.usa_programacion_fletes where projection_id = old.id)
       and (new.proyecto_id, new.producto_id, new.client_id, new.semana_fiscal, new.planning_year,
            new.proyeccion_cajas, new.desglose_diario, new.fecha_salida,
            new.lunes, new.martes, new.miercoles, new.jueves, new.viernes, new.sabado, new.domingo)
       is distinct from
           (old.proyecto_id, old.producto_id, old.client_id, old.semana_fiscal, old.planning_year,
            old.proyeccion_cajas, old.desglose_diario, old.fecha_salida,
            old.lunes, old.martes, old.miercoles, old.jueves, old.viernes, old.sabado, old.domingo) then
        raise exception 'La meta tiene fletes programados. Tráfico debe retirarlos antes de cambiar cliente, producto o cantidades.';
    end if;
    return new;
end $$;
create trigger protect_scheduled_commercial_goal before update on public.proyecciones_estrategicas
for each row execute function public.protect_scheduled_commercial_goal();

-- Store the header and pallets atomically; failed detail inserts must not leave an orphan shipment.
create or replace function public.registrar_embarque_programado(p_schedule_id uuid, p_header jsonb, p_details jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
    freight public.usa_programacion_fletes;
    goal public.proyecciones_estrategicas;
    shipment_id uuid := gen_random_uuid();
    real_departure timestamp := (p_header->>'fecha_embarque')::timestamp;
    requested numeric;
    shipped numeric;
begin
    -- Embarques may lock a freight without receiving Tráfico's UPDATE permission.
    -- The function owner performs the transaction only for roles with shipment access.
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role', ''))
        not in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR','ADMINISTRATIVO') then
        raise exception 'Tu rol no puede registrar embarques.';
    end if;
    select * into freight from public.usa_programacion_fletes where id = p_schedule_id for update;
    if not found then raise exception 'El flete programado ya no está disponible.'; end if;
    select * into goal from public.proyecciones_estrategicas where id = freight.projection_id;
    if goal.client_id is null or real_departure is null or real_departure::date <> freight.scheduled_date then
        raise exception 'El cliente o el día real de salida no coincide con el flete programado.';
    end if;
    if real_departure > (now() at time zone 'America/Mexico_City') + interval '5 minutes' then
        raise exception 'La salida real no puede ser una fecha futura.';
    end if;
    if jsonb_array_length(p_details) = 0 then raise exception 'Captura al menos una tarima.'; end if;
    if exists(select 1 from jsonb_array_elements(p_details) d
              where (d->>'producto_id')::uuid is distinct from goal.producto_id
                 or coalesce((d->>'cantidad_cajas')::numeric, 0) <= 0) then
        raise exception 'Las tarimas deben corresponder al producto solicitado y tener cajas positivas.';
    end if;
    select sum((d->>'cantidad_cajas')::numeric) into requested from jsonb_array_elements(p_details) d;
    select coalesce(sum(d.cantidad_cajas),0) into shipped from public.usa_embarques_detalle d
    join public.usa_embarques e on e.id = d.embarque_id where e.schedule_id = freight.id;
    if shipped + requested > freight.quantity then raise exception 'Las cajas superan la cantidad del flete programado.'; end if;
    insert into public.usa_embarques(id, fecha_embarque, folio_embarque, schedule_id, client_id, carrier_id,
        linea_transporte, nombre_operador, placas_caja, placas_tractor, temperatura_viaje, destino,
        economico, pies, termografo, termo_continuo, estatus_embarque, alerta_inspeccion_pt,
        diferencias_auditoria, foto_remision, foto_termografo, foto_diesel, foto_refacciones, foto_temperatura)
    values (shipment_id, real_departure, p_header->>'folio_embarque', freight.id, goal.client_id, freight.carrier_id,
        (select nombre from public.usa_lineas_transporte where id = freight.carrier_id),
        p_header->>'nombre_operador', p_header->>'placas_caja', p_header->>'placas_tractor',
        (p_header->>'temperatura_viaje')::numeric, (select nombre from public.usa_clientes where id = goal.client_id),
        p_header->>'economico', p_header->>'pies', p_header->>'termografo', p_header->>'termo_continuo',
        'EN REVISIÓN RI', (p_header->>'alerta_inspeccion_pt')::boolean, p_header->'diferencias_auditoria',
        p_header->>'foto_remision', p_header->>'foto_termografo', p_header->>'foto_diesel',
        p_header->>'foto_refacciones', p_header->>'foto_temperatura');
    insert into public.usa_embarques_detalle(embarque_id, numero_pallet, producto_id, remision, mid, lote_pt, cantidad_cajas)
    select shipment_id, d->>'numero_pallet', (d->>'producto_id')::uuid, d->>'remision', d->>'mid', d->>'lote_pt',
        (d->>'cantidad_cajas')::numeric from jsonb_array_elements(p_details) d;
    return shipment_id;
end $$;
revoke all on function public.registrar_embarque_programado(uuid,jsonb,jsonb) from public;
grant execute on function public.registrar_embarque_programado(uuid,jsonb,jsonb) to authenticated;

commit;
