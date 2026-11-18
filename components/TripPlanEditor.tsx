import React, { useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { supabase } from '../lib/supabase';
import type { TripPlan, TripCargo, TransportSpec, SupplyRequest } from '../transportTypes';
import type { StrategicProjection, ProyectoDB, ProductoDB, ClienteDB, LineaTransporteDB } from '../types';
import { evaluateTrip, balanceTrip, departureTemperature } from '../utils/tripPlanning';
import { commercialQuantityForDay } from '../utils/commercialPlanning';
import TripLoadMap from './TripLoadMap';
interface Props { initial: TripPlan; goals: StrategicProjection[]; projects: ProyectoDB[]; clients: ClienteDB[]; products: ProductoDB[]; types: TransportSpec[]; carriers: LineaTransporteDB[]; requests: SupplyRequest[]; booked: Record<string, number>; onClose: () => void; onSaved: () => Promise<void> }
export default function TripPlanEditor({ initial, goals, projects, clients, products, types, carriers, requests, booked, onClose, onSaved }: Props) {
    const [plan, setPlan] = useState(() => {
        try { return { ...initial, temperatureF: initial.temperatureF ?? departureTemperature(initial, products).value }; }
        catch { return initial; }
    }), [saving, setSaving] = useState(false), [error, setError] = useState('');
    const [fieldErrors, setFieldErrors] = useState<string[]>([]);
    const [submitAttempted, setSubmitAttempted] = useState(false);
    const validationRef = useRef<HTMLDivElement>(null);
    const temperatureRef = useRef<HTMLInputElement>(null);
    const activePlan = { ...plan, cargo: plan.cargo.filter(c => c.kind !== 'product' || c.boxes > 0) };
    const result = evaluateTrip(activePlan, products);
    let initialTemperature: ReturnType<typeof departureTemperature> | null = null;
    try { initialTemperature = departureTemperature({ ...activePlan, id: '', temperatureF: null }, products); }
    catch { /* Other validation messages explain incomplete catalog or route data. */ }
    const originCompleted = !!initial.stops.find(s => s.id === (initial.temperatureOriginStopId || initialTemperature?.originStopId))?.completedAt;
    const temperatureLocked = initial.temperatureF != null && originCompleted;
    const allocationErrors = activePlan.cargo.filter(c=>c.kind==='product').flatMap(c=>{
        const g=goals.find(g=>g.id===c.projectionId);const day=plan.stops.find(s=>s.id===c.loadStopId)?.at.slice(0,10)||plan.scheduledDate;
        const available=g ? Math.max(0,commercialQuantityForDay(g,day)-(booked[`${c.projectionId}:${day}`]||0)) : 0;
        return c.boxes>available ? [`${c.description}: solo hay ${available} cajas pendientes para ese día.`] : [];
    });
    const validationIssues = [...new Set([
        ...result.errors, ...allocationErrors, ...fieldErrors,
        ...(activePlan.cargo.length ? [] : ['Agrega al menos un producto o carga a esta unidad.'])
    ])];
    const clearPositions = (next: TripPlan) => ({ ...next, cargo: next.cargo.map(c => next.stops.find(s=>s.id===c.loadStopId)?.completedAt ? c : ({ ...c, positions: undefined })) });
    const changeCargo = (id: string, patch: Partial<TripCargo>) => setPlan(clearPositions({ ...plan, cargo: plan.cargo.map(c => c.id === id ? { ...c, ...patch } : c) }));
    const save = async (e: React.FormEvent) => {
        e.preventDefault(); if (saving) return;
        setSubmitAttempted(true); setError('');
        const form = e.currentTarget as HTMLFormElement;
        const missingFields = Array.from(form.elements)
            .filter((element): element is HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement =>
                (element instanceof HTMLInputElement || element instanceof HTMLSelectElement || element instanceof HTMLTextAreaElement) && element.willValidate && !element.validity.valid)
            .map(element => {
                const label = element.labels?.[0];
                const name = element.getAttribute('aria-label') || Array.from(label?.childNodes || [])
                    .find(node => node.nodeType === Node.TEXT_NODE && node.textContent?.trim())?.textContent?.trim() || 'Campo del formulario';
                return `${name}: ${element.validity.valueMissing ? 'completa este dato.' : element.validationMessage}`;
            });
        setFieldErrors(missingFields);
        if (result.errors.length || allocationErrors.length || !activePlan.cargo.length || missingFields.length) {
            requestAnimationFrame(() => {
                validationRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
                validationRef.current?.focus({ preventScroll: true });
            });
            return;
        }
        setSaving(true); setError('');
        try {
            const payload = { ...plan, temperatureF: plan.temperatureF ?? result.departure.value, temperatureOriginStopId: result.departure.originStopId, scheduledDate: plan.stops[0]?.at.slice(0,10) || plan.scheduledDate, cargo: activePlan.cargo.map(c => ({ ...c, positions: result.pallets.filter(p => p.cargoId === c.id).map(p => p.position) })) };
            const { error } = await supabase.rpc('save_transport_trip', { p_plan: payload, p_expected_revision: initial.revision });
            if (error) throw error; await onSaved(); onClose();
        } catch (e: any) { setError(e.message); } finally { setSaving(false); }
    };
    const addSpecial = () => setPlan({ ...plan, cargo: [...plan.cargo, { id: crypto.randomUUID(), kind: 'special', projectId: '', clientId: '', description: '', boxes: 0, pallets: 1, weightKg: 0, ambient: false, loadStopId: plan.stops[0]?.id || '', unloadStopId: plan.stops.at(-1)?.id || '' }] });
    const input = 'w-full border border-border rounded-lg p-2 bg-background text-sm';
    const stopSelect = (cargo: TripCargo, key: 'loadStopId'|'unloadStopId') => <select aria-label={key === 'loadStopId' ? 'Punto de carga' : 'Punto de descarga'} required className={input} value={cargo[key]} onChange={e => changeCargo(cargo.id, { [key]: e.target.value })}>{plan.stops.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}</select>;
    return createPortal(<div className="fixed inset-0 bg-black/70 z-[180] flex items-center justify-center p-3"><form noValidate onSubmit={save} onChangeCapture={() => { setFieldErrors([]); setError(''); }} className="bg-surface rounded-2xl p-5 max-w-6xl w-full max-h-[95vh] overflow-y-auto space-y-5">
        <div className="flex justify-between"><h2 className="font-black text-primary">{initial.id ? 'Editar viaje' : 'Programar unidad consolidada'} · {plan.scheduledDate}</h2><button type="button" disabled={saving} onClick={onClose}>Cerrar</button></div>
        <div className="grid md:grid-cols-3 gap-3"><label>Tipo de unidad<select required className={input} value={plan.unitTypeId} disabled={!!plan.stops[0]?.completedAt} onChange={e => { const unit = types.find(t => t.id === e.target.value)!; setPlan(clearPositions({ ...plan, unitTypeId: unit.id, equipment: unit })); }}>{types.map(t => <option key={t.id} value={t.id}>{t.name} · {t.capacity} pallets · {t.payloadLb || 'Sin configurar'} lb</option>)}</select></label>
            <label>Proveedor<select required className={input} value={plan.carrierId} onChange={e => setPlan({ ...plan, carrierId: e.target.value })}><option value="">Seleccionar...</option>{carriers.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}</select></label>
            <label>Llegada de la unidad<input required type="datetime-local" className={input} value={plan.arrivalAt.slice(0,16)} onChange={e => setPlan({ ...plan, arrivalAt: e.target.value })} /></label>
        </div>
        <div className="border border-border rounded-xl p-3 space-y-2">
            <label className="block font-bold text-primary">Temperatura de salida de la caja (°F)
                <input ref={temperatureRef} aria-label="Temperatura de salida °F" aria-invalid={result.errors.some(e => e.includes('temperatura'))} type="number" step="any" disabled={temperatureLocked} className={input} value={plan.temperatureF ?? ''} onChange={e => setPlan({ ...plan, temperatureF: e.target.value === '' ? null : Number(e.target.value) })} />
            </label>
            {initialTemperature?.range && <p className="text-sm">Rango permitido para la carga inicial: <strong>{initialTemperature.range.min} ≤ temperatura &lt; {initialTemperature.range.max} °F</strong>.</p>}
            {!originCompleted && initialTemperature?.value != null && <button type="button" className="text-primary underline text-sm" onClick={() => setPlan({ ...plan, temperatureF: initialTemperature!.value })}>Usar sugerencia de la carga inicial: {initialTemperature.value} °F</button>}
            <p className="text-xs text-text-secondary">Se define con los productos de la primera recolección refrigerada (punto A). Las cargas posteriores deben aceptar esta misma temperatura; no se recalcula para acomodarlas. Los insumos sin control térmico no la definen.</p>
            {temperatureLocked && <p className="text-xs text-primary">Temperatura fijada: la carga del punto A ya fue confirmada.</p>}
        </div>
        <div className="grid md:grid-cols-2 gap-3"><label>Placas tractor asignado<input className={input} value={plan.tractorPlates||''} onChange={e=>setPlan({...plan,tractorPlates:e.target.value})}/></label><label>Placas caja asignada<input className={input} value={plan.trailerPlates||''} onChange={e=>setPlan({...plan,trailerPlates:e.target.value})}/></label></div>
        <div className="grid md:grid-cols-2 gap-3">
            {([['operator','Operador'],['economicNumber','Número económico'],['trailerFeet','Pies del remolque'],['thermograph','Termógrafo']] as const).map(([field,label]) => <label key={field}>{label}<input className={input} value={plan[field] || ''} onChange={e => setPlan({...plan,[field]:e.target.value})}/></label>)}
            <label>Termo en continuo<select className={input} value={plan.continuous == null ? '' : String(plan.continuous)} onChange={e => setPlan({...plan,continuous:e.target.value === '' ? undefined : e.target.value === 'true'})}><option value="">Sin confirmar</option><option value="true">Sí</option><option value="false">No</option></select></label>
        </div>
        <section className="space-y-2"><h3 className="font-bold text-primary">Recorrido · orden de recolecciones y entregas</h3>
            {plan.stops.map((s,i) => <div key={s.id} className="grid md:grid-cols-4 gap-2 border border-border rounded p-2">
                <label>Parada {i+1}<input required disabled={!!s.completedAt} className={input} value={s.name} onChange={e => setPlan({ ...plan, stops: plan.stops.map(t => t.id===s.id ? {...t,name:e.target.value}:t) })} /></label>
                <label>Dirección<input required disabled={!!s.completedAt} className={input} value={s.address} onChange={e => setPlan({ ...plan, stops: plan.stops.map(t => t.id===s.id ? {...t,address:e.target.value}:t) })} /></label>
                <label>Horario<input required disabled={!!s.completedAt} type="datetime-local" className={input} value={s.at.slice(0,16)} onChange={e => setPlan({ ...plan, stops: plan.stops.map(t => t.id===s.id ? {...t,at:e.target.value}:t) })} /></label>
                <div className="flex gap-2 items-end"><button type="button" disabled={i===0 || !!s.completedAt || !!plan.stops[i-1]?.completedAt} onClick={() => { const stops=[...plan.stops]; [stops[i-1],stops[i]]=[stops[i],stops[i-1]];setPlan(clearPositions({...plan,stops})); }}>↑ Subir</button><button type="button" disabled={!!s.completedAt} onClick={() => setPlan(clearPositions({...plan,stops:plan.stops.filter(t=>t.id!==s.id)}))}>Quitar</button>{s.completedAt && <span>Confirmada</span>}</div>
            </div>)}
            <button type="button" className="text-primary underline" onClick={() => setPlan({...plan,stops:[...plan.stops,{id:crypto.randomUUID(),name:'Nueva parada',address:'',at:`${plan.scheduledDate}T18:00`}]})}>Agregar parada intermedia / entrega</button>
        </section>
        <section className="space-y-3"><h3 className="font-bold text-primary">Productos y cajas asignadas a esta unidad</h3>
            {plan.cargo.map(c => <fieldset disabled={!!plan.stops.find(s=>s.id===c.loadStopId)?.completedAt} key={c.id} className="border border-border rounded-xl p-3 space-y-2">
                <div className="flex gap-3 justify-between"><strong>{c.kind === 'product' ? `${projects.find(p=>p.id===c.projectId)?.nombre} / ${clients.find(t=>t.id===c.clientId)?.nombre} · ${c.description}` : c.kind === 'supplies' ? 'Insumos de Compras' : 'Carga especial'}</strong><button type="button" className="text-danger" onClick={()=>setPlan(clearPositions({...plan,cargo:plan.cargo.filter(t=>t.id!==c.id)}))}>Excluir</button></div>
                {c.kind === 'product' ? <label>Cajas (0 excluye de esta unidad)<input type="number" min="0" step="1" className={input} value={c.boxes} onChange={e=>changeCargo(c.id,{boxes:Number(e.target.value)})} />
                    <span className="text-xs">Disponibles: {Math.max(0, commercialQuantityForDay(goals.find(g=>g.id===c.projectionId)!,plan.stops.find(s=>s.id===c.loadStopId)?.at.slice(0,10)||plan.scheduledDate) - (booked[`${c.projectionId}:${plan.stops.find(s=>s.id===c.loadStopId)?.at.slice(0,10)}`]||0))} · El remanente generará nuevas sugerencias.</span>
                </label> : <div className="grid md:grid-cols-3 gap-2">
                    <label>Descripción<input required className={input} value={c.description} onChange={e=>changeCargo(c.id,{description:e.target.value})} /></label>
                    <label>Proyecto<select required className={input} value={c.projectId} onChange={e=>changeCargo(c.id,{projectId:e.target.value})}><option value="">Seleccionar...</option>{projects.map(p=><option key={p.id} value={p.id}>{p.nombre}</option>)}</select></label>
                    {c.kind==='special' && <label>Cliente<select required className={input} value={c.clientId} onChange={e=>changeCargo(c.id,{clientId:e.target.value})}><option value="">Seleccionar...</option>{clients.filter(c=>c.activo!==false).map(c=><option key={c.id} value={c.id}>{c.nombre}</option>)}</select></label>}
                    <label>Posiciones equivalentes<input required type="number" min="1" step="1" className={input} value={c.pallets||''} onChange={e=>changeCargo(c.id,{pallets:Number(e.target.value)})} /></label>
                    <label>Peso bruto total con tarimas (kg)<input required type="number" min="0.001" step="any" className={input} value={c.weightKg||''} onChange={e=>changeCargo(c.id,{weightKg:Number(e.target.value)})} /></label>
                    <label><input type="checkbox" checked={!!c.ambient} onChange={e=>changeCargo(c.id,{ambient:e.target.checked})} /> No requiere control térmico</label>
                    {!c.ambient && <><label>Mínima °F<input required type="number" step="any" className={input} value={c.minF??''} onChange={e=>changeCargo(c.id,{minF:Number(e.target.value)})} /></label><label>Superior no permitida °F<input required type="number" step="any" className={input} value={c.maxF??''} onChange={e=>changeCargo(c.id,{maxF:Number(e.target.value)})} /></label></>}
                </div>}
                <div className="grid md:grid-cols-2 gap-2"><label>Carga en{stopSelect(c,'loadStopId')}</label><label>Descarga en{stopSelect(c,'unloadStopId')}</label></div>
            </fieldset>)}
            <select aria-label="Agregar otra meta" className={input} value="" onChange={e=>{
                const g=goals.find(g=>g.id===e.target.value);if(!g)return;
                setPlan(clearPositions({...plan,cargo:[...plan.cargo,{id:crypto.randomUUID(),kind:'product',projectionId:g.id,productId:g.productoId,projectId:g.proyectoId,clientId:g.clientId,description:products.find(p=>p.id===g.productoId)?.nombreDelProducto||'',boxes:1,loadStopId:plan.stops.find(s=>s.id===`p-${g.proyectoId}`)?.id||plan.stops[0]?.id||'',unloadStopId:plan.stops.find(s=>s.id===`c-${g.clientId}`)?.id||plan.stops.at(-1)?.id||''}]}));
            }}><option value="">Agregar producto de otra meta / cliente...</option>{goals.filter(g=>!plan.cargo.some(c=>c.projectionId===g.id)).map(g=><option key={g.id} value={g.id}>{projects.find(p=>p.id===g.proyectoId)?.nombre} / {clients.find(c=>c.id===g.clientId)?.nombre} · {products.find(p=>p.id===g.productoId)?.nombreDelProducto}</option>)}</select>
            <div className="flex gap-4"><button type="button" onClick={addSpecial} className="text-primary underline">Agregar carga especial sin catálogo</button></div>
            <select aria-label="Asignar solicitud de Compras" value="" className={input} onChange={e=>{
                const r=requests.find(r=>r.id===e.target.value);if(!r)return;const stop={id:crypto.randomUUID(),name:r.supplier,address:r.address,at:`${r.requestedDate}T06:00`};
                const insertAt=plan.stops.findIndex(s=>!s.completedAt);const stops=[...plan.stops];stops.splice(insertAt<0?stops.length:insertAt,0,stop);
                setPlan(clearPositions({...plan,scheduledDate:stops[0].at.slice(0,10),stops,cargo:[...plan.cargo,{id:crypto.randomUUID(),kind:'supplies',requestId:r.id,projectId:r.projectId,description:r.description,boxes:0,pallets:r.pallets,weightKg:r.weightKg,ambient:true,loadStopId:stop.id,unloadStopId:plan.stops.find(s=>s.id===`p-${r.projectId}`)?.id||plan.stops[0]?.id||''}]}));
            }}><option value="">Asignar recolección de Compras...</option>{requests.filter(r=>r.status==='pendiente'&&!plan.cargo.some(c=>c.requestId===r.id)).map(r=><option key={r.id} value={r.id}>{r.supplier} · {r.description} · {r.pallets} posiciones</option>)}</select>
        </section>
        <details className="border border-border rounded-xl p-3"><summary>Equipo asignado · geometría y tara para estimación por ejes</summary><div className="grid md:grid-cols-3 gap-2 mt-3">
            {(['lengthM','kingpinM','trailerAxleM','fifthWheelM','tractorWheelbaseM'] as const).map((key,i)=><label key={key}>{['Longitud interior (m)','Perno rey desde frente (m)','Tándem caja desde frente (m)','Quinta rueda desde eje dirección (m)','Distancia dirección–motrices (m)'][i]}<input type="number" step="any" min="0" className={input} value={plan.equipment[key]??''} onChange={e=>setPlan({...plan,equipment:{...plan.equipment,[key]:e.target.value===''?null:Number(e.target.value)}})} /></label>)}
            {[0,1,2].map(i=><label key={i}>Tara {['dirección','motrices','tándem caja'][i]} (lb)<input type="number" step="any" min="0" className={input} value={plan.equipment.emptyAxlesLb?.[i]??''} onChange={e=>{const weights=[...(plan.equipment.emptyAxlesLb||[0,0,0])];weights[i]=Number(e.target.value);setPlan({...plan,equipment:{...plan.equipment,emptyAxlesLb:weights}});}} /></label>)}
        </div></details>
        <button type="button" className="text-primary underline" onClick={()=>setPlan(balanceTrip(clearPositions(plan),products))}>Sugerir acomodo equilibrado por ejes</button>
        <TripLoadMap plan={activePlan} products={products} clients={clients} onChange={setPlan} />
        <label className="block">Instrucciones / reacomodos / horarios<input className={input} value={plan.notes} onChange={e=>setPlan({...plan,notes:e.target.value})} /></label>
        {validationIssues.length > 0 && <div ref={validationRef} tabIndex={-1} role="alert" className="border border-danger rounded-xl p-4 bg-red-50 text-danger space-y-2">
            <p className="font-bold">{submitAttempted ? 'No se guardó la unidad. Corrige los siguientes datos:' : 'Antes de guardar, corrige los siguientes datos:'}</p>
            <ul className="list-disc pl-5 text-sm">{validationIssues.map(message => <li key={message}>{message}</li>)}</ul>
            {result.errors.some(message => message.includes('temperatura')) && <button type="button" className="underline font-bold" onClick={() => { temperatureRef.current?.scrollIntoView({ behavior: 'smooth', block: 'center' }); temperatureRef.current?.focus({ preventScroll: true }); }}>Revisar temperatura de salida</button>}
        </div>}
        {error&&<p role="alert" className="text-danger">{error}</p>}
        <div className="flex justify-end gap-3"><button type="button" disabled={saving} onClick={onClose}>Cancelar</button><button type="submit" disabled={saving} className="bg-primary text-white px-5 py-2 rounded-lg disabled:opacity-50">{saving?'Guardando...':'Guardar unidad y recalcular remanentes'}</button></div>
    </form></div>,document.body);
}
