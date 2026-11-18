import React, { useState } from 'react';
import type { TripPlan } from '../transportTypes';
import type { ProductoDB, ClienteDB } from '../types';
import { evaluateTrip, KG_TO_LB } from '../utils/tripPlanning';
export default function TripLoadMap({ plan, products, clients, onChange }: { plan: TripPlan; products: ProductoDB[]; clients: ClienteDB[]; onChange?: (plan: TripPlan) => void }) {
    const [stage, setStage] = useState(0), [colorBy, setColorBy] = useState('product'), [selected, setSelected] = useState('');
    const result = evaluateTrip(plan, products), index = Math.min(stage, Math.max(0, result.segments.length - 1));
    const segment = result.segments[index];
    const palette = ['#dbeafe','#dcfce7','#fef3c7','#fae8ff','#ffedd5','#cffafe'];
    const keys = [...new Set(result.pallets.map(p => colorBy === 'client' ? p.clientId || 'insumos' : p.productId || p.cargoId))];
    const move = (position: number) => {
        if (!onChange || !selected) return;
        const pallet = result.pallets.find(p => p.id === selected); if (!pallet) return;
        const other = segment?.pallets.find(p => p.position === position);
        if (plan.stops[pallet.loadIndex]?.completedAt || (other && plan.stops[other.loadIndex]?.completedAt)) return;
        const cargo = plan.cargo.map(c => ({ ...c, positions: result.pallets.filter(p => p.cargoId === c.id).map(p => p.id === selected ? position : other?.id === p.id ? pallet.position : p.position) }));
        onChange({ ...plan, cargo }); setSelected('');
    };
    return <section className="border border-border rounded-xl p-4 space-y-3">
        <div className="flex gap-3 flex-wrap items-center"><h3 className="font-black text-primary">Mapa de la caja</h3>
            <select aria-label="Tramo del mapa" className="border border-border p-2 bg-background rounded" value={index} onChange={e => { setStage(Number(e.target.value)); setSelected(''); }}>{plan.stops.slice(0,-1).map((s,i) => <option key={s.id} value={i}>Salida de {s.name}</option>)}</select>
            <select aria-label="Colorear pallets por" className="border border-border p-2 bg-background rounded" value={colorBy} onChange={e => setColorBy(e.target.value)}><option value="product">Color por producto</option><option value="client">Color por cliente</option></select>
        </div>
        {result.departure.value != null && <p className="text-sm font-bold text-primary">Temperatura de salida: {result.departure.value} °F · {plan.stops.find(s => s.id === result.departure.originStopId)?.name || 'Punto A'}</p>}
        {segment && <p className="text-sm">{segment.pallets.length}/{plan.equipment.capacity} posiciones · {segment.weightLb.toFixed(0)} lb / {(segment.weightLb / KG_TO_LB).toFixed(0)} kg · {segment.temperature ? `Rango de la carga: ${segment.temperature.min} ≤ T < ${segment.temperature.max} °F` : 'Sin control térmico requerido en este tramo'} · {segment.freePallets} posiciones libres en este tramo</p>}
        <div className="max-w-xl mx-auto"><div className="bg-primary text-white text-center rounded-t-xl p-2 text-xs">FRENTE · TERMOGRAFO / REFRIGERACIÓN</div>
            <div className="grid grid-cols-2 gap-1 border-x-4 border-primary bg-slate-100 p-2">
                {Array.from({length: Math.min(100, plan.equipment.capacity)}, (_,position) => {
                    const p = segment?.pallets.find(p => p.position === position);
                    const future = result.pallets.find(p => p.position === position && p.loadIndex > index);
                    const key = p && (colorBy === 'client' ? p.clientId || 'insumos' : p.productId || p.cargoId);
                    return <button type="button" key={position} disabled={!onChange} onClick={() => selected ? move(position) : p && !plan.stops[p.loadIndex]?.completedAt && setSelected(p.id)} style={{backgroundColor: p ? palette[keys.indexOf(key!) % palette.length] : 'white'}} className={`min-h-20 border rounded p-2 text-left text-slate-900 text-xs ${selected === p?.id ? 'ring-2 ring-primary' : 'border-slate-300'}`}>
                        <strong>Pos. {position + 1} · {p?.description || 'Disponible'}</strong>
                        {p ? <><div>{p.boxes ? `${p.boxes} cjs · ` : ''}{p.weightKg.toFixed(1)} kg / {(p.weightKg * KG_TO_LB).toFixed(0)} lb</div><div>{clients.find(c => c.id === p.clientId)?.nombre || 'Insumos'}</div><div>Descarga: {plan.stops[p.unloadIndex]?.name}</div></> : future && <div className="text-amber-800">Reserva futura: {future.description}</div>}
                    </button>;
                })}
            </div><div className="bg-primary text-white text-center rounded-b-xl p-2 text-xs">PUERTAS · ACCESO DE CARGA Y DESCARGA</div>
        </div>
        {onChange && <p className="text-xs text-text-secondary">Selecciona un pallet y su nueva posición para moverlo o intercambiarlo. La carga especial se representa por posiciones equivalentes; el reparto uniforme de su peso debe confirmarse antes de salida.</p>}
        {segment?.axles && <div className="grid grid-cols-3 gap-2 text-xs">{segment.axles.map((w,i) => <div key={i} className="bg-primary/5 rounded p-2">{['Dirección','Motrices tractor','Tándem caja'][i]}<strong className="block">{w.toFixed(0)} / {plan.equipment.axleLimitsLb?.[i] || '—'} lb</strong></div>)}</div>}
        <p className="text-xs text-text-secondary">Distribución estimada según posiciones y geometría. No sustituye el pesaje real ni valida por sí sola la ruta de Texas.</p>
        {result.errors.map(e => <p key={e} role="alert" className="text-danger text-xs">{e}</p>)}
        {result.warnings.map(w => <p key={w} className="text-amber-700 text-xs">{w}</p>)}
    </section>;
}
