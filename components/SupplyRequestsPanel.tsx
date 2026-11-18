import React, { useState } from 'react';
import { supabase } from '../lib/supabase';
import { UserRole, type User, type ProyectoDB } from '../types';
import type { SupplyRequest } from '../transportTypes';
export default function SupplyRequestsPanel({ user, projects, requests, refresh }: { user: User; projects: ProyectoDB[]; requests: SupplyRequest[]; refresh: () => Promise<void> }) {
    const [open, setOpen] = useState(false), [saving, setSaving] = useState(false), [error, setError] = useState('');
    const [request, setRequest] = useState({ project_id: '', supplier: '', address: '', description: '', pallets: 1, weight_kg: 0, requested_date: '', reference: '' });
    const canBuy = [UserRole.COMPRAS, UserRole.ADMINISTRADOR].includes(user.role);
    const save = async (e: React.FormEvent) => {
        e.preventDefault(); setSaving(true); setError('');
        const { error } = await supabase.from('usa_solicitudes_insumos').insert(request);
        if (error) setError(error.message); else { await refresh(); setOpen(false); }
        setSaving(false);
    };
    const input = 'border border-border rounded p-2 bg-background w-full';
    return <section className="bg-surface border border-border rounded-xl p-4 space-y-3">
        <div className="flex justify-between"><h2 className="font-black text-primary">Compras · Recolección de insumos</h2>{canBuy && <button onClick={() => setOpen(!open)} className="text-primary underline">Nueva solicitud</button>}</div>
        <p className="text-xs text-text-secondary">Logística: abre una unidad sugerida o «Editar / añadir recolección» en un viaje. En el formulario elige «Asignar recolección de Compras», selecciona la solicitud, revisa las paradas y guarda el viaje.</p>
        {requests.length === 0 && <p className="text-xs text-text-secondary">Sin solicitudes en este periodo.</p>}
        {requests.map(r => <div key={r.id} className="text-sm border-t border-border pt-2"><strong>{r.supplier} → {projects.find(p => p.id === r.projectId)?.nombre}</strong> · {r.requestedDate} · {r.pallets} posiciones · {r.weightKg} kg · {r.status}<p>{r.description} · {r.reference}</p></div>)}
        {open && <form onSubmit={save} className="grid md:grid-cols-3 gap-3">
            <label>Proyecto receptor<select required className={input} value={request.project_id} onChange={e => setRequest({ ...request, project_id: e.target.value })}><option value="">Seleccionar...</option>{projects.map(p => <option key={p.id} value={p.id}>{p.nombre}</option>)}</select></label>
            {(['supplier','address','description','reference'] as const).map((key, i) => <label key={key}>{['Proveedor','Dirección de recolección','Insumos / cantidades','Orden de compra / contacto'][i]}<input required className={input} value={request[key]} onChange={e => setRequest({ ...request, [key]: e.target.value })} /></label>)}
            <label>Fecha de recolección<input required type="date" className={input} value={request.requested_date} onChange={e => setRequest({ ...request, requested_date: e.target.value })} /></label>
            <label>Posiciones equivalentes<input required type="number" min="1" step="1" className={input} value={request.pallets} onChange={e => setRequest({ ...request, pallets: Number(e.target.value) })} /></label>
            <label>Peso bruto total (kg)<input required type="number" min="0.001" step="any" className={input} value={request.weight_kg} onChange={e => setRequest({ ...request, weight_kg: Number(e.target.value) })} /></label>
            <button disabled={saving} className="bg-primary text-white rounded p-2">Enviar a Logística</button>
        </form>}{error && <p role="alert" className="text-danger">{error}</p>}
    </section>;
}
