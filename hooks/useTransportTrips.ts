import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import { toCamelCase } from '../utils/formatters';
import type { TripPlan, SupplyRequest } from '../transportTypes';
export function useTransportTrips(start: string, end: string, includeTrips = true) {
    const [trips, setTrips] = useState<TripPlan[]>([]), [requests, setRequests] = useState<SupplyRequest[]>([]), [error, setError] = useState('');
    const latest = useRef(0);
    const refresh = useCallback(async () => {
        const token = ++latest.current;
        const [t, r] = await Promise.all([
            includeTrips ? supabase.from('usa_viajes_planeados').select('id,revision,plan').or(`scheduled_date.gte.${start},completed_at.is.null`).lte('scheduled_date', end).order('scheduled_date') : Promise.resolve({data:[],error:null}),
            supabase.from('usa_solicitudes_insumos').select('*').gte('requested_date', start).lte('requested_date', end).order('requested_date')
        ]);
        if (token !== latest.current) return;
        if (t.error || r.error) { setError((t.error || r.error)!.message); return; }
        setError(''); setTrips((t.data || []).map(t => ({ ...t.plan, id: t.id, revision: t.revision })));
        setRequests(toCamelCase(r.data || []));
    }, [start, end, includeTrips]);
    useEffect(() => { setTrips([]); setRequests([]); void refresh(); const timer = window.setInterval(refresh, 30000); window.addEventListener('focus', refresh); return () => { ++latest.current; window.clearInterval(timer); window.removeEventListener('focus', refresh); }; }, [refresh]);
    return { trips, requests, error, refresh };
}
