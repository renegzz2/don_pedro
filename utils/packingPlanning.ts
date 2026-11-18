import type { ProductoDB, StrategicProjection } from '../types';
import { commercialQuantityForDay } from './commercialPlanning';

export interface TransportType { id: string; name: string; capacity: number }
export interface LoadAllocation { projectionId: string; productId: string; quantity: number }
export interface SuggestedLoad { unit: TransportType; pallets: number; allocations: LoadAllocation[] }

export const packingTotal = (goal: StrategicProjection) =>
    (goal.packingPlan || []).reduce((sum, d) => sum + Number(d.cantidad || 0), 0);

// A pallet contains a single product. Goals for the same product may share it.
export function consolidateLoads(goals: StrategicProjection[], day: string, products: ProductoDB[], types: TransportType[], booked: Record<string, number> = {}): SuggestedLoad[] {
    if (new Set(goals.map(g => g.proyectoId)).size > 1) throw new Error('Solo se consolidan metas del mismo proyecto.');
    const units = types.filter(t => Number.isFinite(t.capacity) && t.capacity >= 1).map(t => ({ ...t, capacity: Math.floor(t.capacity) })).sort((a, b) => a.capacity - b.capacity);
    if (!units.length) return [];
    const largest = units[units.length - 1];
    const loads: SuggestedLoad[] = [];
    let current: SuggestedLoad = { unit: largest, pallets: 0, allocations: [] };
    let productBoxes = 0;
    let lastProduct = '';
    const finish = () => {
        if (!current.allocations.length) return;
        current.unit = units.find(t => t.capacity >= current.pallets)!;
        loads.push(current);
        current = { unit: largest, pallets: 0, allocations: [] };
        productBoxes = 0;
        lastProduct = '';
    };
    for (const goal of [...goals].sort((a, b) => a.productoId.localeCompare(b.productoId) || a.id.localeCompare(b.id))) {
        let remaining = Math.max(0, commercialQuantityForDay(goal, day) - (booked[goal.id] || 0));
        const perPallet = products.find(p => p.id === goal.productoId)?.cajasPalletUsa;
        // Unknown pallet configuration must be corrected before suggesting transport.
        if (remaining && (!perPallet || perPallet < 1)) throw new Error('Configura las cajas por pallet de todos los productos antes de consolidar.');
        if (!remaining) continue;
        if (lastProduct !== goal.productoId) productBoxes = 0;
        lastProduct = goal.productoId;
        while (remaining > 0) {
            const partialSpace = productBoxes % perPallet! ? perPallet! - productBoxes % perPallet! : 0;
            const space = (largest.capacity - current.pallets) * perPallet! + partialSpace;
            if (space <= 0) { finish(); lastProduct = goal.productoId; continue; }
            const quantity = Math.min(remaining, space);
            const before = Math.ceil(productBoxes / perPallet!);
            productBoxes += quantity;
            current.pallets += Math.ceil(productBoxes / perPallet!) - before;
            current.allocations.push({ projectionId: goal.id, productId: goal.productoId, quantity });
            remaining -= quantity;
        }
    }
    finish();
    return loads;
}
