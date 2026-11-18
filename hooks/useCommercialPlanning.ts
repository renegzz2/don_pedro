import { useCallback, useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import { toCamelCase } from '../utils/formatters';
import { fiscalPeriod } from '../utils/commercialPlanning';
import type { FreightSchedule, StrategicProjection } from '../types';

export function useCommercialPlanning(week = fiscalPeriod().week, year = fiscalPeriod().year) {
    const [goals, setGoals] = useState<StrategicProjection[]>([]);
    const [schedules, setSchedules] = useState<FreightSchedule[]>([]);
    const [error, setError] = useState('');
    const [loading, setLoading] = useState(true);
    const latestRequest = useRef(0);
    const refresh = useCallback(async () => {
        const request = ++latestRequest.current;
        try {
            const [goalsRes, schedulesRes] = await Promise.all([
                supabase.from('proyecciones_estrategicas').select('*').eq('semana_fiscal', week).eq('planning_year', year),
                supabase.from('usa_programacion_fletes').select('*, proyeccion:proyecciones_estrategicas!inner(*)')
                    .eq('proyeccion.semana_fiscal', week).eq('proyeccion.planning_year', year).order('scheduled_date')
            ]);
            if (request !== latestRequest.current) return;
            if (goalsRes.error) throw goalsRes.error;
            if (schedulesRes.error) throw schedulesRes.error;
            setGoals(toCamelCase(goalsRes.data || []));
            setSchedules((toCamelCase(schedulesRes.data || []) as FreightSchedule[]).filter(s => s.proyeccion?.semanaFiscal === week && s.proyeccion?.planningYear === year));
            setError('');
        } catch (e: any) {
            if (request === latestRequest.current) setError(`No se pudo cargar la programación comercial y de fletes: ${e.message}`);
        } finally { if (request === latestRequest.current) setLoading(false); }
    }, [week, year]);

    useEffect(() => {
        let active = true;
        setLoading(true);
        setGoals([]);
        setSchedules([]);
        const reload = () => { if (active) void refresh(); };
        reload();
        window.addEventListener('focus', reload);
        // Polling also covers installations where Realtime is not enabled.
        const timer = window.setInterval(reload, 30000);
        const channel = supabase.channel(`commercial-planning-${week}-${year}-${Math.random()}`)
            .on('postgres_changes', { event: '*', schema: 'public', table: 'usa_programacion_fletes' }, reload)
            .on('postgres_changes', { event: '*', schema: 'public', table: 'proyecciones_estrategicas' }, reload)
            .subscribe();
        return () => { active = false; ++latestRequest.current; window.clearInterval(timer); window.removeEventListener('focus', reload); void supabase.removeChannel(channel); };
    }, [refresh, week, year]);
    return { goals, schedules, error, loading, refresh };
}
