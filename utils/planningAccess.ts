import { View, UserRole } from '../types';
export const PLANNING_SECTIONS = [
    { view: View.PACKING_PLANNING, label: 'Programación de empaque', roles: [UserRole.ADMINISTRADOR, UserRole.LIDER_PROYECTO] as UserRole[] },
    { view: View.SUPPLY_COLLECTION, label: 'Compras · Recolección de insumos', roles: [UserRole.ADMINISTRADOR, UserRole.COMPRAS] as UserRole[] },
    { view: View.TRANSPORT_PLANNING, label: 'Unidades sugeridas · cajas pendientes de asignar', roles: [UserRole.ADMINISTRADOR, UserRole.TRAFICO_RI] as UserRole[] }
];
export function planningSectionAccess(view: View, role: UserRole): boolean | undefined {
    const section = PLANNING_SECTIONS.find(s => s.view === view);
    return section ? section.roles.includes(role) : undefined;
}
export function initialViewForRole(role: UserRole): View {
    if (role === UserRole.COMPRAS) return View.SUPPLY_COLLECTION;
    if (role === UserRole.TRAFICO_RI) return View.TRANSPORT_PLANNING;
    if (role === UserRole.LIDER_PROYECTO) return View.PACKING_PLANNING;
    if (role === UserRole.COMERCIAL) return View.STRATEGIC_PLANNING;
    return View.DASHBOARD;
}
