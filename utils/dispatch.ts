import { UserRole, View, type UsaShipmentReport, type Incident } from '../types';

export const trafficViews = [View.SETTINGS, View.USA_SHIPMENTS, View.TIVE_MAP];
export function canManageUsaDispatch(role?: UserRole) {
    return !!role && [UserRole.TRAFICO_RI, UserRole.ADMINISTRADOR, UserRole.COORDINADOR,
        UserRole.SUBGERENCIA, UserRole.ADMINISTRATIVO, UserRole.GERENCIA].includes(role);
}
export function isActiveUsaDispatch(status?: string) {
    return !['finalizado','cancelado'].includes((status || '').trim().toLowerCase());
}
export const dispatchFollowupFields = ['logisticStatus','driverPhone','sealNumber','responsibleId','caat','alpha',
    'transferAgent','transferPhone','freightCost','tiveTrackerId','comments','expectedArrival'] as const;
export function dispatchFollowupPatch(data: Record<string, unknown>) {
    return Object.fromEntries(dispatchFollowupFields.filter(k => k in data).map(k => [k,data[k]]));
}
export function dispatchNextStop(report: UsaShipmentReport) {
    const stops = report.routePlan?.stops || [];
    const loaded = new Set((report.sourceManifest || []).map(p => p.pickupStopId));
    const lastPickup = stops.reduce((last,s,i) => loaded.has(s.id) ? i : last,-1);
    return stops.find((s,i) => i>lastPickup && !s.completedAt);
}
export function dispatchTargetIds(report: UsaShipmentReport) {
    const stop = dispatchNextStop(report);
    const cargo = report.routePlan?.cargo || [];
    const clients = [...new Set(cargo.filter(c=>c.unloadStopId===stop?.id).map(c=>c.clientId).filter(Boolean))];
    const projects = [...new Set(cargo.filter(c=>c.loadStopId===stop?.id).map(c=>c.projectId).filter(Boolean))];
    return {stop,clientId:clients.length===1?clients[0]:undefined,projectId:projects.length===1?projects[0]:undefined};
}
export function dispatchIncidents(value: unknown): Incident[] {
    if (Array.isArray(value)) return value;
    if (typeof value==='string') { try { const parsed=JSON.parse(value); return Array.isArray(parsed)?parsed:[]; } catch { return []; } }
    return [];
}
