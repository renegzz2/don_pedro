begin;

-- Historical comparison uses actual departures in the selected ISO week/year.
-- Annual manual references and client receipts do not represent weekly shipments.
create or replace function public.planning_weekly_history(p_year integer, p_week integer)
returns table(proyecto_id uuid, producto_id uuid, client_id uuid, projection_id uuid, anio integer, concepto text, cajas numeric)
language plpgsql stable security definer set search_path = public as $$
declare week_start timestamp;
begin
    if auth.uid() is null then return; end if;
    if p_year is null or p_year not between 2000 and 2200 or p_week is null or p_week not between 1 and 53 then
        raise exception 'Selecciona un año y una semana válidos.';
    end if;
    week_start := date_trunc('week', make_date(p_year, 1, 4)::timestamp) + (p_week - 1) * interval '7 days';
    return query
    with departures as (
        select coalesce(d.proyecto_id, g.proyecto_id) as project_id,
               d.producto_id as product_id,
               coalesce(d.client_id, g.client_id) as customer_id,
               d.cantidad_cajas as quantity
        from public.usa_embarques e
        join public.usa_embarques_detalle d on d.embarque_id = e.id
        left join public.usa_programacion_fletes s on s.id = e.schedule_id
        left join public.proyecciones_estrategicas g on g.id = s.projection_id
        where e.fecha_embarque >= week_start and e.fecha_embarque < week_start + interval '7 days'
          and extract(isoyear from e.fecha_embarque)::integer = p_year
          and upper(trim(coalesce(e.estatus_embarque, ''))) not in ('CANCELADO', 'CANCELADA')
          and coalesce(d.proyecto_id, g.proyecto_id) is not null
          and d.producto_id is not null
    )
    select dep.project_id, dep.product_id, null::uuid, null::uuid, p_year, 'ng_semana'::text, sum(dep.quantity)
    from departures dep group by dep.project_id, dep.product_id
    union all
    select dep.project_id, dep.product_id, dep.customer_id, null::uuid, p_year, 'cliente_enviado_semana'::text, sum(dep.quantity)
    from departures dep where dep.customer_id is not null
    group by dep.project_id, dep.product_id, dep.customer_id;
end $$;

revoke all on function public.planning_weekly_history(integer, integer) from public;
grant execute on function public.planning_weekly_history(integer, integer) to authenticated;

commit;
