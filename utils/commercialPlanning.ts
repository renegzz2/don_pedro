import type { FreightSchedule, StrategicProjection } from '../types';

export const localDateKey = (date = new Date()) =>
    `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;

export const localDateTime = (date = new Date()) =>
    `${localDateKey(date)}T${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;

export function fiscalPeriod(date = new Date()) {
    const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
    d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
    const year = d.getUTCFullYear();
    const week = Math.ceil((((d.getTime() - Date.UTC(year, 0, 1)) / 86400000) + 1) / 7);
    return { year, week };
}

export function planningWeekDays(year: number, week: number) {
    const jan4 = new Date(year, 0, 4, 12);
    jan4.setDate(jan4.getDate() - ((jan4.getDay() + 6) % 7) + (week - 1) * 7 - 2);
    const names = ['Sab', 'Dom', 'Lun', 'Mar', 'Mie', 'Jue', 'Vie', 'Sab', 'Dom'];
    return names.map((name, i) => {
        const date = new Date(jan4); date.setDate(date.getDate() + i);
        return { name, dateString: localDateKey(date), formatted: `${String(date.getDate()).padStart(2,'0')}/${String(date.getMonth()+1).padStart(2,'0')}` };
    });
}

export function requestedGoalPeriod(day: string, today = localDateKey(), originalDay?: string) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error('Selecciona una fecha de carga válida.');
    const date = new Date(`${day}T12:00:00`);
    if (Number.isNaN(date.getTime()) || localDateKey(date) !== day) throw new Error('Selecciona una fecha de carga válida.');
    if (day < today && day !== originalDay) throw new Error('No se pueden crear metas para días pasados. Selecciona hoy o una fecha futura.');
    return fiscalPeriod(date);
}

export function defaultGoalDay(year: number, week: number, today = localDateKey()) {
    return planningWeekDays(year, week).slice(2).find(d => d.dateString >= today)?.dateString || today;
}

export function commercialQuantityForDay(p: StrategicProjection, day: string) {
    if (p.packingPlan != null) return p.packingPlan.reduce((sum, item) => sum + (item.fecha.slice(0, 10) === day ? Number(item.cantidad) || 0 : 0), 0);
    if (p.desgloseDiario?.length) {
        return p.desgloseDiario.reduce((sum, item) => sum + (item.fecha?.slice(0, 10) === day ? Number(item.cantidad) || 0 : 0), 0);
    }
    const fields = ['domingo', 'lunes', 'martes', 'miercoles', 'jueves', 'viernes', 'sabado'] as const;
    const legacyTotal = fields.reduce((sum, field) => sum + (Number(p[field]) || 0), 0);
    if (legacyTotal > 0) return Number(p[fields[new Date(`${day}T12:00:00`).getDay()]]) || 0;
    return p.fechaSalida?.slice(0, 10) === day ? Number(p.proyeccionCajas) || 0 : 0;
}

export function freightForDeparture(schedules: FreightSchedule[], day: string, clientId: string) {
    return schedules.filter(s => s.scheduledDate === day && s.proyeccion?.clientId === clientId);
}
