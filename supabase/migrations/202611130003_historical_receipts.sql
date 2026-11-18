begin;
create or replace function public.planning_box_metrics(p_year integer,p_week integer)
returns table(proyecto_id uuid,producto_id uuid,client_id uuid,projection_id uuid,anio integer,concepto text,cajas numeric)
language sql stable security definer set search_path=public as $$
    select h.proyecto_id,h.producto_id,h.client_id,null::uuid,h.anio,h.concepto,h.cajas::numeric
    from public.usa_historico_cajas h where auth.uid() is not null and h.anio=p_year-1
    union all
    select d.proyecto_id,d.producto_id,d.client_id,null::uuid,p_year,'enviado_anual',sum(d.cantidad_cajas)
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id
    where auth.uid() is not null and extract(year from e.fecha_embarque)=p_year and d.proyecto_id is not null and d.client_id is not null and upper(coalesce(e.estatus_embarque,'')) not in ('CANCELADO','CANCELADA')
    group by d.proyecto_id,d.producto_id,d.client_id
    union all
    select d.proyecto_id,d.producto_id,d.client_id,g.id,p_year,'real_meta',sum(d.cantidad_cajas)
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id join public.proyecciones_estrategicas g on g.id=d.proyeccion_id
    where auth.uid() is not null and g.planning_year=p_year and g.semana_fiscal=p_week and upper(coalesce(e.estatus_embarque,'')) not in ('CANCELADO','CANCELADA')
    group by d.proyecto_id,d.producto_id,d.client_id,g.id
    union all
    select r.proyecto_id,r.producto_id,r.client_id,null::uuid,p_year-1,'cliente_recibido',sum(r.cajas)::numeric
    from public.usa_recepciones_cliente r where auth.uid() is not null and extract(year from r.received_at at time zone 'America/Mexico_City')=p_year-1
    and not exists(select 1 from public.usa_historico_cajas h where h.proyecto_id=r.proyecto_id and h.producto_id=r.producto_id and h.client_id=r.client_id and h.anio=p_year-1 and h.concepto='cliente_recibido')
    group by r.proyecto_id,r.producto_id,r.client_id
    union all
    select d.proyecto_id,d.producto_id,null::uuid,null::uuid,p_year-1,'ng_enviado',sum(d.cantidad_cajas)
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id
    where auth.uid() is not null and extract(year from e.fecha_embarque)=p_year-1 and d.proyecto_id is not null and upper(coalesce(e.estatus_embarque,'')) not in ('CANCELADO','CANCELADA')
    and not exists(select 1 from public.usa_historico_cajas h where h.proyecto_id=d.proyecto_id and h.producto_id=d.producto_id and h.anio=p_year-1 and h.concepto='ng_enviado')
    group by d.proyecto_id,d.producto_id
    union all
    select null::uuid,null::uuid,null::uuid,null::uuid,p_year,'sin_atribuir',coalesce(sum(d.cantidad_cajas),0)
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id
    where auth.uid() is not null and extract(year from e.fecha_embarque)=p_year and (d.proyecto_id is null or d.client_id is null) and upper(coalesce(e.estatus_embarque,'')) not in ('CANCELADO','CANCELADA');
$$;

create or replace function public.planning_unattributed_shipments(p_year integer)
returns table(id uuid,fecha timestamp,folio text,producto_id uuid,cajas numeric)
language sql stable security definer set search_path=public as $$
    select d.id,e.fecha_embarque,e.folio_embarque,d.producto_id,d.cantidad_cajas
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id
    where auth.uid() is not null and extract(year from e.fecha_embarque) in (p_year,p_year-1) and (d.proyecto_id is null or d.client_id is null) and upper(coalesce(e.estatus_embarque,'')) not in ('CANCELADO','CANCELADA')
    order by e.fecha_embarque,d.id limit 100;
$$;
create or replace function public.attribute_legacy_shipment(p_detail uuid,p_project uuid,p_client uuid,p_projection uuid,p_reference text)
returns void language plpgsql security definer set search_path=public as $$
declare d public.usa_embarques_detalle;g public.proyecciones_estrategicas;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('COMERCIAL','GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede conciliar embarques.';end if;
    select * into d from public.usa_embarques_detalle where id=p_detail for update;
    if not found or (d.proyecto_id is not null and d.client_id is not null) then raise exception 'El detalle ya fue conciliado o no existe.';end if;
    if coalesce(trim(p_reference),'')='' or p_project is null or p_client is null then raise exception 'Selecciona proyecto, cliente y fuente documental.';end if;
    if p_projection is not null then
        select * into g from public.proyecciones_estrategicas where id=p_projection;
        if not found or g.proyecto_id<>p_project or g.producto_id<>d.producto_id or g.client_id<>p_client then raise exception 'La meta no corresponde al detalle.';end if;
    end if;
    update public.usa_embarques_detalle set proyecto_id=p_project,client_id=p_client,proyeccion_id=p_projection,attribution_reference=p_reference where id=p_detail;
end $$;
revoke all on function public.planning_unattributed_shipments(integer) from public;
revoke all on function public.attribute_legacy_shipment(uuid,uuid,uuid,uuid,text) from public;
grant execute on function public.planning_unattributed_shipments(integer) to authenticated;
grant execute on function public.attribute_legacy_shipment(uuid,uuid,uuid,uuid,text) to authenticated;
commit;
