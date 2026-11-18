begin;
create table public.usa_solicitudes_insumos (
    id uuid primary key default gen_random_uuid(), project_id uuid not null references public.usa_proyectos(id),
    supplier text not null check(length(trim(supplier))>0), address text not null check(length(trim(address))>0),
    description text not null check(length(trim(description))>0), pallets integer not null check(pallets>0),
    weight_kg numeric not null check(weight_kg>0), requested_date date not null,
    reference text not null check(length(trim(reference))>0), status text not null default 'pendiente' check(status in ('pendiente','asignada','entregada')),
    created_by uuid not null default auth.uid(), created_at timestamptz not null default now()
);
create table public.usa_viajes_planeados (
    id uuid primary key default gen_random_uuid(), revision integer not null default 1,
    scheduled_date date not null, completed_at timestamptz, plan jsonb not null, created_by uuid not null default auth.uid(),
    created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index viajes_fecha on public.usa_viajes_planeados(scheduled_date);
create table public.usa_viajes_auditoria (
    id bigint generated always as identity primary key, trip_id uuid not null, actor uuid not null default auth.uid(),
    action text not null, plan jsonb not null, created_at timestamptz not null default now()
);
create table public.usa_recepciones_cliente (
    id uuid primary key default gen_random_uuid(), trip_id uuid not null, cargo_id text not null,
    proyecto_id uuid not null references public.usa_proyectos(id), producto_id uuid not null references public.usa_productos(id),
    client_id uuid not null references public.usa_clientes(id), cajas integer not null check(cajas>=0),
    received_at timestamptz not null default now(), referencia text not null,
    unique(trip_id,cargo_id)
);
do $$ declare t text; begin
    foreach t in array array['usa_solicitudes_insumos','usa_viajes_planeados','usa_viajes_auditoria','usa_recepciones_cliente'] loop
        execute format('alter table public.%I enable row level security',t);
        execute format('create policy read_authenticated on public.%I for select to authenticated using (true)',t);
        execute format('grant select on public.%I to authenticated',t);
    end loop;
end $$;
create policy compras_insert on public.usa_solicitudes_insumos for insert to authenticated with check (status='pendiente' and created_by=auth.uid() and upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) in ('COMPRAS','DIRECCION','SUBDIRECCION','ADMINISTRADOR'));
grant insert on public.usa_solicitudes_insumos to authenticated;

create or replace function public.transport_at(p_value text) returns timestamptz language sql immutable set search_path=public as $$
    select case when p_value ~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then p_value::timestamptz else p_value::timestamp at time zone 'America/Mexico_City' end;
$$;
-- The server derives weights and temperature limits from the catalog, not from browser totals.
create or replace function public.validate_transport_plan(p_plan jsonb, p_trip uuid)
returns void language plpgsql set search_path=public as $$
declare
    u public.tipo_unidad; p public.usa_productos; g public.proyecciones_estrategicas; req public.usa_solicitudes_insumos;
    e jsonb:=p_plan->'equipment'; c jsonb; s jsonb; other jsonb; pallet jsonb; positions jsonb; items jsonb:='[]';
    n integer; idx integer; li integer; ui integer; j integer; pos integer; boxes integer; qty numeric;
    kg numeric; part numeric; bpp integer; lo numeric; hi numeric; lower_f numeric; upper_f numeric;
    capacity integer; payload numeric; total_lb numeric; empty_lb numeric; gross numeric;
    rear numeric; king numeric; drive numeric; front numeric; x numeric; axle jsonb;
    day date; planned numeric; booked numeric; prev_at timestamptz; has_chilled boolean;
    k numeric; r numeric; l numeric; f numeric; w numeric;
begin
    select * into u from public.tipo_unidad where id=(p_plan->>'unitTypeId')::bigint;
    if not found then raise exception 'El tipo de unidad no existe.'; end if;
    capacity:=floor(substring(u.capacidad from '([0-9]+(?:\.[0-9]+)?)')::numeric);
    if coalesce(capacity,0)<1 or u.carga_util_lb is null or u.peso_bruto_max_lb is null or u.tara_pallet_kg is null then raise exception 'Configura capacidad, carga útil, peso bruto y tara de pallets de la unidad.'; end if;
    if (e->>'capacity')::integer is distinct from capacity or (e->>'payloadLb')::numeric is distinct from u.carga_util_lb or (e->>'grossLb')::numeric is distinct from u.peso_bruto_max_lb or (e->>'palletTareKg')::numeric is distinct from u.tara_pallet_kg then raise exception 'Las capacidades cambiaron. Actualiza el catálogo.'; end if;
    if jsonb_typeof(p_plan->'stops') is distinct from 'array' or jsonb_array_length(p_plan->'stops')<2 or jsonb_typeof(p_plan->'cargo') is distinct from 'array' or jsonb_array_length(p_plan->'cargo')=0 then raise exception 'Captura al menos dos paradas y una carga.'; end if;
    if exists(select 1 from jsonb_array_elements(p_plan->'stops') d group by d->>'id' having count(*)>1) or exists(select 1 from jsonb_array_elements(p_plan->'cargo') d group by d->>'id' having count(*)>1) then raise exception 'Los identificadores de paradas y cargas deben ser únicos.'; end if;
    prev_at:=null;
    for s in select value from jsonb_array_elements(p_plan->'stops') loop
        if coalesce(trim(s->>'id'),'')='' or coalesce(trim(s->>'name'),'')='' or coalesce(trim(s->>'address'),'')='' or s->>'at' is null then raise exception 'Completa nombre, dirección y horario de cada parada.'; end if;
        if prev_at is not null and public.transport_at(s->>'at')<prev_at then raise exception 'Los horarios no respetan el recorrido.'; end if;
        prev_at:=public.transport_at(s->>'at');
    end loop;
    if exists(select 1 from jsonb_array_elements(p_plan->'cargo') d where d->>'kind'='product' group by d->>'projectionId' having count(*)>1) then raise exception 'Una meta no puede repetirse dentro del viaje.'; end if;
    for c in select value from jsonb_array_elements(p_plan->'cargo') loop
        if coalesce(trim(c->>'id'),'')='' then raise exception 'Identifica la carga.'; end if;
        select ord::integer-1 into li from jsonb_array_elements(p_plan->'stops') with ordinality t(s,ord) where t.s->>'id'=c->>'loadStopId';
        select ord::integer-1 into ui from jsonb_array_elements(p_plan->'stops') with ordinality t(s,ord) where t.s->>'id'=c->>'unloadStopId';
        if li is null or ui is null or ui<=li then raise exception 'La descarga debe seguir a la recolección.'; end if;
        day:=left(p_plan->'stops'->li->>'at',10)::date;
        lo:=null; hi:=null; boxes:=0; bpp:=0;
        if c->>'kind'='product' then
            select * into g from public.proyecciones_estrategicas where id=(c->>'projectionId')::uuid;
            if not found or (c->>'projectId')::uuid is distinct from g.proyecto_id or (c->>'productId')::uuid is distinct from g.producto_id or (c->>'clientId')::uuid is distinct from g.client_id then raise exception 'La meta, proyecto, producto y cliente no coinciden.'; end if;
            if g.client_id is null then raise exception 'La meta no tiene cliente.'; end if;
            qty:=(c->>'boxes')::numeric;
            if coalesce(qty,0)<=0 or qty<>trunc(qty) then raise exception 'Las cajas deben ser enteras positivas.'; end if;
            boxes:=qty::integer;
            select coalesce(sum((d->>'cantidad')::numeric),0) into planned from jsonb_array_elements(g.packing_plan) d where (d->>'fecha')::date=day;
            select coalesce(sum(quantity),0) into booked from public.usa_programacion_fletes where projection_id=g.id and scheduled_date=day and load_id is distinct from p_trip;
            if booked+boxes>planned then raise exception 'La asignación supera las cajas pendientes de empaque para ese día.'; end if;
            select * into p from public.usa_productos where id=g.producto_id;
            if p.cajas_pallet_usa is null or p.cajas_pallet_usa<=0 or p.peso_usa is null or p.peso_usa<=0 or p.peso_incluye_empaque is null or (not p.peso_incluye_empaque and p.empaque_kg is null) then raise exception 'Confirma cajas por pallet, peso y empaque del producto.'; end if;
            bpp:=p.cajas_pallet_usa; n:=ceil(boxes::numeric/bpp);
            kg:=boxes*(p.peso_usa+case when p.peso_incluye_empaque then 0 else p.empaque_kg end);
            if p.almacenado_frio is distinct from false then
                lo:=nullif(trim(p.limite_tolerable),'')::numeric;hi:=p.limite_superior;
                if lo is null or hi is null or lo>=hi then raise exception 'Límites térmicos inválidos del producto.'; end if;
            end if;
        elsif c->>'kind' in ('special','supplies') then
            qty:=(c->>'pallets')::numeric;
            if coalesce(qty,0)<=0 or qty<>trunc(qty) or coalesce((c->>'weightKg')::numeric,0)<=0 or coalesce(trim(c->>'description'),'')='' then raise exception 'Captura descripción, posiciones enteras y peso bruto.'; end if;
            n:=qty::integer;kg:=(c->>'weightKg')::numeric;
            if not exists(select 1 from public.usa_proyectos where id=(c->>'projectId')::uuid) then raise exception 'Proyecto receptor inválido.'; end if;
            if c->>'kind'='special' and not exists(select 1 from public.usa_clientes where id=(c->>'clientId')::uuid and activo) then raise exception 'Indica un cliente activo de la carga especial.'; end if;
            if coalesce((c->>'ambient')::boolean,false)=false then
                lo:=(c->>'minF')::numeric;hi:=(c->>'maxF')::numeric;
                if lo is null or hi is null or lo>=hi then raise exception 'Indica el rango térmico de la carga especial.'; end if;
            end if;
            if c->>'kind'='supplies' then
                select * into req from public.usa_solicitudes_insumos where id=(c->>'requestId')::uuid for update;
                if not found or req.project_id is distinct from (c->>'projectId')::uuid or req.pallets<>n or req.weight_kg<>kg or req.requested_date<>day then raise exception 'La solicitud de Compras no coincide con la carga.'; end if;
                if exists(select 1 from public.usa_viajes_planeados v,jsonb_array_elements(v.plan->'cargo') a where v.id is distinct from p_trip and a->>'requestId'=c->>'requestId') then raise exception 'Los insumos ya están reservados en otro viaje.'; end if;
            end if;
        else raise exception 'Tipo de carga desconocido.';
        end if;
        positions:=c->'positions';
        if jsonb_typeof(positions) is distinct from 'array' or jsonb_array_length(positions)<>n then raise exception 'Asigna una posición a cada pallet/equivalente.'; end if;
        for j in 0..n-1 loop
            qty:=(positions->>j)::numeric;pos:=qty::integer;
            if qty is null or qty<>trunc(qty) or pos<0 or pos>=capacity then raise exception 'Posición fuera de la caja.'; end if;
            if c->>'kind'='product' then part:=least(bpp,boxes-j*bpp)*(kg/boxes)+u.tara_pallet_kg; else part:=kg/n; end if;
            items:=items||jsonb_build_array(jsonb_build_object('cargo',c->>'id','productId',c->>'productId','lo',lo,'hi',hi,'kg',part,'position',pos,'li',li,'ui',ui));
        end loop;
    end loop;
    for idx in 0..jsonb_array_length(p_plan->'stops')-2 loop
        if exists(select 1 from jsonb_array_elements(items) a where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx group by a->>'position' having count(*)>1) then raise exception 'Dos pallets ocupan la misma posición en un tramo.'; end if;
        select coalesce(sum((a->>'kg')::numeric)*2.20462262185,0),max((a->>'lo')::numeric),min((a->>'hi')::numeric) into total_lb,lower_f,upper_f from jsonb_array_elements(items) a where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx;
        if total_lb>u.carga_util_lb then raise exception 'La carga supera el peso útil en un tramo.'; end if;
        if lower_f is not null then
            if not u.refrigerada or u.temperatura_min_f is null or u.temperatura_max_f is null or greatest(lower_f,u.temperatura_min_f)>=least(upper_f,u.temperatura_max_f) then raise exception 'No existe temperatura compatible para la carga y equipo en un tramo.'; end if;
        end if;
        if (select count(distinct coalesce(a->>'productId','cargo:'||(a->>'cargo'))) from jsonb_array_elements(items) a where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx)>1 and exists(select 1 from jsonb_array_elements(items) a join public.usa_productos pr on pr.id=(a->>'productId')::uuid where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx and pr.puede_consolidar=false) then raise exception 'Un producto no permite consolidar.'; end if;
        k:=(e->>'kingpinM')::numeric;r:=(e->>'trailerAxleM')::numeric;l:=(e->>'lengthM')::numeric;f:=(e->>'fifthWheelM')::numeric;w:=(e->>'tractorWheelbaseM')::numeric;axle:=e->'emptyAxlesLb';
        if k is not null and r is not null and l is not null and f is not null and w is not null and jsonb_typeof(axle)='array' and jsonb_array_length(axle)=3 then
            if k<0 or r<=k or l<=0 or w<=0 or f<0 or f>w or exists(select 1 from jsonb_array_elements_text(axle) a where a::numeric<0) then raise exception 'Geometría o tara inválida.'; end if;
            rear:=0;
            for pallet in select a from jsonb_array_elements(items) a where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx loop
                x:=(floor((pallet->>'position')::numeric/2)+0.5)*l/ceil(capacity::numeric/2);
                rear:=rear+(pallet->>'kg')::numeric*2.20462262185*(x-k)/(r-k);
            end loop;
            king:=total_lb-rear;drive:=(axle->>1)::numeric+king*f/w;front:=(axle->>0)::numeric+king*(1-f/w);rear:=rear+(axle->>2)::numeric;
            if least(front,drive,rear)<0 or front+drive+rear>u.peso_bruto_max_lb then raise exception 'Peso bruto o distribución por ejes fuera de límite.'; end if;
            if jsonb_typeof(u.limites_ejes_lb)='array' and jsonb_array_length(u.limites_ejes_lb)=3 and (front>(u.limites_ejes_lb->>0)::numeric or drive>(u.limites_ejes_lb->>1)::numeric or rear>(u.limites_ejes_lb->>2)::numeric) then raise exception 'Se supera un límite por grupo de ejes: reacomoda o reduce carga.'; end if;
        end if;
    end loop;
end $$;
revoke all on function public.validate_transport_plan(jsonb,uuid) from public;

create or replace function public.save_transport_trip(p_plan jsonb,p_expected_revision integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid:=coalesce(nullif(p_plan->>'id','')::uuid,gen_random_uuid()); oldrow public.usa_viajes_planeados; nextrev integer; c jsonb; s jsonb; prior jsonb; item public.usa_programacion_fletes; load_day date; arrival timestamptz;
begin
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede programar viajes.'; end if;
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
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('GERENCIA','SUBGERENCIA','COORDINADOR','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede cancelar viajes.'; end if;
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
    if auth.uid() is null or upper(coalesce(auth.jwt()->'app_metadata'->>'role','')) not in ('GERENCIA','SUBGERENCIA','COORDINADOR','LIDER_PROYECTO','ADMINISTRATIVO','DIRECCION','SUBDIRECCION','ADMINISTRADOR') then raise exception 'Tu rol no puede confirmar operaciones.'; end if;
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

revoke all on function public.save_transport_trip(jsonb,integer) from public;
revoke all on function public.cancel_transport_trip(uuid,integer) from public;
revoke all on function public.confirm_transport_stop(uuid,integer,text,jsonb,text,jsonb) from public;
grant execute on function public.save_transport_trip(jsonb,integer) to authenticated;
grant execute on function public.cancel_transport_trip(uuid,integer) to authenticated;
grant execute on function public.confirm_transport_stop(uuid,integer,text,jsonb,text,jsonb) to authenticated;

create or replace function public.validate_consolidated_capacity() returns trigger
language plpgsql set search_path = public as $$
declare project uuid; cap numeric; pallets numeric; t public.usa_viajes_planeados;
begin
    select * into t from public.usa_viajes_planeados where id=new.load_id;
    if found then
        if current_setting('app.transport_trip_write',true) is distinct from new.load_id::text then raise exception 'Modifica las asignaciones desde el plan de viaje.'; end if;
        if exists(select 1 from public.usa_programacion_fletes s where s.load_id=new.load_id and s.projection_id=new.projection_id and s.id<>new.id) then raise exception 'La meta ya tiene una asignación en este viaje.'; end if;
        if not exists(select 1 from jsonb_array_elements(t.plan->'cargo') c join jsonb_array_elements(t.plan->'stops') s on s->>'id'=c->>'loadStopId'
            where c->>'kind'='product' and (c->>'projectionId')::uuid=new.projection_id and (c->>'boxes')::integer=new.quantity and left(s->>'at',10)::date=new.scheduled_date
            and (t.plan->>'unitTypeId')::bigint=new.unit_type_id and (t.plan->>'carrierId')::uuid=new.carrier_id and public.transport_at(t.plan->>'arrivalAt')=new.arrival_at) then raise exception 'La asignación no coincide con el plan autorizado.'; end if;
        return new;
    end if;
    if tg_op='INSERT' then raise exception 'Programa las nuevas cargas desde el plan de viaje.'; end if;
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

create or replace function public.validate_commercial_freight() returns trigger
language plpgsql set search_path = public as $$
declare
    goal public.proyecciones_estrategicas;
    daily_quantity numeric := 0;
    booked numeric;
begin
    if tg_op = 'DELETE' then
        if exists(select 1 from public.usa_viajes_planeados where id=old.load_id) and current_setting('app.transport_trip_write',true) is distinct from old.load_id::text then raise exception 'Cancela o modifica el viaje completo para liberar sus asignaciones.'; end if;
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


commit;
