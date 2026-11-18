import React, { useState } from 'react';
import { createPortal } from 'react-dom';
import { supabase } from '../lib/supabase';
import type { FreightSchedule, LineaTransporteDB, StrategicProjection } from '../types';
import { localDateTime } from '../utils/commercialPlanning';

interface Props {
    projection: StrategicProjection;
    day: string;
    quantity: number;
    unitLabel: string;
    description: string;
    carriers: LineaTransporteDB[];
    schedules: FreightSchedule[];
    onClose: () => void;
    onSaved: () => Promise<void>;
}

export default function FreightScheduleModal({ projection, day, quantity, unitLabel, description, carriers, schedules, onClose, onSaved }: Props) {
    const booked = schedules.reduce((sum, s) => sum + s.quantity, 0);
    const [editingId, setEditingId] = useState('');
    const [carrierId, setCarrierId] = useState('');
    const [arrivalAt, setArrivalAt] = useState(`${day}T08:00`);
    const [boxes, setBoxes] = useState(Math.max(0, quantity - booked));
    const [unit, setUnit] = useState(unitLabel);
    const [notes, setNotes] = useState('');
    const [saving, setSaving] = useState(false);
    const [error, setError] = useState('');
    const reset = () => { setEditingId(''); setCarrierId(''); setBoxes(Math.max(0, quantity - booked)); setNotes(''); setUnit(unitLabel); };
    const save = async (event: React.FormEvent) => {
        event.preventDefault();
        if (saving) return;
        const otherBooked = schedules.filter(s => s.id !== editingId).reduce((sum, s) => sum + s.quantity, 0);
        if (!projection.clientId) { setError('Comercial debe indicar el cliente de esta meta.'); return; }
        if (!carrierId || !arrivalAt || !Number.isInteger(boxes) || boxes <= 0 || boxes + otherBooked > quantity) {
            setError('Selecciona proveedor, fecha de llegada y cajas positivas sin superar lo solicitado para el día.'); return;
        }
        setSaving(true); setError('');
        try {
            const payload = { projection_id: projection.id, scheduled_date: day, arrival_at: new Date(arrivalAt).toISOString(), carrier_id: carrierId, quantity: boxes, unit_label: unit, notes };
            const result = editingId
                ? await supabase.from('usa_programacion_fletes').update(payload).eq('id', editingId)
                : await supabase.from('usa_programacion_fletes').insert(payload);
            if (result.error) throw result.error;
            await onSaved(); onClose();
        } catch (e: any) { setError(e.message); } finally { setSaving(false); }
    };
    const remove = async (id: string) => {
        if (saving || !window.confirm('¿Retirar este flete de la programación?')) return;
        setSaving(true); setError('');
        try {
            const { error } = await supabase.from('usa_programacion_fletes').delete().eq('id', id);
            if (error) throw error;
            await onSaved(); onClose();
        } catch (e: any) { setError(e.message); } finally { setSaving(false); }
    };
    const input = 'w-full border border-border bg-background text-text-primary rounded-lg p-2 mt-1';
    return createPortal(
        <div className="fixed inset-0 bg-black/70 z-[180] flex items-center justify-center p-4">
            <form onSubmit={save} className="bg-surface rounded-2xl shadow-xl max-w-lg w-full max-h-[95vh] overflow-y-auto p-6 space-y-4">
                <h2 className="font-black text-primary uppercase">Programar flete · {day}</h2>
                <p className="text-sm text-text-secondary">{description}</p>
                <p className="text-sm">Solicitud de Comercial: <strong>{quantity.toLocaleString()} cajas</strong>. Programadas: {booked.toLocaleString()}.</p>
                {error && <p role="alert" className="text-danger text-sm">{error}</p>}
                {schedules.map(s => <div key={s.id} className="border border-border rounded-lg p-3 text-sm">
                    <p>{carriers.find(c => c.id === s.carrierId)?.nombre || 'Proveedor'} · {s.quantity} cjs · {s.unitLabel}</p>
                    <p>Llegada al empaque: {new Date(s.arrivalAt).toLocaleString()}</p>
                    <button type="button" disabled={saving} className="text-primary mr-4 underline" onClick={() => {
                        setEditingId(s.id); setCarrierId(s.carrierId); setArrivalAt(localDateTime(new Date(s.arrivalAt)));
                        setBoxes(s.quantity); setUnit(s.unitLabel); setNotes(s.notes || '');
                    }}>Editar</button>
                    <button type="button" disabled={saving} className="text-danger underline" onClick={() => remove(s.id)}>Retirar</button>
                </div>)}
                {editingId && <button type="button" onClick={reset} className="text-primary underline">Agregar otro flete</button>}
                <label className="block text-sm">Proveedor de transporte
                    <select required className={input} value={carrierId} onChange={e => setCarrierId(e.target.value)}>
                        <option value="">Seleccionar proveedor...</option>
                        {carriers.map(c => <option key={c.id} value={c.id}>{c.nombre}</option>)}
                    </select>
                </label>
                <label className="block text-sm">Fecha y hora de llegada del transporte al empaque
                    <input required type="datetime-local" className={input} value={arrivalAt} onChange={e => setArrivalAt(e.target.value)} />
                </label>
                <label className="block text-sm">Cajas asignadas a este flete
                    <input required type="number" min="1" step="1" className={input} value={boxes} onChange={e => setBoxes(Number(e.target.value))} />
                </label>
                <label className="block text-sm">Unidades requeridas
                    <input required className={input} value={unit} onChange={e => setUnit(e.target.value)} />
                </label>
                <label className="block text-sm">Observaciones
                    <textarea className={input} value={notes} onChange={e => setNotes(e.target.value)} />
                </label>
                <div className="flex justify-end gap-3">
                    <button disabled={saving} type="button" onClick={onClose}>Cancelar</button>
                    <button disabled={saving} type="submit" className="bg-primary text-white px-5 py-2 rounded-lg">{saving ? 'Guardando...' : editingId ? 'Guardar cambios' : 'Programar flete'}</button>
                </div>
            </form>
        </div>, document.body
    );
}
