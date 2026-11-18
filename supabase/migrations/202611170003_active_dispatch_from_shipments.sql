-- Run after 202611170002_consolidated_shipments.sql. No historical trips are activated automatically.
begin;
do $$ begin
    if to_regprocedure('public.registrar_embarque_consolidado(uuid,text,uuid[],jsonb,jsonb)') is null then
        raise exception 'Aplica primero 202611170002_consolidated_shipments.sql.';
    end if;
end $$;

alter table public.usa_shipment_reports
    add column if not exists source_load_id uuid,
    add column if not exists source_shipment_ids uuid[] not null default '{}',
    add column if not exists project_ids uuid[] not null default '{}',
    add column if not exists source_manifest jsonb not null default '[]',
    add column if not exists route_plan jsonb,
    add column if not exists source_audit jsonb not null default '[]',
    add column if not exists economic_number text,
    add column if not exists trailer_feet text,
    add column if not exists continuous_mode text;
create unique index if not exists usa_dispatch_source_load_unique on public.usa_shipment_reports(source_load_id);
alter table public.usa_embarques
    add column if not exists submission_id uuid,
    add column if not exists submission_payload jsonb,
    add column if not exists dispatch_activation_enabled boolean not null default false;
alter table public.usa_embarques alter column dispatch_activation_enabled set default true;
create unique index if not exists shipment_submission_unique on public.usa_embarques(submission_id);

create or replace function public.dispatch_load_for_shipment(p_shipment uuid)
returns uuid language sql stable security definer set search_path=public as $$
    select coalesce(e.load_id,s.load_id,e.id) from public.usa_embarques e
    left join public.usa_programacion_fletes s on s.id=e.schedule_id where e.id=p_shipment
$$;
revoke all on function public.dispatch_load_for_shipment(uuid) from public,authenticated;

create or replace function public.sync_usa_dispatch(p_load uuid)
returns void language plpgsql security definer set search_path=public as $$
declare
    first_shipment public.usa_embarques; journey jsonb; shipment_ids uuid[];
    projects uuid[]; clients uuid[]; project_names text; manifest jsonb; product_rows jsonb; audit_rows jsonb; boxes numeric;
begin
    -- The unique key also serializes two pickups of the same physical journey.
    perform pg_advisory_xact_lock(hashtextextended('dispatch:'||p_load::text,0));
    if not exists(select 1 from public.usa_shipment_reports where source_load_id=p_load)
       and not exists(select 1 from public.usa_embarques e where e.dispatch_activation_enabled
            and public.dispatch_load_for_shipment(e.id)=p_load) then return; end if;
    select * into first_shipment from public.usa_embarques e
    where public.dispatch_load_for_shipment(e.id)=p_load and lower(trim(coalesce(e.estatus_embarque,'')))<>'cancelado'
      and exists(select 1 from public.usa_embarques_detalle d where d.embarque_id=e.id)
    order by e.fecha_embarque,e.id limit 1;
    if not found then
        update public.usa_shipment_reports set logistic_status='Cancelado',products='[]',total_real_boxes=0,
            source_manifest='[]',updated_at=now() where source_load_id=p_load and lower(trim(coalesce(logistic_status,'')))<>'finalizado';
        return;
    end if;
    select plan into journey from public.usa_viajes_planeados where id=p_load;
    select array_agg(e.id order by e.fecha_embarque,e.id),jsonb_agg(jsonb_build_object(
        'shipmentId',e.id,'status',e.estatus_embarque,'inspectionPending',e.alerta_inspeccion_pt,'differences',e.diferencias_auditoria))
    into shipment_ids,audit_rows from public.usa_embarques e
    where public.dispatch_load_for_shipment(e.id)=p_load and lower(trim(coalesce(e.estatus_embarque,'')))<>'cancelado'
      and exists(select 1 from public.usa_embarques_detalle d where d.embarque_id=e.id);
    select array_agg(distinct d.proyecto_id) filter(where d.proyecto_id is not null),
        array_agg(distinct d.client_id) filter(where d.client_id is not null),
        sum(d.cantidad_cajas),jsonb_agg(to_jsonb(d)||jsonb_build_object('pickupStopId',e.pickup_stop_id,'departureAt',e.fecha_embarque))
    into projects,clients,boxes,manifest from public.usa_embarques_detalle d join public.usa_embarques e on e.id=d.embarque_id
    where d.embarque_id=any(shipment_ids);
    select string_agg(nombre,' / ' order by nombre) into project_names from public.usa_proyectos where id=any(projects);
    select jsonb_agg(row_data order by row_data->>'projectionId',row_data->>'productId') into product_rows from (
        select jsonb_build_object('productId',d.producto_id,'projectId',d.proyecto_id,'clientId',d.client_id,
            'projectionId',d.proyeccion_id,'realQty',sum(d.cantidad_cajas),'projectedQty',coalesce(max(s.quantity),sum(d.cantidad_cajas)),
            'mid',string_agg(distinct d.mid,', '),'remision',string_agg(distinct d.remision,', ')) as row_data
        from public.usa_embarques_detalle d left join public.usa_programacion_fletes s on s.id=d.schedule_id
        where d.embarque_id=any(shipment_ids) group by d.producto_id,d.proyecto_id,d.client_id,d.proyeccion_id
    ) grouped;
    insert into public.usa_shipment_reports(source_load_id,source_shipment_ids,source_manifest,route_plan,source_audit,
        trip_id,project,project_id,project_ids,client_id,client_ids,is_consolidated,products,total_real_boxes,
        departure_date_time,real_departure_date,linea_transportista_id,driver_name,tractor_plates,box_number,unit_type,
        temperature,ideal_temp,thermograph_serial,economic_number,trailer_feet,continuous_mode,logistic_status)
    values(p_load,shipment_ids,manifest,journey,audit_rows,'VIAJE-'||upper(p_load::text),project_names,
        case when cardinality(projects)=1 then projects[1] end,coalesce(projects,'{}'),
        case when cardinality(clients)=1 then clients[1] end,coalesce(clients,'{}'),
        cardinality(projects)>1 or cardinality(clients)>1 or jsonb_array_length(product_rows)>1,product_rows,boxes,
        first_shipment.fecha_embarque at time zone 'America/Mexico_City',first_shipment.fecha_embarque at time zone 'America/Mexico_City',
        first_shipment.carrier_id,first_shipment.nombre_operador,first_shipment.placas_tractor,first_shipment.placas_caja,
        coalesce(journey->'equipment'->>'name',(select unit_label from public.usa_programacion_fletes where id=first_shipment.schedule_id)),
        first_shipment.temperatura_viaje::text,first_shipment.temperatura_viaje,first_shipment.termografo,
        first_shipment.economico,first_shipment.pies,first_shipment.termo_continuo,'En ruta')
    on conflict(source_load_id) do update set
        source_shipment_ids=excluded.source_shipment_ids,source_manifest=excluded.source_manifest,route_plan=excluded.route_plan,
        source_audit=excluded.source_audit,project=excluded.project,project_id=excluded.project_id,project_ids=excluded.project_ids,
        client_id=excluded.client_id,client_ids=excluded.client_ids,is_consolidated=excluded.is_consolidated,
        products=excluded.products,total_real_boxes=excluded.total_real_boxes,
        departure_date_time=excluded.departure_date_time,real_departure_date=excluded.real_departure_date,
        linea_transportista_id=excluded.linea_transportista_id,driver_name=excluded.driver_name,
        tractor_plates=excluded.tractor_plates,box_number=excluded.box_number,unit_type=excluded.unit_type,
        temperature=excluded.temperature,ideal_temp=excluded.ideal_temp,thermograph_serial=excluded.thermograph_serial,
        economic_number=excluded.economic_number,trailer_feet=excluded.trailer_feet,continuous_mode=excluded.continuous_mode,updated_at=now();
    -- Follow-up status, Tive ID, incidents, costs and closing/payment data are never reset by cargo synchronization.
end $$;
revoke all on function public.sync_usa_dispatch(uuid) from public,authenticated;

create or replace function public.refresh_dispatch_from_source()
returns trigger language plpgsql security definer set search_path=public as $$
declare old_load uuid; new_load uuid;
begin
    if tg_table_name='usa_viajes_planeados' then
        if exists(select 1 from public.usa_shipment_reports where source_load_id=new.id) then perform public.sync_usa_dispatch(new.id); end if;
    elsif tg_table_name='usa_embarques' then
        if old.load_id is distinct from new.load_id or old.schedule_id is distinct from new.schedule_id then
            raise exception 'No se puede reasignar una salida registrada a otro viaje.';
        end if;
        perform public.sync_usa_dispatch(public.dispatch_load_for_shipment(new.id));
    else
        if tg_op<>'INSERT' then old_load:=public.dispatch_load_for_shipment(old.embarque_id); end if;
        if tg_op<>'DELETE' then new_load:=public.dispatch_load_for_shipment(new.embarque_id); end if;
        if tg_op='INSERT' and exists(select 1 from public.usa_shipment_reports where source_load_id=new_load
            and lower(trim(logistic_status)) in ('finalizado','cancelado')) then
            raise exception 'El despacho está cerrado. Tráfico debe revisarlo antes de registrar otra carga.';
        end if;
        if old_load is not null then perform public.sync_usa_dispatch(old_load); end if;
        if new_load is not null and new_load is distinct from old_load then perform public.sync_usa_dispatch(new_load); end if;
    end if;
    return null;
end $$;
revoke all on function public.refresh_dispatch_from_source() from public,authenticated;
drop trigger if exists dispatch_from_details on public.usa_embarques_detalle;
create trigger dispatch_from_details after insert or update or delete on public.usa_embarques_detalle
for each row execute function public.refresh_dispatch_from_source();
drop trigger if exists dispatch_from_header on public.usa_embarques;
create trigger dispatch_from_header after update on public.usa_embarques for each row execute function public.refresh_dispatch_from_source();
drop trigger if exists dispatch_route_update on public.usa_viajes_planeados;
create trigger dispatch_route_update after update of plan on public.usa_viajes_planeados for each row execute function public.refresh_dispatch_from_source();

create or replace function public.protect_automatic_dispatch()
returns trigger language plpgsql set search_path=public as $$
begin
    -- Only the table owner (the internal synchronizer and SQL maintenance) writes source data.
    if current_user=pg_get_userbyid((select relowner from pg_class where oid='public.usa_shipment_reports'::regclass)) then
        if tg_op='DELETE' then return old; else return new; end if;
    end if;
    if tg_op='INSERT' and new.source_load_id is not null then raise exception 'El despacho se crea desde la salida de Embarques.'; end if;
    if tg_op='INSERT' and upper(coalesce(auth.jwt()->'app_metadata'->>'role',''))='TRAFICO_RI' then raise exception 'Tráfico debe activar el despacho desde Embarques.'; end if;
    if (tg_op='DELETE' and old.source_load_id is not null) then raise exception 'El despacho tiene salidas vinculadas; utiliza el estatus de cancelación.'; end if;
    if tg_op='UPDATE' and (old.source_load_id is not null or new.source_load_id is not null) then
        if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in
            ('TRAFICO_RI','ADMINISTRADOR','COORDINADOR','SUBGERENCIA','ADMINISTRATIVO','GERENCIA') then raise exception 'Tu rol no puede modificar el despacho.'; end if;
        if (to_jsonb(new)-array['logistic_status','driver_phone','seal_number','responsible_id','caat','alpha','transfer_agent','transfer_phone',
            'freight_cost','tive_tracker_id','comments','expected_arrival','arrival_date_time','arrived_at_stop_over','departed_from_stop_over',
            'incidents','current_temp','temp_status','tracking_link','location_history','temperature_history','last_known_eta','has_thermal_excursion',
            'carrier_rating','carrier_rating_comments','rating_pending','extra_costs','fines','freight_payer','reviewer_id','passed_to_payment',
            'passed_to_payment_date','invoice_received','invoice_received_date','carrier_invoice_number','fiscal_folio','freight_in_portfolio',
            'payment_status','invoice_number','invoice_url','requires_comp_services','requires_customs_services','updated_at'])
        is distinct from (to_jsonb(old)-array['logistic_status','driver_phone','seal_number','responsible_id','caat','alpha','transfer_agent','transfer_phone',
            'freight_cost','tive_tracker_id','comments','expected_arrival','arrival_date_time','arrived_at_stop_over','departed_from_stop_over',
            'incidents','current_temp','temp_status','tracking_link','location_history','temperature_history','last_known_eta','has_thermal_excursion',
            'carrier_rating','carrier_rating_comments','rating_pending','extra_costs','fines','freight_payer','reviewer_id','passed_to_payment',
            'passed_to_payment_date','invoice_received','invoice_received_date','carrier_invoice_number','fiscal_folio','freight_in_portfolio',
            'payment_status','invoice_number','invoice_url','requires_comp_services','requires_customs_services','updated_at']) then
            raise exception 'Los datos de carga y transporte se corrigen desde Programación o Embarques.';
        end if;
    end if;
    if tg_op='DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists protect_automatic_dispatch on public.usa_shipment_reports;
create trigger protect_automatic_dispatch before insert or update or delete on public.usa_shipment_reports
for each row execute function public.protect_automatic_dispatch();

-- Repeated submission of the same physical capture returns the original shipment.
do $$ begin
    if to_regprocedure('public.registrar_embarque_consolidado_base(uuid,text,uuid[],jsonb,jsonb)') is null then
        alter function public.registrar_embarque_consolidado(uuid,text,uuid[],jsonb,jsonb) rename to registrar_embarque_consolidado_base;
    end if;
end $$;
revoke all on function public.registrar_embarque_consolidado_base(uuid,text,uuid[],jsonb,jsonb) from public,authenticated;
create or replace function public.registrar_embarque_consolidado(p_load_id uuid,p_stop_id text,p_schedule_ids uuid[],p_header jsonb,p_details jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare token uuid:=nullif(p_header->>'submission_id','')::uuid; existing public.usa_embarques; shipment uuid; fingerprint jsonb;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in
        ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR','ADMINISTRATIVO') then raise exception 'Tu rol no puede registrar embarques.'; end if;
    fingerprint:=jsonb_build_object('load',p_load_id,'stop',p_stop_id,'schedules',to_jsonb(p_schedule_ids),'header',p_header-'folio_embarque','details',p_details);
    if token is not null then
        perform pg_advisory_xact_lock(hashtextextended('shipment:'||token::text,0));
        select * into existing from public.usa_embarques where submission_id=token;
        if found then
            if existing.submission_payload is distinct from fingerprint then raise exception 'Esta captura ya fue enviada con otros datos. Actualiza antes de continuar.'; end if;
            return existing.id;
        end if;
    end if;
    shipment:=public.registrar_embarque_consolidado_base(p_load_id,p_stop_id,p_schedule_ids,p_header,p_details);
    update public.usa_embarques set submission_id=token,submission_payload=fingerprint where id=shipment;
    return shipment;
end $$;
revoke all on function public.registrar_embarque_consolidado(uuid,text,uuid[],jsonb,jsonb) from public;
grant execute on function public.registrar_embarque_consolidado(uuid,text,uuid[],jsonb,jsonb) to authenticated;
commit;
