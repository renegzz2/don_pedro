import React, { useEffect, useMemo, useState } from 'react';
import { supabase } from '../lib/supabase';
import { View, UserRole, type User, type ProyectoDB, type ProductoDB, type ClienteDB, type LineaTransporteDB, type TipoUnidad } from '../types';
import { fiscalPeriod, planningWeekDays } from '../utils/commercialPlanning';
import { planningSectionAccess, PLANNING_SECTIONS } from '../utils/planningAccess';
import { fromUnit } from '../utils/tripPlanning';
import { toCamelCase } from '../utils/formatters';
import { useCommercialPlanning } from '../hooks/useCommercialPlanning';
import { useTransportTrips } from '../hooks/useTransportTrips';
import PackingPlanPanel from './PackingPlanPanel';
import ConsolidatedTransportCalendar from './ConsolidatedTransportCalendar';
import SupplyRequestsPanel from './SupplyRequestsPanel';
import type { TransportSpec } from '../transportTypes';

function usePeriod() {
    const current = fiscalPeriod();
    const [year,setYear] = useState(current.year), [week,setWeek] = useState(current.week);
    const days = useMemo(() => planningWeekDays(year,week),[year,week]);
    return { year,week,setYear,setWeek,days };
}
function PeriodSelector({period}:{period:ReturnType<typeof usePeriod>}) {
    return <div className="flex gap-3 flex-wrap"><label className="text-sm font-bold">Año<input aria-label="Año de planeación" type="number" min="2000" max="2200" className="border border-border rounded-lg p-2 bg-surface w-24 ml-2" value={period.year} onChange={e=>period.setYear(Math.min(2200,Math.max(2000,Number(e.target.value)||2000)))}/></label><label className="text-sm font-bold">Semana<input aria-label="Semana de planeación" type="number" min="1" max="53" className="border border-border rounded-lg p-2 bg-surface w-20 ml-2" value={period.week} onChange={e=>period.setWeek(Math.min(53,Math.max(1,Number(e.target.value)||1)))}/></label></div>;
}
function SuppliesPage({user}:{user:User}) {
    const period = usePeriod();
    const data = useTransportTrips(period.days[0].dateString,period.days.at(-1)!.dateString,false);
    const [projects,setProjects] = useState<ProyectoDB[]>([]), [error,setError] = useState('');
    useEffect(()=>{let active=true;void supabase.from('usa_proyectos').select('*').then(r=>{if(!active)return;if(r.error)setError(r.error.message);else setProjects(toCamelCase(r.data||[]));});return()=>{active=false;};},[]);
    return <div className="space-y-5"><h1 className="text-2xl font-black text-primary">Compras · Recolección de insumos</h1><PeriodSelector period={period}/>{(error||data.error)&&<p role="alert" className="text-danger">{error||data.error}</p>}<SupplyRequestsPanel user={user} projects={projects} requests={data.requests} refresh={data.refresh}/></div>;
}
function PackingOrTransportPage({user,view}:{user:User;view:View}) {
    const period = usePeriod();
    const planning = useCommercialPlanning(period.week,period.year);
    const [projects,setProjects]=useState<ProyectoDB[]>([]),[products,setProducts]=useState<ProductoDB[]>([]),[clients,setClients]=useState<ClienteDB[]>([]),[carriers,setCarriers]=useState<LineaTransporteDB[]>([]),[units,setUnits]=useState<TransportSpec[]>([]),[error,setError]=useState('');
    const [project,setProject]=useState(''),[client,setClient]=useState('');
    const refreshCatalogs=async()=>{
        const requests=[supabase.from('usa_proyectos').select('*'),supabase.from('usa_productos').select('*'),supabase.from('usa_clientes').select('*')];
        if(view===View.TRANSPORT_PLANNING)requests.push(supabase.from('tipo_unidad').select('*'),supabase.from('usa_lineas_transporte').select('*'));
        const results=await Promise.all(requests);
        const failed=results.find(r=>r.error);if(failed){setError(failed.error!.message);return;}
        setProjects(toCamelCase(results[0].data||[]));setProducts(toCamelCase(results[1].data||[]));setClients(toCamelCase(results[2].data||[]));
        if(view===View.TRANSPORT_PLANNING){setUnits((toCamelCase(results[3].data||[])as TipoUnidad[]).map(fromUnit));setCarriers(toCamelCase(results[4].data||[]));}
        setError('');
    };
    useEffect(()=>{void refreshCatalogs();},[view]);
    const goals=planning.goals.filter(g=>(!project||g.proyectoId===project)&&(!client||g.clientId===client));
    const title=PLANNING_SECTIONS.find(s=>s.view===view)?.label;
    return <div className="space-y-5"><h1 className="text-2xl font-black text-primary">{title}</h1><div className="flex gap-4 flex-wrap items-center"><PeriodSelector period={period}/><label className="text-sm">Proyecto<select aria-label="Filtrar proyecto" className="border border-border rounded-lg p-2 bg-surface ml-2" value={project} onChange={e=>setProject(e.target.value)}><option value="">Todos</option>{projects.map(p=><option key={p.id} value={p.id}>{p.nombre}</option>)}</select></label><label className="text-sm">Cliente<select aria-label="Filtrar cliente" className="border border-border rounded-lg p-2 bg-surface ml-2" value={client} onChange={e=>setClient(e.target.value)}><option value="">Todos</option>{clients.map(c=><option key={c.id} value={c.id}>{c.nombre}</option>)}</select></label></div>
        {(error||planning.error)&&<p role="alert" className="text-danger">{error||planning.error}</p>}
        {planning.loading?<p>Cargando planeación...</p>:view===View.PACKING_PLANNING?<PackingPlanPanel goals={goals} projects={projects} products={products} clients={clients} days={period.days} canEdit={true} onSaved={planning.refresh}/>:<ConsolidatedTransportCalendar goals={goals} projects={projects} products={products} clients={clients} types={units} schedules={planning.schedules} carriers={carriers} days={period.days} canSchedule={[UserRole.TRAFICO_RI,UserRole.ADMINISTRADOR].includes(user.role)} user={user} onSaved={async()=>{await Promise.all([planning.refresh(),refreshCatalogs()]);}}/>}
    </div>;
}
export default function OperationalPlanningPage({user,view}:{user:User;view:View}) {
    if(planningSectionAccess(view,user.role)!==true)return <p role="alert" className="text-danger">No tienes acceso a esta sección.</p>;
    return view===View.SUPPLY_COLLECTION?<SuppliesPage user={user}/>:<PackingOrTransportPage user={user} view={view}/>;
}
