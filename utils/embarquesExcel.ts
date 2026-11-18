// Supports both header/value rows and printed layouts with labels beside/before values.
export const normalizeExcelLabel = (value: unknown) => String(value ?? '')
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '').toUpperCase()
    .replace(/[^A-Z0-9]+/g, ' ').trim();

const aliases = {
    operador: ['OPERADOR', 'NOMBRE OPERADOR', 'NOMBRE DEL OPERADOR', 'CHOFER', 'NOMBRE DEL CHOFER'],
    placasTractor: ['PLACAS TRACTOR', 'PLACA TRACTOR', 'PLACAS DEL TRACTOR', 'TRACTOR'],
    placasCaja: ['PLACAS CAJA', 'PLACA CAJA', 'PLACAS DE CAJA', 'PLACAS DE LA CAJA', 'REMOLQUE'],
    economico: ['ECONOMICO', 'NO ECONOMICO', 'NUMERO ECONOMICO', 'NUM ECONOMICO'],
    pies: ['PIES', 'PIES REMOLQUE', 'LONGITUD PIES'],
    termografo: ['TERMOGRAFO', 'TERMOGRADO', 'ID TERMOGRAFO', 'NUMERO DE TERMOGRAFO'],
    temperatura: ['TEMPERATURA PROGRAMADA', 'TEMP PROGRAMADA', 'TEMPERATURA PROGRAMADA F', 'TEMP PROGRAMADA F', 'TEMPERATURA VIAJE', 'TEMPERATURA'],
    continuo: ['TERMO CONTINUO', 'TERMO EN CONTINUO', 'CONTINUO']
} as const;

export function extractTransportFields(sheets: unknown[][][]) {
    const result: Partial<Record<keyof typeof aliases, string>> = {};
    const labels = new Map<string, keyof typeof aliases>();
    Object.entries(aliases).forEach(([field, values]) => values.forEach(v => labels.set(v, field as keyof typeof aliases)));
    const isValue = (v: unknown) => v !== undefined && v !== null && String(v).trim() !== '' && !labels.has(normalizeExcelLabel(v));
    for (const rows of sheets) {
        rows.forEach((row, r) => row.forEach((cell, c) => {
            const raw = String(cell ?? '').trim();
            const inline = raw.match(/^(.+?)\s*[:=]\s*(.+)$/);
            const field = labels.get(normalizeExcelLabel(inline?.[1] || raw));
            if (!field || result[field] !== undefined) return;
            let value: unknown = inline?.[2];
            if (!isValue(value)) {
                // Tabular headers put their values directly below; horizontal forms put them to the right.
                const nextLabel = row.slice(c + 1).find(v => v !== null && v !== undefined && String(v).trim());
                if (labels.has(normalizeExcelLabel(nextLabel))) value = rows[r + 1]?.[c];
                else value = row.slice(c + 1).find(v => v !== null && v !== undefined && String(v).trim());
                if (!isValue(value)) value = rows[r + 1]?.[c];
            }
            if (isValue(value)) result[field] = String(value).trim();
        }));
    }
    return result;
}

export function parseTemperature(value: string) {
    const match = value.replace(',', '.').match(/-?\d+(?:\.\d+)?/);
    return match ? Number(match[0]) : undefined;
}

export function parseContinuous(value: string) {
    const normalized = normalizeExcelLabel(value);
    if (['SI', 'YES', 'TRUE', '1', 'CONTINUO'].includes(normalized)) return 'Sí';
    if (['NO', 'FALSE', '0', 'CICLO', 'CICLICO'].includes(normalized)) return 'No';
    return undefined;
}
