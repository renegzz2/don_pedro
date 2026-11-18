import type { FreightSchedule } from '../types';
import type { TripPlan } from '../transportTypes';

export interface ShipmentLoad {
    id: string; loadId?: string; stopId?: string; trip?: TripPlan;
    schedules: FreightSchedule[];
}

// The client filters journeys, never removes the other clients' cargo from a journey.
export function shipmentLoads(schedules: FreightSchedule[], trips: TripPlan[], day: string, clientId: string): ShipmentLoad[] {
    const groups = new Map<string, ShipmentLoad>();
    for (const schedule of schedules.filter(s => s.scheduledDate === day)) {
        const trip = trips.find(t => t.id === schedule.loadId);
        const cargo = trip?.cargo.find(c => c.projectionId === schedule.projectionId);
        const stopId = cargo?.loadStopId;
        const id = schedule.loadId ? `${schedule.loadId}:${stopId || day}` : schedule.id;
        if (!groups.has(id)) groups.set(id, { id, loadId: schedule.loadId, stopId, trip, schedules: [] });
        groups.get(id)!.schedules.push(schedule);
    }
    return [...groups.values()].filter(g => g.schedules.some(s => s.proyeccion?.clientId === clientId));
}

export function shipmentTransport(trip?: TripPlan) {
    return {
        operator: trip?.operator || '', tractor: trip?.tractorPlates || '', trailer: trip?.trailerPlates || '',
        economic: trip?.economicNumber || '', feet: trip?.trailerFeet || trip?.equipment.name.match(/\b(\d+)\s*pies\b/i)?.[1] || '',
        thermograph: trip?.thermograph || '', temperature: trip?.temperatureF ?? '' as number | '',
        continuous: trip?.continuous === false ? 'No' : trip?.continuous === true ? 'Sí' : '',
    };
}

export function resolveShipmentSchedule(schedules: FreightSchedule[], productId: string, scheduleId?: string) {
    const matches = schedules.filter(s => s.proyeccion?.productoId === productId && (!scheduleId || s.id === scheduleId));
    return matches.length === 1 ? matches[0] : undefined;
}
