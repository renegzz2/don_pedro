import { useCallback, useEffect, useState, useRef } from 'react';
import { supabase } from '../lib/supabase';
import type { BoxMetric } from '../utils/planningMetrics';
export { metricBoxes } from '../utils/planningMetrics';
export function usePlanningMetrics(year: number, week: number, historyYear = year - 1) {
    const [rows, setRows] = useState<BoxMetric[]>([]); const [error, setError] = useState('');
    const [loadedKey, setLoadedKey] = useState('');
    const queryKey = `${year}:${week}:${historyYear}`;
    const latest = useRef(0);
    const refresh = useCallback(async () => {
        const token = ++latest.current;
        const [current, history] = await Promise.all([
            supabase.rpc('planning_box_metrics', { p_year: year, p_week: week }),
            supabase.rpc('planning_weekly_history', { p_year: historyYear, p_week: week })
        ]);
        if (token !== latest.current) return;
        const error = current.error || history.error;
        if (error) { setRows([]); setError(`No se pudieron cargar las cajas históricas/enviadas: ${error.message}`); }
        else { setRows([...(current.data || []), ...(history.data || [])]); setError(''); }
        setLoadedKey(queryKey);
    }, [year, week, historyYear, queryKey]);
    useEffect(() => {
        setRows([]); setLoadedKey(''); void refresh();
        const timer = window.setInterval(refresh, 30000);
        window.addEventListener('focus', refresh);
        return () => { ++latest.current; window.clearInterval(timer); window.removeEventListener('focus', refresh); };
    }, [refresh]);
    return { rows: loadedKey === queryKey ? rows : [], error: loadedKey === queryKey ? error : '', loading: loadedKey !== queryKey, refresh };
}
