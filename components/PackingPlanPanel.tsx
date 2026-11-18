import React, { useState } from 'react';
import { supabase } from '../lib/supabase';
import type { StrategicProjection, ProyectoDB, ProductoDB, ClienteDB } from '../types';
import { fiscalPeriod } from '../utils/commercialPlanning';
import { packingTotal } from '../utils/packingPlanning';

interface Props {
    goals: StrategicProjection[]; projects: ProyectoDB[]; products: ProductoDB[]; clients: ClienteDB[];
    days: { dateString: string; formatted: string; name: string }[];
    canEdit: boolean; onSaved: () => Promise<void>;
}
export default function PackingPlanPanel({ goals, projects, products, clients, days, canEdit, onSaved }: Props) {
    const [editing, setEditing] = useState<StrategicProjection | null>(null);
    const [plan, setPlan] = useState<Record<string, number>>({});
    const [saving, setSaving] = useState(false);
    const [error, setError] = useState('');
    const total = Object.values(plan).reduce((sum, n) => sum + n, 0);
    const save = async () => {
        if (!editing || saving) return;
        if (Object.values(plan).some(n => !Number.isInteger(n) || n < 0) || total > editing.proyeccionCajas) {
            setError('Captura cajas enteras y positivas sin superar la meta comercial.'); return;
        }
        setSaving(true); setError('');
        try {
            const { error } = await supabase.rpc('save_packing_plan', {
                p_goal_id: editing.id,
                p_plan: Object.entries(plan).filter(([, cantidad]) => cantidad > 0).map(([fecha, cantidad]) => ({ fecha, cantidad })),
                p_expected: editing.packingPlan || []
            });
            if (error) throw error;
            await onSaved(); setEditing(null);
        } catch (e: any) { setError(e.message); } finally { setSaving(false); }
    };
    return <section className="bg-surface border border-border rounded-2xl p-4 space-y-3">
        <h2 className="text-primary font-black text-sm uppercase">Programación de empaque</h2>
        <p className="text-xs text-text-secondary">El líder distribuye las cajas de cada meta entre los días de la semana. Las unidades se calculan con esta programación.</p>
        <div className="overflow-x-auto"><table className="w-full text-xs text-left">
            <thead><tr><th className="p-2">Proyecto / Cliente / Producto</th><th className="p-2">Meta comercial</th><th className="p-2">Programadas por empaque</th><th className="p-2">Pendientes de programar</th>{canEdit && <th />}</tr></thead>
            <tbody>{goals.map(g => <tr key={g.id} className="border-t border-border">
                <td className="p-2">{projects.find(p => p.id === g.proyectoId)?.nombre} / {clients.find(c => c.id === g.clientId)?.nombre || 'Sin cliente'}<br /><strong>{products.find(p => p.id === g.productoId)?.nombreDelProducto}</strong></td>
                <td className="p-2">{g.proyeccionCajas.toLocaleString()}</td>
                <td className="p-2">{packingTotal(g).toLocaleString()}</td>
                <td className="p-2 font-bold text-amber-700">{Math.max(0, g.proyeccionCajas - packingTotal(g)).toLocaleString()}</td>
                {canEdit && <td className="p-2"><button disabled={saving} className="text-primary underline" onClick={() => {
                    setEditing(g); setError(''); setPlan(Object.fromEntries((g.packingPlan || []).map(d => [d.fecha.slice(0, 10), d.cantidad])));
                }}>Distribuir cajas</button></td>}
            </tr>)}</tbody>
        </table></div>
        {editing && <div className="border border-primary/30 rounded-xl p-4 space-y-3">
            <h3 className="font-bold">{products.find(p => p.id === editing.productoId)?.nombreDelProducto} · Meta: {editing.proyeccionCajas.toLocaleString()} cajas</h3>
            <div className="flex gap-3 flex-wrap">{days.filter(d => {
                const period = fiscalPeriod(new Date(`${d.dateString}T12:00:00`));
                return period.week === editing.semanaFiscal && period.year === editing.planningYear;
            }).map(d => <label className="text-xs" key={d.dateString}>{d.name} {d.formatted}
                <input aria-label={`Cajas ${d.dateString}`} type="number" min="0" step="1" disabled={saving} className="block border border-border bg-background rounded p-2 w-24" value={plan[d.dateString] || ''} onChange={e => setPlan(prev => ({ ...prev, [d.dateString]: Number(e.target.value) }))} />
            </label>)}</div>
            <p className="text-sm">Programadas: {total.toLocaleString()} · Pendientes: {Math.max(0, editing.proyeccionCajas - total).toLocaleString()}</p>
            {error && <p role="alert" className="text-danger text-sm">{error}</p>}
            <div className="flex gap-4"><button disabled={saving} onClick={save} className="bg-primary text-white rounded-lg px-4 py-2">{saving ? 'Guardando...' : 'Guardar programación'}</button>
                <button disabled={saving} onClick={() => setEditing(null)}>Cancelar</button></div>
        </div>}
    </section>;
}
