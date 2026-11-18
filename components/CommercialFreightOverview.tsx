import React, { useEffect, useState } from 'react';
import { useCommercialPlanning } from '../hooks/useCommercialPlanning';
import { supabase } from '../lib/supabase';
import { packingTotal } from '../utils/packingPlanning';

export default function CommercialFreightOverview() {
    const { goals, schedules, error, loading, refresh } = useCommercialPlanning();
    const [names, setNames] = useState<Record<string, string>>({});
    useEffect(() => {
        let active = true;
        void Promise.all([
            supabase.from('usa_proyectos').select('id, nombre'),
            supabase.from('usa_productos').select('id, nombre_del_producto'),
            supabase.from('usa_clientes').select('id, nombre'),
            supabase.from('usa_lineas_transporte').select('id, nombre')
        ]).then(results => {
            if (!active) return;
            setNames(Object.fromEntries(results.flatMap(r => (r.data || []).map((row: any) => [row.id, row.nombre || row.nombre_del_producto]))));
        });
        return () => { active = false; };
    }, []);
    return <section className="bg-surface border border-border rounded-2xl p-5 space-y-3">
        <div className="flex justify-between gap-3"><h2 className="font-black text-primary uppercase">Solicitud de Comercial y fletes por recibir</h2>
            <button type="button" onClick={() => refresh()} className="text-primary text-sm underline">Actualizar</button></div>
        {error && <p role="alert" className="text-danger text-sm">{error}</p>}
        {loading ? <p>Cargando programación...</p> : goals.length === 0 ? <p className="text-sm">Comercial aún no ha registrado metas para esta semana.</p> :
            <div className="overflow-x-auto"><table className="w-full text-sm text-left">
                <thead><tr className="border-b border-border"><th className="p-2">Proyecto / Cliente</th><th className="p-2">Producto</th><th className="p-2">Cajas requeridas en la semana</th><th className="p-2">Fletes programados por Tráfico</th></tr></thead>
                <tbody>{goals.map(g => <tr key={g.id} className="border-b border-border">
                    <td className="p-2">{names[g.proyectoId] || 'Proyecto'}<br />{names[g.clientId || ''] || 'Cliente pendiente'}</td>
                    <td className="p-2">{names[g.productoId] || 'Producto'}</td>
                    <td className="p-2">{Number(g.proyeccionCajas || 0).toLocaleString()} cjs
                        <div className="text-xs text-amber-700">Pendientes de programar: {Math.max(0, g.proyeccionCajas - packingTotal(g)).toLocaleString()} cjs</div>
                        {(g.packingPlan || []).map((d, i) => <div key={i} className="text-xs text-text-secondary">{d.fecha.slice(0, 10)}: {d.cantidad} cjs</div>)}
                    </td>
                    <td className="p-2">{schedules.filter(s => s.projectionId === g.id).length === 0 ? 'Pendiente de Tráfico' : schedules.filter(s => s.projectionId === g.id).map(s =>
                        <div key={s.id} className="mb-2"><strong>{names[s.carrierId] || 'Proveedor'} · {s.unitLabel}</strong>
                            <div>{s.loadId && `Unidad compartida ${s.loadId.slice(0, 8)} · `}Llegada al empaque: {new Date(s.arrivalAt).toLocaleString()}</div>
                            <div>Carga: {s.scheduledDate} · {s.quantity} cjs</div>{s.notes && <div>{s.notes}</div>}
                        </div>)}</td>
                </tr>)}</tbody>
            </table></div>}
    </section>;
}
