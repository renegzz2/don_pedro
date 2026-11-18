import React, { useState } from 'react';
import { supabase } from '../lib/supabase';
import type { TransportSpec } from '../transportTypes';
export default function TransportSpecEditor({ units, onSaved }: { units: TransportSpec[]; onSaved: () => Promise<void> }) {
    const [unit, setUnit] = useState<TransportSpec | null>(null), [saving,setSaving]=useState(false), [error,setError]=useState('');
    const save=async()=>{if(!unit)return;setSaving(true);setError('');
        const {error}=await supabase.from('tipo_unidad').update({carga_util_lb:unit.payloadLb,peso_bruto_max_lb:unit.grossLb,refrigerada:!!unit.refrigerated,temperatura_min_f:unit.minF,temperatura_max_f:unit.maxF,tara_pallet_kg:unit.palletTareKg,limites_ejes_lb:unit.axleLimitsLb}).eq('id',unit.id);
        if(error)setError(error.message);else{await onSaved();setUnit(null);}setSaving(false);
    };
    return <details className="border border-border rounded-xl p-3"><summary className="font-bold text-primary">Configurar capacidades de transporte</summary>
        <p className="text-xs my-2">Captura límites operativos confirmados para Texas. No se asignan capacidades de peso ni permisos de sobrepeso automáticamente.</p>
        <select aria-label="Tipo a configurar" className="border border-border p-2 bg-background rounded" value={unit?.id||''} onChange={e=>setUnit(structuredClone(units.find(u=>u.id===e.target.value)||null))}><option value="">Seleccionar...</option>{units.map(u=><option key={u.id} value={u.id}>{u.name}</option>)}</select>
        {unit&&<div className="grid md:grid-cols-3 gap-3 mt-3">
            {(['payloadLb','grossLb','palletTareKg','minF','maxF'] as const).map((key,i)=><label key={key}>{['Carga útil (lb)','Peso bruto máximo (lb)','Tara pallet (kg)','Mínima del equipo °F','Máxima del equipo °F'][i]}<input type="number" step="any" className="border border-border rounded p-2 bg-background w-full" value={unit[key]??''} onChange={e=>setUnit({...unit,[key]:e.target.value===''?null:Number(e.target.value)})}/></label>)}
            <label><input type="checkbox" checked={!!unit.refrigerated} onChange={e=>setUnit({...unit,refrigerated:e.target.checked})}/> Equipo refrigerado</label>
            {[0,1,2].map(i=><label key={i}>Límite {['dirección','motrices','tándem caja'][i]} (lb)<input type="number" step="any" min="1" className="border border-border rounded p-2 bg-background w-full" value={unit.axleLimitsLb?.[i]??''} onChange={e=>{const limits=[...(unit.axleLimitsLb||[0,0,0])];limits[i]=Number(e.target.value);setUnit({...unit,axleLimitsLb:limits});}}/></label>)}
            <button type="button" disabled={saving} onClick={save} className="bg-primary text-white rounded p-2">Guardar configuración</button>
        </div>}{error&&<p role="alert" className="text-danger">{error}</p>}
    </details>;
}
