import type { StrategicProjection } from '../types';
export interface BoxMetric { proyecto_id: string; producto_id: string; client_id: string | null; projection_id: string | null; anio: number; concepto: string; cajas: number }
export function metricBoxes(rows: BoxMetric[], p: StrategicProjection, concept: string, clientId?: string): number | null {
    const byClient = concept === 'cliente_recibido' || concept === 'cliente_enviado_semana';
    const matches = rows.filter(r => r.concepto === concept && r.proyecto_id === p.proyectoId && r.producto_id === p.productoId && (!byClient || r.client_id === clientId) && (concept !== 'real_meta' || r.projection_id === p.id));
    return matches.length ? matches.reduce((sum, r) => sum + Number(r.cajas), 0) : (['real_meta', 'enviado_anual', 'ng_semana', 'cliente_enviado_semana'].includes(concept) ? 0 : null);
}
