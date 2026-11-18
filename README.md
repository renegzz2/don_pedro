# nglobal
App Don Pedro

## Flujo Comercial, Tráfico y Embarques

Aplicar en orden `supabase/migrations/202611110001_commercial_freight_workflow.sql` y `supabase/migrations/202611120001_packing_consolidated_transport.sql` antes de desplegar esta versión. La migración añade el año fiscal a las metas, la tabla `usa_programacion_fletes` y el guardado transaccional de embarques y tarimas. Los años de metas existentes se deducen de `created_at`; revisar los registros históricos capturados en un año distinto de su planeación.

Para asignar el nuevo rol a una cuenta, configurar `app_metadata.role` como `COMERCIAL` en Supabase Auth y renovar su sesión. La aplicación reconoce el valor sin cambiar el enum SQL `public.user_role`, que corresponde al sistema anterior de perfiles.

- Comercial crea una meta por proyecto, cliente y producto para la semana actual, con cantidad y día de carga. La fecha solicitada no reserva transporte: el líder de proyecto/empaque distribuye las cajas por día en **Programación de empaque**, que muestra la meta, cajas programadas y pendientes de programar. Solo `LIDER_PROYECTO` y `ADMINISTRADOR` pueden guardar esta distribución.
- Tráfico RI abre Unidades sugeridas en el sidebar. El calendario consolida todos los productos del mismo proyecto y día, convierte cajas a pallets por producto y elige la unidad de menor capacidad suficiente. Si se supera la capacidad máxima, divide la carga entre varias unidades. Deben estar configuradas las cajas por pallet de cada producto y la capacidad en pallets de los tipos de transporte. Cada unidad se reserva de forma atómica con todas sus metas; la base valida cajas disponibles y capacidad. Las asignaciones conservan su producto y cliente y comparten `load_id`, visible también en Embarques.
- La consola del Líder muestra las cantidades semanales solicitadas y los fletes por recibir. Se actualiza al recuperar el foco y cada 30 segundos, además de Realtime cuando esté habilitado.
- Embarques selecciona un cliente solicitado por Comercial, captura la fecha y hora reales de salida y elige uno de sus fletes programados para ese día. La fecha programada de carga determina el día disponible; la llegada al empaque es un dato separado.
- El XLSX se importa en **1. Datos** y completa los campos de transporte reconocidos y las tarimas. Los datos siguen editables. No reemplaza cliente, proveedor programado ni salida real. La hoja de tarimas debe contener `PRODUCTO` y `CAJAS`; mantiene `PALLET`, `REMISION`, `MID`, `LOTE`, `CALIDAD` y `LBS` del layout anterior. Los datos del transporte pueden estar en otras hojas, como encabezados con valores debajo o etiquetas con valores al lado.

Las metas con fletes asignados se protegen frente a cambios de cliente, producto, fechas o cantidades. Tráfico debe retirar primero los fletes afectados. Un flete con embarques registrados ya no se puede retirar ni modificar. El guardado de Embarques verifica producto, día y cajas disponibles y guarda cabecera y tarimas en una sola transacción.

Pruebas del flujo: `npm run test:commercial-planning`.

La migración de empaque conserva las cajas de los fletes ya reservados como programación inicial. Las demás cajas quedan pendientes para que el líder las distribuya. Reducir un día por debajo de los fletes reservados requiere retirarlos primero; retirar una unidad consolidada retira todas sus asignaciones y se bloquea si alguna tiene embarques.

## Viajes, pesos y matriz por cliente (13 de noviembre de 2026)

Para una instalación que ya aplicó las migraciones del 11 y 12 de noviembre, ejecutar **una sola vez** `supabase/activate_20261113.sql` completo en SQL Editor. Es una transacción que agrupa las cinco nuevas migraciones; si falla, no deja activación parcial. No volver a ejecutar las migraciones anteriores: la del 12 inicializa la programación de empaque. Si se administra el historial con CLI, aplicar en su lugar las cinco migraciones `202611130001` a `202611130005`, en orden; no ejecutar también el archivo unificado.

Configuración necesaria antes de reservar las nuevas unidades:

- En **Base de Datos → Productos**, confirmar si `peso_usa` (kg/caja) incluye empaque. Si no, capturar `empaque_kg`. La aplicación no supone que los kg son libras ni que el peso neto ya es bruto. Revisar `cajas_pallet_usa`, límite inferior `limite_tolerable`, límite superior **excluido** `limite_superior`, temperatura óptima y permiso de consolidación. Las temperaturas están en °F.
- En **Base de Datos → Estados Unidos → Tipos de Unidad**, capturar carga útil y peso bruto máximo en lb, tara de pallets en kg, refrigeración, rango del equipo y límites por grupos de ejes. No se precargan límites legales ni permisos de sobrepeso a partir del nombre del vehículo.
- El editor del viaje permite registrar placas, geometría y tara por grupos de ejes del equipo asignado. Los cálculos usan posiciones longitudinales en dos columnas; requieren revisar el formato físico de las tarimas. El acomodo sugerido busca reducir excesos por ejes y puede modificarse en el mapa. Es una estimación de planeación, no una certificación de ruta ni una solución de óptimo global.
- Para salir con carga, confirmar cada parada en orden, con las cajas de producto previamente registradas en Embarques, geometría/tara completas, identificación del equipo y ticket de báscula por grupos de ejes. Se comprueban carga útil, peso bruto y límites por ejes. La autorización de ruta/puentes de Texas debe confirmarse con el transportista. Los demás tipos de unidad requieren su propia configuración de ejes; la estimación actual corresponde al conjunto de tres grupos (dirección, motrices y caja), no a cualquier número de ejes.

El viaje aparece una sola vez y conserva varias metas, proyectos, clientes, recolecciones y entregas. Cada carga tiene origen/destino propios. La temperatura de salida se determina con la primera recolección refrigerada (punto A) y las cargas posteriores deben admitir ese mismo valor, incluso si la mercancía inicial ya se entregó. La ocupación se comprueba por tramo; una descarga libera posiciones para una recolección posterior. Los pallets de distintos clientes/metas se mantienen identificados por separado. El mapa señala espacios disponibles en el tramo y reservas futuras, permite intercambiar posiciones y advierte posibles reacomodos para descarga.

En el formulario se puede cambiar unidad y cajas por producto, excluir un producto con cero cajas y agregar otras metas/clientes. El servidor reserva únicamente lo confirmado y las sugerencias recalculan el remanente sin asignarle proveedor automáticamente. Los cambios usan revisión del viaje y bloqueos de metas para impedir sobreasignación. Los datos ya recogidos quedan protegidos; se permiten nuevas recolecciones futuras sin reemplazar embarques existentes. Los fletes anteriores siguen visibles y protegidos.

**Compras:** asignar `app_metadata.role = COMPRAS` a las cuentas de esa área y renovar sesión. Compras crea solicitudes con proveedor, dirección, proyecto receptor, fecha, referencia, posiciones equivalentes y peso bruto. Logística las asigna al recorrido. El espacio no se libera hasta confirmar la parada de descarga de los insumos. Las cargas especiales se registran sin crear un producto de catálogo, con destinatario, posiciones equivalentes, peso bruto total (incluye tarimas) y condición térmica. Su peso se representa inicialmente uniforme entre posiciones equivalentes; debe revisarse físicamente antes de salida.

**Matriz:**

- `NG [año consultado]`: cajas realmente embarcadas del proyecto/producto a todos los clientes durante la semana fiscal seleccionada y el año ISO consultado. El año de consulta inicia en el anterior al año de planeación y puede cambiarse en el selector.
- `[cliente seleccionado] [año consultado]`: cajas realmente embarcadas a ese cliente del proyecto/producto durante la misma semana y año consultados. El selector solo incluye clientes activos. No se usan recepciones ni referencias anuales para estas comparaciones semanales.
- `Presupuesto (cajas enviadas)`: total de cajas de Embarques en el año en curso por proyecto/producto, sumando clientes.
- `Real enviado`: cajas de Embarques vinculadas específicamente a la meta. No usa cantidades previstas, canjes capturados ni ajustes manuales como evidencia de envío.
- Se retiró de la matriz la sección de conciliación de embarques sin proyecto/cliente. Los registros sin atribución no se asignan por suposición.
- Las referencias anuales anteriores se conservan en la base, pero no se muestran como envíos semanales. El formulario anual de históricos ya no se ofrece en la matriz. La comparación semanal se deriva de la fecha real del embarque; los registros cancelados se excluyen. Una consulta completada sin embarques devuelve cero.
- Las entregas confirmadas siguen guardando las cajas realmente recibidas para trazabilidad; no alimentan la comparación semanal de envíos. CSV e impresión PDF usan la misma semana, cliente y año consultados que la matriz.

Validaciones: `npm run test:commercial-planning`, `npm run test:transport`, `npm run build`. Las nuevas pruebas ejecutan el SQL unificado en PostgreSQL embebido (PGlite), además del cálculo de carga, temperatura, peso, ejes, remanentes y métricas. No requieren ni modifican un proyecto Supabase externo.

Para instalaciones que ya ejecutaron la activación anterior del 13 de noviembre, aplicar **solo** `supabase/migrations/202611130004_weekly_shipment_history.sql`. No repetir `activate_20261113.sql` sobre una instalación ya activada. La nueva migración actualiza únicamente la consulta semanal, es repetible y no cambia metas, cajas ni históricos existentes.

## Temperatura fija y asignación de Compras

Aplicar únicamente `supabase/migrations/202611130005_fixed_departure_temperature.sql` si ya se aplicaron las migraciones anteriores. Es repetible y no modifica registros existentes. La temperatura de salida se guarda en el viaje y se verifica en PostgreSQL: se elige con los productos del punto A, no con las cargas futuras. Una vez confirmada esa recolección no se puede cambiar para aceptar otro producto. Los insumos previos sin control térmico no definen la temperatura. En viajes iniciados antes de esta mejora se debe registrar explícitamente la temperatura con la que salieron; no se inventa a partir del catálogo. Se valida el valor configurado del viaje; esto no representa una lectura de sensor en tiempo real.

Se retiró «Configurar capacidades de transporte» de Viajes. Las capacidades permanecen en el catálogo de Base de Datos. Para asignar una solicitud de Compras, Logística abre una unidad sugerida o «Editar / añadir recolección» en un viaje, elige «Asignar recolección de Compras», selecciona la solicitud y verifica proveedor → empaque, horarios, peso y posiciones antes de guardar. Al guardar la solicitud pasa a «asignada»; después de confirmar la descarga de los insumos pasa a «entregada». Si no hay unidad sugerida puede usarse «Nuevo viaje / carga especial sin metas» y completar sus paradas.

## Secciones operativas y metas futuras (17 de noviembre de 2026)

En instalaciones ya activadas, ejecutar **solo** `supabase/migrations/202611170001_planning_sections_future_goals.sql`. Es repetible, conserva los registros existentes y debe ejecutarse después de las migraciones del 13 de noviembre. No volver a ejecutar los archivos de activación anteriores.

El sidebar y las rutas comprueban las mismas reglas:

| Sección | Roles |
|---|---|
| Programación de empaque | `ADMINISTRADOR`, `LIDER_PROYECTO` |
| Compras · Recolección de insumos | `ADMINISTRADOR`, `COMPRAS` |
| Unidades sugeridas · cajas pendientes de asignar | `ADMINISTRADOR`, `TRAFICO_RI` |

Estas funciones ya no están incrustadas en Alcance y Metas. La pantalla de unidades mantiene el selector para asignar solicitudes pendientes de Compras al recorrido, pero no ofrece la creación de solicitudes. Cada sección dispone de selección de semana y año. Líder de Proyecto, Compras y Tráfico RI entran inicialmente a su sección correspondiente; los demás accesos existentes se conservan.

Para asignar el nuevo rol a una cuenta, configurar **`app_metadata.role = "TRAFICO_RI"`** mediante la administración de Supabase Auth y cerrar/abrir sesión para renovar el JWT. La migración también registra `TRAFICO_RI` en el enum legado `public.user_role` cuando existe; cambiar solo el perfil legado no sustituye la configuración de Auth. El selector de roles de demostración reconoce Tráfico RI cuando ese selector está habilitado.

Las funciones de guardado de empaque aceptan únicamente Líder/Administrador; las de viajes aceptan únicamente Tráfico RI/Administrador; la política de creación de solicitudes acepta únicamente Compras/Administrador. Se validan en PostgreSQL además de ocultar el menú.

Comercial puede crear metas para **hoy o cualquier fecha futura**, incluidas semanas y años posteriores. El formulario conserva por defecto la semana futura elegida y calcula semana/año fiscal a partir de la fecha de carga, navegando al periodo de la meta al guardarla. La base rechaza nuevas fechas pasadas y periodos que no correspondan a la fecha. Se permite editar una meta histórica sin cambiar su fecha existente; no se permite asignarle otra fecha pasada ni añadirle días pasados. Las sesiones SQL de mantenimiento sin identidad de usuario pueden importar históricos.

### Embarques por unidad consolidada

Después de las migraciones anteriores (incluida `202611170001_planning_sections_future_goals.sql`), ejecutar **`supabase/migrations/202611170002_consolidated_shipments.sql`** completo en Supabase SQL Editor. Esta migración es independiente del archivo de activación del 13 de noviembre, se puede repetir y conserva los embarques existentes. Luego iniciar `npm run dev` o actualizar la versión desplegada.

En Embarques, seleccionar cliente como filtro, fecha real de salida, transportista y **Unidad consolidada programada**. Cada opción representa un viaje en un punto de carga: incluye todos los productos y clientes programados allí. Las recolecciones en otros puntos mantienen su propia captura. Debajo aparece el desglose completo; la selección del cliente no excluye mercancía de otros clientes del mismo viaje.

Se copian placas, temperatura, operador, económico, pies, termógrafo y modo continuo disponibles en la programación. Los campos desconocidos quedan pendientes de captura; los pies pueden obtenerse del nombre explícito del equipo, por ejemplo Thermo 53 pies. Programación permite registrar esos datos antes del embarque. La fecha/hora de llegada no sustituye la salida real. La temperatura debe coincidir con el valor fijado para el viaje.

Seleccionar la unidad antes de importar el Excel. También se pueden capturar tarimas manualmente. Los productos se limitan a la carga programada. Cuando un producto corresponde a varias metas/clientes, seleccionar su asignación en cada partida; no se adivina el destinatario. El guardado crea un solo encabezado y conserva la asignación de meta/proyecto/cliente por detalle, de forma atómica. Se validan cantidades acumuladas por asignación, incluyendo capturas previas hechas con el formulario anterior. Las confirmaciones de paradas y los históricos utilizan esas mismas asignaciones.

### Despacho activo desde la salida de Embarques

Ejecutar completo `supabase/migrations/202611170003_active_dispatch_from_shipments.sql` en SQL Editor, después de `202611170002_consolidated_shipments.sql`, y cargar esta versión de la app. La migración puede repetirse. Los datos nuevos se agregan a las tablas existentes; los despachos manuales conservan su funcionamiento. Los embarques históricos no se activan automáticamente ni al corregirlos. Una nueva salida de un viaje que ya tenía cargas anteriores incorpora también esas cargas al expediente del mismo viaje.

Al guardar una salida real, se crea automáticamente un registro en `usa_shipment_reports` con estado **En ruta**, vinculado al viaje y sus salidas. Si el despacho falla, también se revierte el embarque: no queda una salida sin despacho. La app envía una clave de captura para que un reintento tras perder conexión devuelva la misma salida, sin duplicar cajas. El viaje tiene un único despacho por `source_load_id`; cada recolección posterior incorpora sus tarimas y clientes al mismo registro, sin reemplazar las cargas iniciales.

Se heredan operador, placas, equipo, económico, pies, termógrafo, continuo, temperatura fijada y fecha real de salida. Las cantidades y los proyectos/clientes proceden de los detalles reales de Embarques; el recorrido programado se conserva por separado, incluyendo cargas futuras. Las observaciones de auditoría se muestran como observaciones del embarque, no como una entrega confirmada. Una salida nueva no puede añadirse a un despacho finalizado/cancelado sin que Tráfico revise y reabra su seguimiento.

**Tráfico RI** dispone de Operaciones USA y el mapa Tive en el menú. Puede editar seguimiento junto con los roles logísticos que ya tenían permiso; la base protege los datos heredados y rechaza modificaciones de otros roles en despachos vinculados. En la edición de un despacho automático, `UsaShipmentForm` muestra datos confirmados y un formulario de seguimiento: teléfono, sello, responsable, cruce, costo USD, dispositivo Tive, ETA, comentarios y estatus. Las correcciones de cajas, transporte y temperatura se hacen en el origen. El formulario manual anterior permanece para los despachos existentes y las cuentas que ya podían crearlos. Los despachos automáticos no se eliminan desde la tabla; se conserva su vínculo documental.

La tabla se actualiza por Realtime, consulta cada 30 segundos y al recuperar el foco, sin reemplazar lo que se está escribiendo en un formulario. Los activos siguen visibles al cambiar de año; los finalizados usan el año de llegada si está registrado. La carga muestra cajas embarcadas acumuladas, no un cálculo de existencias a bordo. Las paradas se confirman desde Unidades sugeridas y sus confirmaciones actualizan el recorrido del despacho. Finalización, calificación, incidencias y pagos continúan con el flujo existente.

El Tive se asigna explícitamente, sin usar como sustituto el termógrafo o folio del viaje. Con datos GPS y coordenadas del próximo proyecto/cliente se estima la llegada a esa parada; sin esos datos se muestra la ETA capturada o programada y se indica que no hay GPS. Si una parada representa varios clientes sin un destino único, no se inventa un cliente para calcular distancia. La migración no requiere habilitar Realtime para funcionar gracias a la consulta periódica.
