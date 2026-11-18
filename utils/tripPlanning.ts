import type { ProductoDB, StrategicProjection, TipoUnidad } from '../types';
import type { TransportSpec, TripPlan, TripCargo, LoadPallet } from '../transportTypes';
import { commercialQuantityForDay } from './commercialPlanning';
import { getTipoUnidadCapacity, getTipoUnidadName } from './formatters';
export const KG_TO_LB = 2.20462262185;
export const fromUnit = (u: TipoUnidad): TransportSpec => ({
    id: String(u.id), name: getTipoUnidadName(u), capacity: Math.floor(getTipoUnidadCapacity(u)),
    payloadLb: u.cargaUtilLb, grossLb: u.pesoBrutoMaxLb, refrigerated: u.refrigerada,
    minF: u.temperaturaMinF, maxF: u.temperaturaMaxF, palletTareKg: u.taraPalletKg,
    lengthM: u.longitudInteriorM, kingpinM: u.pernoReyM, trailerAxleM: u.tandemCajaM,
    fifthWheelM: u.quintaRuedaM, tractorWheelbaseM: u.distanciaEjesTractorM,
    emptyAxlesLb: u.pesosVaciosEjesLb, axleLimitsLb: u.limitesEjesLb
});
const finite = (n: unknown): n is number => typeof n === 'number' && Number.isFinite(n);
export function boxWeightKg(p: ProductoDB) {
    if (!finite(p.pesoUsa) || p.pesoUsa <= 0 || p.pesoIncluyeEmpaque == null || (!p.pesoIncluyeEmpaque && (!finite(p.empaqueKg) || p.empaqueKg < 0)))
        throw new Error(`Confirma peso bruto y empaque de ${p.nombreDelProducto}.`);
    return p.pesoUsa + (p.pesoIncluyeEmpaque ? 0 : p.empaqueKg!);
}
export function thermalRange(products: { minF?: number; maxF?: number }[]) {
    const chilled = products.filter(p => p.minF != null || p.maxF != null);
    if (!chilled.length) return null;
    const min = Math.max(...chilled.map(p => Number(p.minF)));
    const max = Math.min(...chilled.map(p => Number(p.maxF)));
    if (!Number.isFinite(min) || !Number.isFinite(max) || min >= max) throw new Error('No existe temperatura común permitida para esta carga.');
    return { min, max, suggested: (min + max) / 2 };
}
// The first temperature-controlled pickup sets the journey temperature.
// Later pickups cannot influence this choice, even after the original cargo is delivered.
export function departureTemperature(plan: TripPlan, products: ProductoDB[], pallets = expandPallets(plan, products)) {
    if (plan.temperatureF != null && !finite(plan.temperatureF)) throw new Error('La temperatura de salida debe ser un número válido en °F.');
    const controlled = pallets.filter(p => finite(p.minF) && finite(p.maxF));
    if (!controlled.length) return { value: plan.temperatureF ?? null, originStopId: null, range: null };
    const firstIndex = Math.min(...controlled.map(p => p.loadIndex));
    const initial = controlled.filter(p => p.loadIndex === firstIndex);
    const range = thermalRange(initial)!;
    if (!plan.equipment.refrigerated || !finite(plan.equipment.minF) || !finite(plan.equipment.maxF)) throw new Error('El equipo no tiene un rango de refrigeración configurado.');
    const common = thermalRange([{ minF: Math.max(range.min, plan.equipment.minF), maxF: Math.min(range.max, plan.equipment.maxF) }])!;
    const originStopId = plan.stops[firstIndex].id;
    if (plan.id && plan.stops[firstIndex].completedAt && plan.temperatureF == null) throw new Error('Confirma la temperatura de salida registrada en el punto A; no se puede inferir para un viaje iniciado.');
    const preferred = [...new Set(initial.map(p => p.productId))].flatMap(id => {
        const optimum = products.find(p => p.id === id)?.tempOptima;
        return finite(optimum) && optimum >= common.min && optimum < common.max ? [optimum] : [];
    });
    const value = plan.temperatureF ?? (preferred.length ? preferred.reduce((n,t) => n+t,0) / preferred.length : common.suggested);
    if (value < common.min || value >= common.max) throw new Error(`La temperatura de salida debe cumplir ${common.min} ≤ T < ${common.max} °F para la carga inicial.`);
    return { value, originStopId, range: common };
}
export function expandPallets(plan: TripPlan, products: ProductoDB[]): LoadPallet[] {
    const pallets: LoadPallet[] = [];
    if (!Number.isInteger(plan.equipment.capacity) || plan.equipment.capacity <= 0) throw new Error('Configura la capacidad de pallets.');
    const stopIds = plan.stops.map(s => s.id);
    if (new Set(stopIds).size !== stopIds.length || stopIds.some(s => !s)) throw new Error('Las paradas deben ser únicas.');
    if (plan.stops.length < 2 || plan.stops.some(s => !s.name.trim() || !s.at || !Number.isFinite(new Date(s.at).getTime()))) throw new Error('Completa nombre y horario de las paradas.');
    if (plan.stops.some((s, i) => i && new Date(s.at) < new Date(plan.stops[i - 1].at))) throw new Error('Los horarios deben respetar el orden de las paradas.');
    if (new Set(plan.cargo.map(c => c.id)).size !== plan.cargo.length) throw new Error('Las cargas deben ser únicas.');
    const tare = plan.equipment.palletTareKg;
    if (!finite(tare) || tare < 0) throw new Error('Configura el peso de las tarimas.');
    for (const cargo of plan.cargo) {
        const loadIndex = stopIds.indexOf(cargo.loadStopId), unloadIndex = stopIds.indexOf(cargo.unloadStopId);
        if (loadIndex < 0 || unloadIndex <= loadIndex) throw new Error('La descarga debe estar después de la recolección.');
        let count: number, totalKg: number, perPallet = 0, minF: number | undefined, maxF: number | undefined;
        if (cargo.kind === 'product') {
            const product = products.find(p => p.id === cargo.productId);
            if (!product || !cargo.clientId || !cargo.projectId || !cargo.projectionId || !Number.isInteger(cargo.boxes) || cargo.boxes <= 0 || !Number.isInteger(product.cajasPalletUsa) || product.cajasPalletUsa! <= 0) throw new Error('Completa producto, cliente, meta y cajas enteras positivas.');
            perPallet = product.cajasPalletUsa!;
            count = Math.ceil(cargo.boxes / perPallet);
            totalKg = cargo.boxes * boxWeightKg(product);
            if (product.almacenadoFrio !== false) {
                minF = Number(product.limiteTolerable); maxF = product.limiteSuperior;
                if (product.limiteTolerable == null || String(product.limiteTolerable).trim() === '' || !finite(minF) || !finite(maxF) || minF >= maxF) throw new Error(`Revisa los límites de temperatura de ${product.nombreDelProducto}.`);
            }
        } else {
            count = cargo.pallets!; totalKg = cargo.weightKg!;
            if (!cargo.description.trim() || !cargo.projectId || (cargo.kind === 'special' && !cargo.clientId) || !Number.isInteger(count) || count <= 0 || !finite(totalKg) || totalKg <= 0) throw new Error('Completa descripción, destinatario, posiciones enteras y peso de la carga especial/insumos.');
            if (!cargo.ambient) { minF = cargo.minF; maxF = cargo.maxF; if (!finite(minF) || !finite(maxF) || minF >= maxF) throw new Error('Indica un rango térmico válido o que no requiere control.'); }
        }
        for (let index = 0; index < count; index++) {
            const boxes = cargo.kind === 'product' ? Math.min(perPallet, cargo.boxes - index * perPallet) : 0;
            const weightKg = cargo.kind === 'product' ? totalKg * boxes / cargo.boxes + tare : totalKg / count;
            const position = cargo.positions?.[index] ?? -1;
            pallets.push({ id: `${cargo.id}:${index}`, cargoId: cargo.id, productId: cargo.productId, clientId: cargo.clientId,
                description: cargo.description, boxes, weightKg, position, loadIndex, unloadIndex, minF, maxF });
        }
    }
    // Allocate positions across the full journey, reserving future collections and reusing delivered space.
    for (const pallet of [...pallets].sort((a, b) => a.loadIndex - b.loadIndex || b.unloadIndex - a.unloadIndex || b.weightKg - a.weightKg)) {
        const conflicts = pallets.filter(p => p !== pallet && p.position >= 0 && p.loadIndex < pallet.unloadIndex && pallet.loadIndex < p.unloadIndex);
        if (pallet.position < 0) {
            const available = Array.from({ length: plan.equipment.capacity }, (_, i) => i).filter(i => !conflicts.some(p => p.position === i));
            // Longer-haul cargo towards the front; later pickups keep accessible positions.
            pallet.position = available[0] ?? -1;
        }
        if (pallet.position < 0 || pallet.position >= plan.equipment.capacity || conflicts.some(p => p.position === pallet.position)) throw new Error('No hay posiciones suficientes o hay pallets superpuestos en un tramo.');
    }
    return pallets;
}
export function axleWeights(unit: TransportSpec, pallets: LoadPallet[]) {
    const { lengthM, kingpinM, trailerAxleM, fifthWheelM, tractorWheelbaseM, emptyAxlesLb } = unit;
    if (![lengthM, kingpinM, trailerAxleM, fifthWheelM, tractorWheelbaseM].every(finite) || !emptyAxlesLb || emptyAxlesLb.length !== 3 || emptyAxlesLb.some(n => !finite(n) || n < 0) || trailerAxleM! <= kingpinM! || tractorWheelbaseM! <= 0 || lengthM! <= 0 || fifthWheelM! < 0 || fifthWheelM! > tractorWheelbaseM!) return null;
    const rows = Math.ceil(unit.capacity / 2);
    let trailer = 0, kingpin = 0;
    pallets.forEach(p => {
        const x = (Math.floor(p.position / 2) + 0.5) * lengthM! / rows;
        const rear = p.weightKg * KG_TO_LB * (x - kingpinM!) / (trailerAxleM! - kingpinM!);
        trailer += rear; kingpin += p.weightKg * KG_TO_LB - rear;
    });
    const drive = kingpin * fifthWheelM! / tractorWheelbaseM!;
    return [emptyAxlesLb[0] + kingpin - drive, emptyAxlesLb[1] + drive, emptyAxlesLb[2] + trailer];
}
export function evaluateTrip(plan: TripPlan, products: ProductoDB[]) {
    const errors: string[] = [], warnings: string[] = [];
    let pallets: LoadPallet[] = [];
    try { pallets = expandPallets(plan, products); } catch (e: any) { errors.push(e.message); }
    let departure: ReturnType<typeof departureTemperature> = { value: finite(plan.temperatureF) ? plan.temperatureF : null, originStopId: null, range: null };
    if (pallets.length) try { departure = departureTemperature(plan, products, pallets); } catch (e: any) { errors.push(e.message); }
    const u = plan.equipment;
    for (const p of products.filter(p=>plan.cargo.some(c=>c.productId===p.id))) if (finite(p.tempOptima) && (p.tempOptima < Number(p.limiteTolerable) || p.tempOptima >= Number(p.limiteSuperior))) warnings.push(`${p.nombreDelProducto}: temperatura óptima fuera del rango permitido; se usa el rango común válido.`);
    if (!finite(u.payloadLb) || u.payloadLb <= 0) errors.push('Configura la carga útil permitida en libras.');
    if (!finite(u.grossLb) || u.grossLb <= 0) errors.push('Configura el peso bruto máximo de la combinación.');
    const segments = plan.stops.slice(0, -1).map((stop, i) => {
        const onBoard = pallets.filter(p => p.loadIndex <= i && p.unloadIndex > i);
        const weightLb = onBoard.reduce((n, p) => n + p.weightKg * KG_TO_LB, 0);
        let temperature: ReturnType<typeof thermalRange> = null;
        try {
            temperature = thermalRange(onBoard);
            if (temperature && (!u.refrigerated || !finite(u.minF) || !finite(u.maxF) || Math.max(temperature.min, u.minF) >= Math.min(temperature.max, u.maxF))) throw new Error('El equipo no puede mantener el rango de temperatura requerido.');
            if (temperature) {
                temperature = thermalRange([{ minF: Math.max(temperature.min, u.minF!), maxF: Math.min(temperature.max, u.maxF!) }]);
                if (!finite(departure.value) || departure.value < temperature!.min || departure.value >= temperature!.max)
                    throw new Error(`La carga no es compatible con la temperatura de salida ${departure.value ?? 'sin confirmar'} °F. No se cambia la temperatura en una parada intermedia.`);
                temperature = { ...temperature!, suggested: departure.value };
            }
        } catch (e: any) { errors.push(`${stop.name}: ${e.message}`); }
        const productIds = [...new Set(onBoard.map(p => p.productId).filter(Boolean))];
        const distinctLoads = new Set(onBoard.map(p=>p.productId||`cargo:${p.cargoId}`)).size;
        if (distinctLoads > 1 && productIds.some(id => products.find(p => p.id === id)?.puedeConsolidar === false)) errors.push(`${stop.name}: un producto no permite consolidación.`);
        if (weightLb > (u.payloadLb || 0)) errors.push(`${stop.name}: excede la carga útil.`);
        const axles = axleWeights(u, onBoard);
        if (axles) {
            if (axles.some(n => n < 0)) errors.push(`${stop.name}: distribución o geometría inválida.`);
            if (axles.reduce((n, a) => n + a, 0) > (u.grossLb || 0)) errors.push(`${stop.name}: excede el peso bruto.`);
            if (!u.axleLimitsLb || u.axleLimitsLb.length !== 3) warnings.push('Configura límites por grupo de ejes.');
            else if (axles.some((n, index) => n > u.axleLimitsLb![index])) errors.push(`${stop.name}: excede un límite por grupo de ejes. Reacomoda los pallets.`);
        } else warnings.push('Distribución por ejes pendiente: faltan tara o geometría del equipo.');
        // Unloading accessibility is separate from load-bearing validity.
        const toUnload = onBoard.filter(p => p.unloadIndex === i + 1);
        if (toUnload.some(p => onBoard.some(other => other.position > p.position && other.unloadIndex > p.unloadIndex && other.position % 2 === p.position % 2))) warnings.push(`${plan.stops[i + 1]?.name}: puede requerir mover pallets para descargar.`);
        return { stopId: stop.id, pallets: onBoard, weightLb, temperature, axles, freePallets: u.capacity - onBoard.length };
    });
    return { pallets, segments, departure, errors: [...new Set(errors)], warnings: [...new Set(warnings)] };
}
export function initialTrip(goals: StrategicProjection[], day: string, unit: TransportSpec, booked: Record<string, number> = {}): TripPlan {
    const projectIds = [...new Set(goals.map(g => g.proyectoId))];
    const clientIds = [...new Set(goals.map(g => g.clientId).filter(Boolean))];
    const stops = [...projectIds.map(id => ({ id: `p-${id}`, name: 'Empaque', address: '', at: `${day}T08:00` })), ...clientIds.map(id => ({ id: `c-${id}`, name: 'Entrega', address: '', at: `${day}T18:00` }))];
    return { id: '', revision: 0, scheduledDate: day, carrierId: '', arrivalAt: `${day}T08:00`, unitTypeId: unit.id, equipment: unit, stops, notes: '', cargo: goals.map(g => ({ id: g.id, kind: 'product', projectionId: g.id, productId: g.productoId, projectId: g.proyectoId, clientId: g.clientId, description: '', boxes: Math.max(0, commercialQuantityForDay(g, day) - (booked[g.id] || 0)), loadStopId: `p-${g.proyectoId}`, unloadStopId: `c-${g.clientId}` })).filter(c => c.boxes > 0) as TripCargo[] };
}

export function suggestTrips(goals: StrategicProjection[], day: string, products: ProductoDB[], units: TransportSpec[], booked: Record<string, number> = {}) {
    const pending = goals.map(g => ({ ...g, pending: Math.max(0, commercialQuantityForDay(g, day) - (booked[g.id] || 0)) })).filter(g => g.pending > 0);
    const suggestions: TripPlan[] = [], issues: string[] = [];
    const sorted = [...units].filter(u => u.capacity > 0).sort((a, b) => a.capacity - b.capacity || (a.payloadLb || 0) - (b.payloadLb || 0));
    const prepare = (selected: StrategicProjection[], unit: TransportSpec) => {
        const p = initialTrip(selected, day, unit);
        p.cargo.forEach(c => { c.description = products.find(p => p.id === c.productId)?.nombreDelProducto || ''; });
        try { p.temperatureF = departureTemperature(p, products).value; } catch { /* evaluateTrip explains missing metadata. */ }
        return p;
    };
    while (pending.some(g => g.pending > 0)) {
        let best: TripPlan | undefined;
        // For each equipment type, pack as many available boxes as feasible, checking the full thermal intersection.
        for (const unit of sorted) {
            const selected: StrategicProjection[] = [];
            for (const g of pending.filter(g => g.pending > 0)) {
                let low = 0, high = g.pending;
                while (low < high) {
                    const mid = Math.ceil((low + high) / 2);
                    const row = { ...g, packingPlan: [{ fecha: day, cantidad: mid }] };
                    const plan = prepare([...selected, row], unit);
                    if (evaluateTrip(balanceTrip(plan, products), products).errors.length === 0) low = mid; else high = mid - 1;
                }
                if (low) selected.push({ ...g, packingPlan: [{ fecha: day, cantidad: low }] });
            }
            if (!selected.length) continue;
            const candidate = balanceTrip(prepare(selected, unit), products);
            const count = candidate.cargo.reduce((n, c) => n + c.boxes, 0);
            const bestCount = best?.cargo.reduce((n, c) => n + c.boxes, 0) || 0;
            if (count > bestCount || (count === bestCount && candidate.equipment.capacity < best!.equipment.capacity)) best = candidate;
        }
        if (!best) {
            const first = pending.find(g => g.pending > 0)!;
            const sample = sorted[sorted.length - 1];
            if (!sample) issues.push('Configura los tipos de unidad.');
            else issues.push(...evaluateTrip(prepare([{ ...first, packingPlan: [{ fecha: day, cantidad: 1 }] }], sample), products).errors);
            break;
        }
        suggestions.push(best);
        best.cargo.forEach(c => { const g = pending.find(g => g.id === c.projectionId)!; g.pending -= c.boxes; });
    }
    return { suggestions, issues: [...new Set(issues)] };
}

// Try deterministic swaps and free positions across every segment; retain only feasible improvements.
export function balanceTrip(plan: TripPlan, products: ProductoDB[]) {
    let result = evaluateTrip(plan, products);
    if (!result.pallets.length || !result.segments.some(s => s.axles)) return plan;
    let best = { ...plan, cargo: plan.cargo.map(c => ({ ...c, positions: result.pallets.filter(p => p.cargoId === c.id).map(p => p.position) })) };
    const score = (p: TripPlan) => {
        const e = evaluateTrip(p, products);
        if (e.errors.some(s => !s.includes('ejes') && !s.includes('peso bruto') && !s.includes('distribución'))) return Number.POSITIVE_INFINITY;
        return e.segments.reduce((sum, s) => sum + (s.axles?.reduce((n, a, i) => n + Math.max(0, a - (p.equipment.axleLimitsLb?.[i] || Number.POSITIVE_INFINITY)) ** 2 + Math.max(0, -a) ** 2, 0) || 0), 0);
    };
    let bestScore = score(best);
    for (let round = 0; round < 4 && bestScore > 0; round++) {
        let improved = false;
        const pallets = evaluateTrip(best, products).pallets;
        search: for (const pallet of pallets) for (let slot = 0; slot < best.equipment.capacity; slot++) {
            if (slot === pallet.position) continue;
            const conflicts = pallets.filter(p => p.position === slot && p.loadIndex < pallet.unloadIndex && pallet.loadIndex < p.unloadIndex);
            if (conflicts.length > 1) continue;
            const other = conflicts[0];
            const candidate = { ...best, cargo: best.cargo.map(c => ({ ...c, positions: pallets.filter(p => p.cargoId === c.id).map(p => p.id === pallet.id ? slot : p.id === other?.id ? pallet.position : p.position) })) };
            const candidateScore = score(candidate);
            if (candidateScore < bestScore) { best = candidate; bestScore = candidateScore; improved = true; break search; }
        }
        if (!improved) break;
    }
    return best;
}
