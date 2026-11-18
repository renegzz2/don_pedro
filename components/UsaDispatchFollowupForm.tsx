import React, {useState} from 'react';
import {createPortal} from 'react-dom';
import type {UsaShipmentReport, ProductoDB, ClienteDB, EstatusDB, ResponsableDB} from '../types';
import {localDateTime} from '../utils/commercialPlanning';

interface Props {
    report: UsaShipmentReport; onClose: () => void;
    onSubmit: (data: any, status: string) => void | Promise<void>;
    productSpecs: ProductoDB[]; clientes: ClienteDB[]; logisticStatuses: EstatusDB[]; responsables: ResponsableDB[];
}
export default function UsaDispatchFollowupForm({report,onClose,onSubmit,productSpecs,clientes,logisticStatuses,responsables}:Props) {
    const [saving,setSaving]=useState(false);
    const [values,setValues]=useState({
        logisticStatus:report.logisticStatus || 'En ruta',driverPhone:report.driverPhone || '',sealNumber:report.sealNumber || '',
        responsibleId:report.responsibleId || '',caat:report.caat || '',alpha:report.alpha || '',transferAgent:report.transferAgent || '',
        transferPhone:report.transferPhone || '',freightCost:String(report.freightCost ?? ''),tiveTrackerId:report.tiveTrackerId || '',
        comments:report.comments || '',expectedArrival:report.expectedArrival ? localDateTime(new Date(report.expectedArrival)) : '',
    });
    const input='w-full border border-border rounded-lg p-2 text-sm bg-white text-primary';
    const textFields=[['driverPhone','Teléfono del operador'],['sealNumber','Sello'],['caat','CAAT'],['alpha','Alpha'],
        ['transferAgent','Agente de transfer'],['transferPhone','Teléfono de transfer'],['tiveTrackerId','Dispositivo Tive (si está instalado)']] as const;
    const statuses=[...new Set([values.logisticStatus,'En ruta',...logisticStatuses.map(s=>s.nombre)])]
        .filter(s=>s===values.logisticStatus || !['finalizado','confirmado','programado','unidad en empaque','pendiente'].includes(s.trim().toLowerCase()));
    return createPortal(<div className="fixed inset-0 z-[100] bg-black/60 flex items-center justify-center p-4" role="dialog" aria-modal="true" aria-label="Seguimiento del despacho">
        <form className="bg-white rounded-2xl max-w-4xl w-full max-h-[92vh] overflow-auto p-6 space-y-5" onSubmit={async e=>{
            e.preventDefault(); if(saving)return; setSaving(true);
            try { await onSubmit({id:report.id,tripId:report.tripId,...values,
                responsibleId:values.responsibleId || null,freightCost:values.freightCost===''?null:Number(values.freightCost),
                tiveTrackerId:values.tiveTrackerId.trim() || null,
                expectedArrival:values.expectedArrival ? new Date(values.expectedArrival).toISOString() : null},values.logisticStatus); }
            finally {setSaving(false);}
        }}>
            <div className="flex justify-between gap-4"><div><h2 className="font-bold text-xl text-primary">Seguimiento del despacho</h2><p className="text-sm break-all">{report.tripId}</p></div><button type="button" onClick={onClose} aria-label="Cerrar">✕</button></div>
            <section className="bg-slate-50 border rounded-xl p-4 space-y-2 text-sm">
                <h3 className="font-bold text-primary">Salida confirmada por Embarques</h3>
                <p>{report.project} · {(report.clientIds || [report.clientId]).map(id=>clientes.find(c=>c.id===id)?.nombre).filter(Boolean).join(' / ')}</p>
                <p>Salida real: {report.realDepartureDate ? new Date(report.realDepartureDate).toLocaleString('es-MX') : 'Sin registro'}</p>
                <p>{report.unitType} · Operador: {report.driverName || '—'} · Tractor: {report.tractorPlates || '—'} · Caja: {report.boxNumber || '—'}</p>
                <p>Económico: {report.economicNumber || '—'} · Pies: {report.trailerFeet || '—'} · Termógrafo: {report.thermographSerial || '—'}</p>
                <p>Temperatura programada: {report.idealTemp ?? '—'} °F · Continuo: {report.continuousMode || 'Sin confirmar'}</p>
                <p>Los datos confirmados se corrigen desde Programación o Embarques. Completa aquí el seguimiento del recorrido.</p>
            </section>
            <section className="space-y-2"><h3 className="font-bold text-primary">Carga real · {Number(report.totalRealBoxes || 0).toLocaleString()} cajas embarcadas acumuladas</h3>
                {(report.products || []).map((p:any,i)=><div key={i} className="border-b pb-1 text-sm">
                    {productSpecs.find(s=>s.id===p.productId)?.nombreDelProducto || p.manualProductName || 'Producto'} · {clientes.find(c=>c.id===p.clientId)?.nombre || 'Cliente'} · {p.realQty || 0} cajas
                </div>)}
                <p className="text-xs text-slate-500">Incluye las cargas ya registradas de cada punto. Las recolecciones futuras permanecen en el recorrido programado.</p>
            </section>
            {report.routePlan?.stops?.length ? <section className="space-y-2"><h3 className="font-bold text-primary">Recorrido programado</h3>{report.routePlan.stops.map(s=><div key={s.id} className="border rounded p-2 text-sm"><strong>{s.name}</strong> · {s.at ? new Date(s.at).toLocaleString('es-MX') : 'Sin horario'}<p>{s.address}</p><p>{s.completedAt ? `Confirmada: ${new Date(s.completedAt).toLocaleString('es-MX')}` : 'Pendiente de confirmar en Unidades sugeridas'}</p></div>)}</section> : null}
            {report.sourceAudit?.some(a=>a.inspectionPending || a.differences?.length) && <p role="status" className="rounded bg-amber-50 p-3 text-sm text-amber-800">Embarques reportó observaciones de auditoría. Revisa la salida correspondiente; el despacho conserva esas observaciones.</p>}
            <div className="grid md:grid-cols-2 gap-4">
                <label>Estatus logístico<select className={input} value={values.logisticStatus} onChange={e=>setValues({...values,logisticStatus:e.target.value})}>{statuses.map(s=><option key={s}>{s}</option>)}</select></label>
                <label>Responsable<select className={input} value={values.responsibleId} onChange={e=>setValues({...values,responsibleId:e.target.value})}><option value="">Sin asignar</option>{responsables.map(r=><option key={r.id} value={r.id}>{r.nombre}</option>)}</select></label>
                {textFields.map(([field,label])=><label key={field}>{label}<input className={input} value={values[field]} onChange={e=>setValues({...values,[field]:e.target.value})}/></label>)}
                <label>Costo de flete (USD)<input type="number" min="0" step="0.01" className={input} value={values.freightCost} onChange={e=>setValues({...values,freightCost:e.target.value})}/></label>
                <label>Llegada estimada<input type="datetime-local" className={input} value={values.expectedArrival} onChange={e=>setValues({...values,expectedArrival:e.target.value})}/></label>
            </div>
            <p className="text-xs text-slate-500">El termógrafo y el dispositivo Tive son identificadores distintos. Registra el Tive únicamente si la unidad lo tiene instalado.</p>
            <label className="block">Comentarios de seguimiento<textarea className={input} value={values.comments} onChange={e=>setValues({...values,comments:e.target.value})}/></label>
            <div className="flex justify-end gap-3"><button type="button" onClick={onClose}>Cancelar</button><button disabled={saving} className="bg-primary text-white rounded-lg p-3 font-bold">{saving?'Guardando…':'Guardar seguimiento'}</button></div>
        </form>
    </div>,document.body);
}
