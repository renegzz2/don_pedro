begin;

-- The first pickup requiring refrigeration determines a single departure setpoint.
-- Supplies without thermal requirements do not define point A.
create or replace function public.trip_departure_temperature(p_plan jsonb)
returns jsonb language plpgsql stable set search_path=public as $$
declare
    c jsonb; p public.usa_productos; u public.tipo_unidad;
    first_index integer; load_index integer; origin text; low_f numeric; high_f numeric;
    cargo_low numeric; cargo_high numeric; optimum numeric; preferred jsonb:='[]';
    selected_f numeric; controlled boolean;
begin
    for c in select value from jsonb_array_elements(p_plan->'cargo') loop
        optimum:=null;controlled:=false;
        if c->>'kind'='product' then
            select * into p from public.usa_productos where id=(c->>'productId')::uuid;
            if found and p.almacenado_frio is distinct from false then
                controlled:=true;cargo_low:=nullif(trim(p.limite_tolerable),'')::numeric;cargo_high:=p.limite_superior;optimum:=p.temp_optima;
            end if;
        elsif c->>'kind' in ('special','supplies') and coalesce((c->>'ambient')::boolean,false)=false then
            controlled:=true;cargo_low:=(c->>'minF')::numeric;cargo_high:=(c->>'maxF')::numeric;
        end if;
        if not controlled then continue;end if;
        if cargo_low is null or cargo_high is null or cargo_low>=cargo_high then raise exception 'Revisa los límites de temperatura de la carga.';end if;
        select ord::integer-1 into load_index from jsonb_array_elements(p_plan->'stops') with ordinality t(v,ord) where v->>'id'=c->>'loadStopId';
        if load_index is null then raise exception 'Selecciona la parada de carga del producto.';end if;
        if first_index is null or load_index<first_index then
            first_index:=load_index;origin:=c->>'loadStopId';low_f:=cargo_low;high_f:=cargo_high;preferred:='[]';
        elsif load_index=first_index then
            low_f:=greatest(low_f,cargo_low);high_f:=least(high_f,cargo_high);
        else continue;
        end if;
        if optimum is not null then preferred:=preferred||to_jsonb(optimum);end if;
    end loop;
    selected_f:=(p_plan->>'temperatureF')::numeric;
    if first_index is null then return jsonb_build_object('value',selected_f,'originStopId',null);end if;
    select * into u from public.tipo_unidad where id=(p_plan->>'unitTypeId')::bigint;
    if not found or not u.refrigerada or u.temperatura_min_f is null or u.temperatura_max_f is null then raise exception 'El equipo no tiene un rango de refrigeración configurado.';end if;
    low_f:=greatest(low_f,u.temperatura_min_f);high_f:=least(high_f,u.temperatura_max_f);
    if low_f>=high_f then raise exception 'No existe temperatura común para la carga inicial y el equipo.';end if;
    if selected_f is null then
        select avg(v::numeric) into selected_f from jsonb_array_elements_text(preferred) t(v) where v::numeric>=low_f and v::numeric<high_f;
        selected_f:=coalesce(selected_f,(low_f+high_f)/2);
    end if;
    if selected_f<low_f or selected_f>=high_f then raise exception 'La temperatura de salida debe cumplir % <= T < % °F para la carga inicial.',low_f,high_f;end if;
    return jsonb_build_object('value',selected_f,'originStopId',origin,'minF',low_f,'maxF',high_f);
end $$;
revoke all on function public.trip_departure_temperature(jsonb) from public;

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
    k numeric; r numeric; l numeric; f numeric; w numeric; thermal jsonb; fixed_f numeric;
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
    thermal:=public.trip_departure_temperature(p_plan);
    fixed_f:=(p_plan->>'temperatureF')::numeric;
    if thermal->>'originStopId' is not null and fixed_f is null then raise exception 'Confirma la temperatura de salida del punto A antes de continuar.';end if;
    for idx in 0..jsonb_array_length(p_plan->'stops')-2 loop
        if exists(select 1 from jsonb_array_elements(items) a where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx group by a->>'position' having count(*)>1) then raise exception 'Dos pallets ocupan la misma posición en un tramo.'; end if;
        select coalesce(sum((a->>'kg')::numeric)*2.20462262185,0),max((a->>'lo')::numeric),min((a->>'hi')::numeric) into total_lb,lower_f,upper_f from jsonb_array_elements(items) a where (a->>'li')::integer<=idx and (a->>'ui')::integer>idx;
        if total_lb>u.carga_util_lb then raise exception 'La carga supera el peso útil en un tramo.'; end if;
        if lower_f is not null then
            if not u.refrigerada or u.temperatura_min_f is null or u.temperatura_max_f is null or greatest(lower_f,u.temperatura_min_f)>=least(upper_f,u.temperatura_max_f) then raise exception 'No existe temperatura compatible para la carga y equipo en un tramo.'; end if;
            if fixed_f<lower_f or fixed_f>=upper_f then raise exception 'La carga de % no admite la temperatura de salida de % °F. No se cambia la temperatura en una parada intermedia.',p_plan->'stops'->idx->>'name',fixed_f;end if;
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

create or replace function public.save_transport_trip(p_plan jsonb,p_expected_revision integer)
returns uuid language plpgsql security definer set search_path=public as $$
declare tid uuid:=coalesce(nullif(p_plan->>'id','')::uuid,gen_random_uuid()); oldrow public.usa_viajes_planeados; nextrev integer; c jsonb; s jsonb; prior jsonb; item public.usa_programacion_fletes; load_day date; arrival timestamptz; thermal jsonb; previous_thermal jsonb; origin_completed boolean;
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


revoke all on function public.validate_transport_plan(jsonb,uuid) from public;
revoke all on function public.save_transport_trip(jsonb,integer) from public;
grant execute on function public.save_transport_trip(jsonb,integer) to authenticated;

commit;
