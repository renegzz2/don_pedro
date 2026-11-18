export interface TransportSpec {
    id: string; name: string; capacity: number;
    payloadLb?: number | null; grossLb?: number | null;
    refrigerated?: boolean; minF?: number | null; maxF?: number | null;
    palletTareKg?: number | null; lengthM?: number | null;
    kingpinM?: number | null; trailerAxleM?: number | null;
    fifthWheelM?: number | null; tractorWheelbaseM?: number | null;
    emptyAxlesLb?: number[] | null; axleLimitsLb?: number[] | null;
}
export interface TripStop { id: string; name: string; address: string; at: string; completedAt?: string }
export interface TripCargo {
    id: string; kind: 'product' | 'special' | 'supplies';
    projectionId?: string; requestId?: string; projectId: string; clientId?: string;
    productId?: string; description: string; boxes: number;
    pallets?: number; weightKg?: number; ambient?: boolean; minF?: number; maxF?: number;
    loadStopId: string; unloadStopId: string; positions?: number[];
}
export interface TripPlan {
    id: string; revision: number; scheduledDate: string; unitTypeId: string;
    temperatureF?: number | null;
    temperatureOriginStopId?: string | null;
    tractorPlates?: string; trailerPlates?: string;
    operator?: string; economicNumber?: string; trailerFeet?: string;
    thermograph?: string; continuous?: boolean;
    carrierId: string; arrivalAt: string; equipment: TransportSpec;
    stops: TripStop[]; cargo: TripCargo[]; notes: string;
    scaleTickets?: { stopId: string; weightsLb: number[]; reference: string; at: string }[];
}
export interface SupplyRequest {
    id: string; projectId: string; supplier: string; address: string;
    description: string; pallets: number; weightKg: number;
    requestedDate: string; reference: string; status: string;
}
export interface LoadPallet {
    id: string; cargoId: string; productId?: string; clientId?: string;
    description: string; boxes: number; weightKg: number; position: number;
    loadIndex: number; unloadIndex: number; minF?: number; maxF?: number;
}
