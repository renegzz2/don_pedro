import React, { useState } from 'react';
import { supabase } from '../lib/supabase';
import type { ProyectoDB, ProductoDB, ClienteDB } from '../types';
export default function HistoricalBoxEditor({ projects, products, clients, year, onSaved }: { projects: ProyectoDB[]; products: ProductoDB[]; clients: ClienteDB[]; year: number; onSaved: () => Promise<void> }) {
    const [open, setOpen] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState('');
    const [data, setData] = useState({ proyecto_id: '', producto_id: '', client_id: '', concepto: 'cliente_recibido', cajas: 0, referencia: '' });
    const save = async (e: React.FormEvent) => {
        e.preventDefault(); if (busy) return; setBusy(true); setError('');
        try {
            if (!Number.isInteger(data.cajas) || data.cajas < 0) throw new Error('Las cajas deben ser enteras y no negativas.');
            const client = data.concepto === 'cliente_recibido' ? data.client_id : null;
            let query = supabase.from('usa_historico_cajas').select('id').eq('proyecto_id', data.proyecto_id).eq('producto_id', data.producto_id).eq('anio', year).eq('concepto', data.concepto);
            query = client ? query.eq('client_id', client) : query.is('client_id', null);
            const found = await query.maybeSingle(); if (found.error) throw found.error;
            const payload = { ...data, client_id: client, anio: year };
            const result = found.data ? await supabase.from('usa_historico_cajas').update(payload).eq('id', found.data.id) : await supabase.from('usa_historico_cajas').insert(payload);
            if (result.error) throw result.error; await onSaved(); setOpen(false);
        } catch (e: any) { setError(e.message); } finally { setBusy(false); }
    };
    const input = 'border border-border rounded-lg p-2 bg-background text-sm w-full';
    return <div><button type="button" className="text-primary underline text-xs" onClick={() => setOpen(!open)}>Capturar / corregir histórico {year}</button>
        {open && <form onSubmit={save} className="border border-border rounded-xl p-4 grid md:grid-cols-3 gap-3 mt-3">
            <label>Proyecto<select required className={input} value={data.proyecto_id} onChange={e => setData({ ...data, proyecto_id: e.target.value })}><option value="">Seleccionar...</option>{projects.map(p => <option key={p.id} value={p.id}>{p.nombre}</option>)}</select></label>
            <label>Producto<select required className={input} value={data.producto_id} onChange={e => setData({ ...data, producto_id: e.target.value })}><option value="">Seleccionar...</option>{products.map(p => <option key={p.id} value={p.id}>{p.nombreDelProducto}</option>)}</select></label>
            <label>Dato histórico<select className={input} value={data.concepto} onChange={e => setData({ ...data, concepto: e.target.value })}><option value="ng_enviado">NG: cajas enviadas</option><option value="cliente_recibido">Cliente: cajas recibidas</option></select></label>
            {data.concepto === 'cliente_recibido' && <label>Cliente<select required className={input} value={data.client_id} onChange={e => setData({ ...data, client_id: e.target.value })}><option value="">Seleccionar...</option>{clients.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}</select></label>}
            <label>Cajas del año {year}<input required type="number" min="0" step="1" className={input} value={data.cajas} onChange={e => setData({ ...data, cajas: Number(e.target.value) })} /></label>
            <label>Fuente / documento<input required className={input} value={data.referencia} onChange={e => setData({ ...data, referencia: e.target.value })} /></label>
            <p className="text-xs md:col-span-3">Guarda el total anual del proyecto/producto; sustituye la referencia anterior para esta combinación.</p>
            {error && <p role="alert" className="text-danger md:col-span-3">{error}</p>}<button disabled={busy} className="bg-primary text-white p-2 rounded-lg">{busy ? 'Guardando...' : 'Guardar histórico'}</button>
        </form>}
    </div>;
}
