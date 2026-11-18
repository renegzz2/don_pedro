begin;
alter table public.usa_clientes add column if not exists activo boolean not null default true;
alter table public.usa_productos add column if not exists peso_incluye_empaque boolean;
alter table public.usa_productos add column if not exists empaque_kg numeric check (empaque_kg >= 0);
alter table public.tipo_unidad
    add column if not exists carga_util_lb numeric check (carga_util_lb > 0),
    add column if not exists peso_bruto_max_lb numeric check (peso_bruto_max_lb > 0),
    add column if not exists refrigerada boolean not null default false,
    add column if not exists temperatura_min_f numeric,
    add column if not exists temperatura_max_f numeric,
    add column if not exists tara_pallet_kg numeric check (tara_pallet_kg >= 0),
    add column if not exists longitud_interior_m numeric,
    add column if not exists perno_rey_m numeric,
    add column if not exists tandem_caja_m numeric,
    add column if not exists quinta_rueda_m numeric,
    add column if not exists distancia_ejes_tractor_m numeric,
    add column if not exists pesos_vacios_ejes_lb jsonb,
    add column if not exists limites_ejes_lb jsonb;


alter table public.usa_embarques_detalle
    add column if not exists proyecto_id uuid references public.usa_proyectos(id),
    add column if not exists client_id uuid references public.usa_clientes(id),
    add column if not exists proyeccion_id uuid references public.proyecciones_estrategicas(id),
    add column if not exists attribution_reference text;
update public.usa_embarques_detalle d set proyecto_id=g.proyecto_id,client_id=g.client_id,proyeccion_id=g.id,attribution_reference='Flete vinculado'
from public.usa_embarques e join public.usa_programacion_fletes s on s.id=e.schedule_id join public.proyecciones_estrategicas g on g.id=s.projection_id
where d.embarque_id=e.id and d.proyecto_id is null;
create or replace function public.attribute_scheduled_shipment_detail() returns trigger language plpgsql set search_path=public as $$
declare g public.proyecciones_estrategicas;
begin
    select pe.* into g from public.usa_embarques e join public.usa_programacion_fletes s on s.id=e.schedule_id join public.proyecciones_estrategicas pe on pe.id=s.projection_id where e.id=new.embarque_id;
    if found then new.proyecto_id:=g.proyecto_id;new.client_id:=g.client_id;new.proyeccion_id:=g.id;new.attribution_reference:='Flete vinculado';end if;
    return new;
end $$;
create trigger attribute_shipment_detail before insert or update on public.usa_embarques_detalle for each row execute function public.attribute_scheduled_shipment_detail();

-- Facts have a year and source. Legacy SS price/reference fields are intentionally not imported.
create table public.usa_historico_cajas (
    id uuid primary key default gen_random_uuid(),
    proyecto_id uuid not null references public.usa_proyectos(id),
    producto_id uuid not null references public.usa_productos(id),
    client_id uuid references public.usa_clientes(id),
    anio integer not null check (anio between 2000 and 2200),
    concepto text not null check (concepto in ('ng_enviado','cliente_recibido')),
    cajas integer not null check (cajas >= 0),
    referencia text not null check (length(trim(referencia)) > 0),
    created_at timestamptz not null default now(),
    check ((concepto = 'cliente_recibido' and client_id is not null) or (concepto = 'ng_enviado' and client_id is null))
);
create unique index historico_ng_unique on public.usa_historico_cajas(proyecto_id, producto_id, anio) where concepto = 'ng_enviado';
create unique index historico_cliente_unique on public.usa_historico_cajas(proyecto_id, producto_id, client_id, anio) where concepto = 'cliente_recibido';
alter table public.usa_historico_cajas enable row level security;
create policy historico_read on public.usa_historico_cajas for select to authenticated using (true);
create policy historico_write on public.usa_historico_cajas for all to authenticated using (upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) in ('COMERCIAL','DIRECCION','SUBDIRECCION','ADMINISTRADOR')) with check (upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) in ('COMERCIAL','DIRECCION','SUBDIRECCION','ADMINISTRADOR'));
grant select,insert,update,delete on public.usa_historico_cajas to authenticated;

-- One annual NG reference per product/project, never sum a repeated reference from weekly goals.
insert into public.usa_historico_cajas(proyecto_id,producto_id,anio,concepto,cajas,referencia)
select proyecto_id,producto_id,2025,'ng_enviado',max(ng_2025)::integer,'Referencia NG 2025 heredada: revisar fuente'
from public.proyecciones_estrategicas where ng_2025 > 0 and ng_2025 <= 2147483647 and ng_2025 = trunc(ng_2025)
group by proyecto_id,producto_id having min(ng_2025) = max(ng_2025)
on conflict do nothing;

create or replace function public.planning_box_metrics(p_year integer, p_week integer)
returns table(proyecto_id uuid, producto_id uuid, client_id uuid, projection_id uuid, anio integer, concepto text, cajas numeric)
language sql stable security definer set search_path = public as $$
    select h.proyecto_id,h.producto_id,h.client_id,null::uuid,h.anio,h.concepto,h.cajas::numeric
    from public.usa_historico_cajas h where auth.uid() is not null and h.anio = p_year - 1
    union all
    select g.proyecto_id,d.producto_id,e.client_id,null::uuid,p_year,'enviado_anual',sum(d.cantidad_cajas)
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id
    join public.usa_programacion_fletes s on s.id=e.schedule_id join public.proyecciones_estrategicas g on g.id=s.projection_id
    where auth.uid() is not null and extract(year from e.fecha_embarque)=p_year
    group by g.proyecto_id,d.producto_id,e.client_id
    union all
    select g.proyecto_id,d.producto_id,e.client_id,g.id,p_year,'real_meta',sum(d.cantidad_cajas)
    from public.usa_embarques e join public.usa_embarques_detalle d on d.embarque_id=e.id
    join public.usa_programacion_fletes s on s.id=e.schedule_id join public.proyecciones_estrategicas g on g.id=s.projection_id
    where auth.uid() is not null and g.planning_year=p_year and g.semana_fiscal=p_week
    group by g.proyecto_id,d.producto_id,e.client_id,g.id;
$$;
revoke all on function public.planning_box_metrics(integer,integer) from public;
grant execute on function public.planning_box_metrics(integer,integer) to authenticated;
commit;
