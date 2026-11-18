


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "hypopg" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "index_advisor" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."user_role" AS ENUM (
    'Administrativo',
    'Coordinador 1',
    'Coordinador 2',
    'Sweet Seasons'
);


ALTER TYPE "public"."user_role" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."append_to_location_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  EXECUTE format(
    'UPDATE public.%I SET ' ||
    '  location_history = COALESCE(location_history, ''[]''::jsonb) || %L::jsonb ' ||
    'WHERE id = %L',
    table_name,
    new_entry,
    report_id_to_update
  );
END;
$$;


ALTER FUNCTION "public"."append_to_location_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."append_to_temperature_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb", "new_current_temp" numeric, "new_temp_status" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  EXECUTE format(
    'UPDATE public.%I SET ' ||
    '  temperature_history = COALESCE(temperature_history, ''[]''::jsonb) || %L::jsonb, ' ||
    '  current_temp = %L, ' ||
    '  temp_status = %L ' ||
    'WHERE id = %L',
    table_name,
    new_entry,
    new_current_temp,
    new_temp_status,
    report_id_to_update
  );
END;
$$;


ALTER FUNCTION "public"."append_to_temperature_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb", "new_current_temp" numeric, "new_temp_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_user_allowed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.usa_responsables 
    WHERE correo = NEW.email
  ) THEN
    RETURN NEW;
  ELSE
    RAISE EXCEPTION 'Acceso Denegado: Su correo electrónico no está autorizado en el Sistema de Control Global.';
  END IF;
END;
$$;


ALTER FUNCTION "public"."check_user_allowed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_mining_rewards"("user_id_input" "uuid", "claim_amount" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE profiles
  SET 
    in_app_auri_balance = COALESCE(in_app_auri_balance, 0) + claim_amount,
    last_mine_claim = NOW(),
    accumulated_auri = 0
  WHERE id = user_id_input;
END;
$$;


ALTER FUNCTION "public"."claim_mining_rewards"("user_id_input" "uuid", "claim_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_tables"("table_names" "text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  tbl text;
BEGIN
  IF NOT (
    SELECT rolsuper OR rolcreaterole
    FROM pg_roles
    WHERE rolname = current_user
  ) THEN
    RAISE EXCEPTION 'No tienes permiso para ejecutar esta función.';
  END IF;

  FOREACH tbl IN ARRAY table_names LOOP
    EXECUTE format('DROP TABLE IF EXISTS public.%I', tbl);
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."delete_tables"("table_names" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_dispatch_alert_push"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  -- JEFE: Token de autorización anon para el gateway
  auth_token TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN1Y3ZnZXZoc214cnBrcHZyYmxtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTk5NDMxNTcsImV4cCI6MjA3NTUxOTE1N30.SKHUuWXN3OXLq0zTWuTDQsQFUSUhHkUZAb_FNv2NPBA'; 
BEGIN
  -- JEFE: Llamamos a la Edge Function de Push pasándole la alerta completa
  PERFORM
    net.http_post(
      url := 'https://sucvgevhsmxrpkpvrblm.supabase.co/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'apikey', auth_token,
        'Authorization', 'Bearer ' || auth_token
      ),
      body := jsonb_build_object(
        'title', '🚨 ALERTA: ' || COALESCE(NEW.alert_type, 'SISTEMA'),
        'body', NEW.message || ' (VIAJE: ' || COALESCE(NEW.trip_id, 'N/D') || ')',
        'trip_id', NEW.trip_id
      )
    );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_dispatch_alert_push"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_dispatch_push_notification"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  auth_token TEXT := 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN1Y3ZnZXZoc214cnBrcHZyYmxtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTk5NDMxNTcsImV4cCI6MjA3NTUxOTE1N30.SKHUuWXN3OXLq0zTWuTDQsQFUSUhHkUZAb_FNv2NPBA'; 
  payload JSONB;
BEGIN
  -- CASO A: Es una alerta nueva (Temperatura, etc)
  IF (TG_TABLE_NAME = 'usa_shipment_alerts') THEN
    payload := jsonb_build_object(
      'type', 'ALERT',
      'trip_id', NEW.trip_id,
      'title', '⚠️ ALERTA: ' || NEW.trip_id,
      'body', NEW.message
    );
  -- CASO B: Cambio de estatus logístico
  ELSE
    IF (OLD.logistic_status IS DISTINCT FROM NEW.logistic_status) THEN
      payload := jsonb_build_object(
        'type', 'STATUS_CHANGE',
        'trip_id', NEW.trip_id,
        'title', '🚚 Viaje: ' || NEW.trip_id,
        'body', 'Estatus: ' || OLD.logistic_status || ' -> ' || NEW.logistic_status
      );
    ELSE
      RETURN NEW;
    END IF;
  END IF;

  PERFORM net.http_post(
    url := 'https://sucvgevhsmxrpkpvrblm.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('apikey', auth_token, 'Authorization', 'Bearer ' || auth_token),
    body := payload
  );
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_dispatch_push_notification"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_coordination_audit_data"("p_project_id" "uuid", "p_product_ids" "uuid"[]) RETURNS TABLE("producto_id" "uuid", "stock_fisico" integer, "nombre_producto" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.id as producto_id,
        COALESCE(inv.stock_disponible, 0) as stock_fisico,
        p.nombre_del_producto as nombre_producto
    FROM public.usa_productos p
    LEFT JOIN public.inventario_proyectos inv ON inv.producto_id = p.id AND inv.proyecto_id = p_project_id
    WHERE p.id = ANY(p_product_ids);
END;
$$;


ALTER FUNCTION "public"."get_coordination_audit_data"("p_project_id" "uuid", "p_product_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_product_goal_health"("p_project_id" "uuid", "p_semana_fiscal" integer) RETURNS TABLE("producto_id" "uuid", "nombre_producto" "text", "meta_proyectada" integer, "programado_actual" integer, "porcentaje_avance" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH programmed AS (
        SELECT 
            p.product_id,
            SUM((p.quantity)::int) as total_prog
        FROM public.lider_programacion_usa_reports l,
        LATERAL jsonb_to_recordset(l.productos) as p(product_id uuid, quantity int)
        WHERE l.project_id = p_project_id 
          AND l.semana_fiscal = p_semana_fiscal
          AND l.usa_logistics_status != 'Cancelado'
        GROUP BY p.product_id
    )
    SELECT 
        pe.producto_id,
        prod.nombre_del_producto,
        pe.proyeccion_cajas as meta_proyectada,
        COALESCE(prog.total_prog, 0) as programado_actual,
        ROUND((COALESCE(prog.total_prog, 0)::numeric / NULLIF(pe.proyeccion_cajas, 0)::numeric) * 100, 2) as porcentaje_avance
    FROM public.proyecciones_estrategicas pe
    JOIN public.usa_productos prod ON pe.producto_id = prod.id
    LEFT JOIN programmed prog ON pe.producto_id = prog.product_id
    WHERE pe.proyecto_id = p_project_id 
      AND pe.semana_fiscal = p_semana_fiscal
      AND pe.autorizado = true;
END;
$$;


ALTER FUNCTION "public"."get_product_goal_health"("p_project_id" "uuid", "p_semana_fiscal" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_product_goal_health"("p_project_id" "uuid", "p_semana_fiscal" integer) IS 'Cálculo dinámico para los Anillos de Salud de Meta en la Consola del Líder.';



CREATE OR REPLACE FUNCTION "public"."get_remaining_authorized_boxes"("p_project_id" "uuid", "p_week" integer) RETURNS TABLE("producto_id" "uuid", "nombre_producto" "text", "cantidad_restante" integer, "meta_total" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH programmed_boxes AS (
        SELECT 
            p.product_id,
            SUM(p.quantity) as total_programmed
        FROM public.lider_programacion_usa_reports l,
        LATERAL jsonb_to_recordset(l.productos) as p(product_id uuid, quantity int)
        WHERE l.project_id = p_project_id 
          AND l.semana_fiscal = p_week
          AND l.usa_logistics_status != 'Cancelado'
        GROUP BY p.product_id
    )
    SELECT 
        pe.producto_id,
        prod.nombre_del_producto as nombre_producto,
        (pe.proyeccion_cajas - COALESCE(pb.total_programmed, 0))::INT as cantidad_restante,
        pe.proyeccion_cajas::INT as meta_total
    FROM public.proyecciones_estrategicas pe
    JOIN public.usa_productos prod ON pe.producto_id = prod.id
    LEFT JOIN programmed_boxes pb ON pe.producto_id = pb.product_id
    WHERE pe.proyecto_id = p_project_id 
      AND pe.semana_fiscal = p_week
      AND pe.autorizado = true
      AND (pe.proyeccion_cajas - COALESCE(pb.total_programmed, 0)) > 0;
END;
$$;


ALTER FUNCTION "public"."get_remaining_authorized_boxes"("p_project_id" "uuid", "p_week" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$BEGIN
  INSERT INTO public.profiles (id, email,role)
  VALUES (new.id, new.email,'Administrativo'::user_role);
  RETURN new;
END;$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_auri_balance"("user_id_input" "uuid", "amount_input" numeric) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  UPDATE profiles
  SET in_app_auri_balance = COALESCE(in_app_auri_balance, 0) + amount_input
  WHERE id = user_id_input;
END;
$$;


ALTER FUNCTION "public"."increment_auri_balance"("user_id_input" "uuid", "amount_input" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_default_auri_users"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  DELETE FROM profiles
  WHERE name = 'Usuario Auri'
  AND created_at < NOW() - INTERVAL '15 days';
END;
$$;


ALTER FUNCTION "public"."purge_default_auri_users"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_inventory_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.ultima_actualizacion = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_inventory_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."advertisements" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "title" "text" NOT NULL,
    "sponsor" "text" NOT NULL,
    "image_url" "text" NOT NULL,
    "link" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."advertisements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."alert_recipients" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "telefono" "text" NOT NULL,
    "activo" boolean DEFAULT true,
    "hora_inicio" smallint,
    "hora_fin" smallint,
    "dias_activos" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."alert_recipients" OWNER TO "postgres";


ALTER TABLE "public"."alert_recipients" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."alert_recipients_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."alert_settings" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "phone_number_1" "text",
    "phone_number_2" "text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."alert_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."industria_clientes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "direccion" "text"
);


ALTER TABLE "public"."industria_clientes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."industria_escalas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text" NOT NULL
);


ALTER TABLE "public"."industria_escalas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."industria_estatus" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "color" "text"
);


ALTER TABLE "public"."industria_estatus" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."industria_productos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre_del_producto" "text",
    "almacenado_frio" boolean,
    "temp_limite_inferior" numeric,
    "temp_optima" "text",
    "temp_limite_superior" numeric,
    "se_puede_consolidar" boolean,
    "consolidar_con" "text",
    "temp_continua_o_ciclos" "text"
);


ALTER TABLE "public"."industria_productos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."industria_proyectos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "direccion" "text"
);


ALTER TABLE "public"."industria_proyectos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."industria_shipment_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" DEFAULT 'Industria'::"text" NOT NULL,
    "trip_id" "text" NOT NULL,
    "client" "text",
    "destination" "text",
    "packing_departure" timestamp with time zone,
    "destination_arrival" timestamp with time zone,
    "logistic_status" "text",
    "transport" "text",
    "operator" "text",
    "freight_cost" numeric,
    "remission" "text",
    "product" "text",
    "products" "jsonb",
    "notes" "text",
    "comments" "text",
    "programacion_id" "text",
    "tipo_unidad" "text",
    "modo_transporte" "text",
    "incidents" "text",
    "consolidado" boolean DEFAULT false,
    "temp_status" "text",
    "pallets" integer,
    "temperature_history" "jsonb",
    "location_history" "jsonb",
    "escalas" "jsonb" DEFAULT '[]'::"jsonb"
);


ALTER TABLE "public"."industria_shipment_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."inventario_proyectos" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "proyecto_id" "uuid",
    "producto_id" "uuid",
    "stock_disponible" integer DEFAULT 0,
    "stock_reservado" integer DEFAULT 0,
    "ultima_actualizacion" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."inventario_proyectos" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventario_proyectos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."lider_programacion_usa_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" DEFAULT 'LiderProgramacionUsa'::"text" NOT NULL,
    "lote_id" "text",
    "semana" integer,
    "carga_semanal" "text",
    "proyecto" "text",
    "productos" "jsonb",
    "temperatura_ideal" numeric,
    "pallets" integer,
    "cajas" integer,
    "fecha_salida" timestamp with time zone,
    "fecha_llegada" timestamp with time zone,
    "usa_logistics_status" "text",
    "area" "text",
    "is_consolidated" boolean DEFAULT false,
    "secondary_project" "text",
    "secondary_project_id" "text",
    "suggested_unit" "text",
    "comentarios" "text",
    "consolidation_partner_id" "uuid",
    "project_id" "uuid",
    "semana_fiscal" integer,
    "datos_transporte" "jsonb" DEFAULT '[]'::"jsonb",
    "client_id" "uuid",
    "assigned_trip_id" "text",
    CONSTRAINT "check_logistics_status" CHECK (("usa_logistics_status" = ANY (ARRAY['Programado'::"text", 'Esperando Consolidacion'::"text", 'Cargado'::"text", 'Cancelado'::"text"])))
);

ALTER TABLE ONLY "public"."lider_programacion_usa_reports" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."lider_programacion_usa_reports" OWNER TO "postgres";


COMMENT ON COLUMN "public"."lider_programacion_usa_reports"."lote_id" IS 'ID opcional para control interno del líder. Tráfico asignará el Folio Real.';



COMMENT ON COLUMN "public"."lider_programacion_usa_reports"."pallets" IS 'Cantidad de pallets calculados (corregido por script de mantenimiento para consistencia visual).';



COMMENT ON COLUMN "public"."lider_programacion_usa_reports"."fecha_salida" IS 'Fecha clave para las notificaciones en el radar de Coordinación.';



COMMENT ON COLUMN "public"."lider_programacion_usa_reports"."datos_transporte" IS 'Almacena borrador de choferes y unidades antes del inicio formal del viaje.';



COMMENT ON COLUMN "public"."lider_programacion_usa_reports"."assigned_trip_id" IS 'Folio de viaje (ID de Viaje) generado por Coordinación vinculado a este lote.';



CREATE TABLE IF NOT EXISTS "public"."location_history" (
    "id" bigint NOT NULL,
    "trip_id" "text" NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"() NOT NULL,
    "location" "text" NOT NULL,
    "details" "text",
    "latitude" double precision,
    "longitude" double precision,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."location_history" OWNER TO "postgres";


ALTER TABLE "public"."location_history" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."location_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."log_geocercas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "shipment_id" "uuid",
    "tipo_evento" "text",
    "zona_nombre" "text",
    "lat" double precision,
    "lng" double precision,
    "timestamp" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."log_geocercas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacional_logistic_statuses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" NOT NULL,
    "display_order" integer
);


ALTER TABLE "public"."nacional_logistic_statuses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacional_shipment_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" DEFAULT 'Nacional'::"text" NOT NULL,
    "trip_id" "text" NOT NULL,
    "week_number" integer,
    "packing_departure" timestamp with time zone,
    "origin" "text",
    "producer" "text",
    "destination_arrival" timestamp with time zone,
    "client" "text",
    "remission" "text",
    "product" "text",
    "products" "jsonb",
    "trip_configuration" "text",
    "logistic_status" "text",
    "transport" "text",
    "operator" "text",
    "freight_cost" numeric,
    "responsible" "text",
    "notes" "text",
    "locus" "text",
    "transit_time" "text",
    "incidents" "text",
    "comments" "text",
    "programacion_id" "text",
    "tipo_unidad" "text",
    "modo_transporte" "text",
    "consolidado" boolean DEFAULT false,
    "temp_status" "text",
    "pallets" integer,
    "temperature_history" "jsonb",
    "location_history" "jsonb",
    "escalas" "jsonb" DEFAULT '[]'::"jsonb"
);


ALTER TABLE "public"."nacional_shipment_reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacionales_clientes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "direccion" "text"
);


ALTER TABLE "public"."nacionales_clientes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacionales_escalas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text" NOT NULL
);


ALTER TABLE "public"."nacionales_escalas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacionales_estatus" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "color" "text"
);


ALTER TABLE "public"."nacionales_estatus" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacionales_productos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre_del_producto" "text",
    "almacenado_frio" boolean,
    "temp_limite_inferior" numeric,
    "temp_optima" "text",
    "temp_limite_superior" numeric,
    "se_puede_consolidar" boolean,
    "consolidar_con" "text",
    "temp_continua_o_ciclos" "text",
    "limite_inferior" "text",
    "limite_superior" "text",
    "puede_consolidar" boolean,
    "productos_consolida" "text",
    "alias_supermercados" "text",
    "alias_usa" "text",
    "config_usa" "text",
    "peso_usa" double precision
);


ALTER TABLE "public"."nacionales_productos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nacionales_proyectos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "direccion" "text"
);


ALTER TABLE "public"."nacionales_proyectos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."offline_sync_audit" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "device_id" "text",
    "user_name" "text",
    "table_target" "text" NOT NULL,
    "operation_type" "text" NOT NULL,
    "payload" "jsonb" NOT NULL,
    "sync_status" "text" DEFAULT 'PENDING'::"text",
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "synced_at" timestamp with time zone
);


ALTER TABLE "public"."offline_sync_audit" OWNER TO "postgres";


COMMENT ON TABLE "public"."offline_sync_audit" IS 'Bitácora de seguridad para reconstrucción de datos guardados en modo offline.';



CREATE TABLE IF NOT EXISTS "public"."private_messages" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "from_user" "text" NOT NULL,
    "to_user" "text" NOT NULL,
    "message_text" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."private_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text",
    "role" "public"."user_role"
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."proyecciones_estrategicas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "semana_fiscal" integer NOT NULL,
    "canal_venta" "text" DEFAULT 'USA'::"text",
    "lider_proyecto_id" "uuid",
    "proyecto_id" "uuid",
    "producto_id" "uuid",
    "presupuesto_monetario" numeric(12,2) DEFAULT 0,
    "proyeccion_cajas" integer DEFAULT 0,
    "venta_2023_referencia" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "ng_2025" integer DEFAULT 0,
    "autorizado" boolean DEFAULT false,
    "fecha_salida" "date",
    "fecha_llegada" "date",
    "total_tarimas" numeric DEFAULT 0,
    "camiones_calculados" numeric DEFAULT 0,
    "venta_real_manual" integer DEFAULT 0,
    "lunes" integer DEFAULT 0,
    "martes" integer DEFAULT 0,
    "miercoles" integer DEFAULT 0,
    "jueves" integer DEFAULT 0,
    "viernes" integer DEFAULT 0,
    "sabado" integer DEFAULT 0,
    "domingo" integer DEFAULT 0,
    "ultima_sincronizacion" timestamp with time zone,
    "client_id" "uuid",
    "comentarios_rechazo" "text",
    "ss_2025" numeric DEFAULT 0,
    "precio_venta_2025" numeric DEFAULT 0,
    "linea_transportista_id" "uuid",
    "unidad_transporte_id" "uuid",
    "desglose_diario" "jsonb" DEFAULT '[]'::"jsonb",
    "canje_productos" "jsonb" DEFAULT '[]'::"jsonb",
    "sort_order" integer DEFAULT 0,
    "referencias_anuales" "jsonb" DEFAULT '{}'::"jsonb"
);

ALTER TABLE ONLY "public"."proyecciones_estrategicas" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."proyecciones_estrategicas" OWNER TO "postgres";


COMMENT ON TABLE "public"."proyecciones_estrategicas" IS 'Sincronizado con Mapeo Diario v2.1 (Soporta ultima_sincronizacion)';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."fecha_salida" IS 'Fecha oficial de despacho utilizada para el posicionamiento en el grid diario.';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."comentarios_rechazo" IS 'Razón técnica del rechazo proporcionada por Subdirección o Dirección.';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."ss_2025" IS 'Precio unitario de compra pactado para el ciclo 2025.';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."precio_venta_2025" IS 'Precio unitario de venta pactado para el ciclo 2025.';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."desglose_diario" IS 'Arreglo de objetos {fecha, cantidad} para envíos parciales.';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."canje_productos" IS 'Productos sustitutos cuando no se completa el volumen programado. Arreglo de {productId, quantity}.';



COMMENT ON COLUMN "public"."proyecciones_estrategicas"."sort_order" IS 'Orden personalizado para la visualización en la matriz estratégica.';



CREATE TABLE IF NOT EXISTS "public"."push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_name" "text" NOT NULL,
    "subscription" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);

ALTER TABLE ONLY "public"."push_subscriptions" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."push_subscriptions" OWNER TO "postgres";


COMMENT ON TABLE "public"."push_subscriptions" IS 'Repositorio central de dispositivos para el motor Phoenix de notificaciones externas.';



CREATE TABLE IF NOT EXISTS "public"."usa_productos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "nombre_del_producto" "text" NOT NULL,
    "categoria" "text" DEFAULT 'Vegetales'::"text",
    "alias_usa" "text",
    "config_usa" "text",
    "peso_usa" numeric,
    "cajas_pallet_usa" integer DEFAULT 50,
    "limite_tolerable" "text",
    "temp_optima" numeric,
    "limite_superior" numeric,
    "almacenado_frio" boolean DEFAULT true,
    "puede_consolidar" boolean DEFAULT true,
    "alias_supermercados" "text",
    "color" "text",
    "nombre_insumo" "text",
    "etiqueta" "text",
    "fleje" "text",
    "tarima" "text",
    "gasto_caja" numeric DEFAULT 0,
    "gasto_etiqueta" numeric DEFAULT 0,
    "gasto_fleje" numeric DEFAULT 0,
    "gasto_tarima" numeric DEFAULT 0,
    "activo" boolean DEFAULT true
);

ALTER TABLE ONLY "public"."usa_productos" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_productos" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_productos" IS 'Tabla sincronizada con el módulo de Base de Datos v4.0';



CREATE TABLE IF NOT EXISTS "public"."usa_proyectos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "direccion" "text",
    "maps_link" "text",
    "tiempo_optimo" numeric,
    "tiempo_tolerable" numeric,
    "capacidad_carga_pallets" integer DEFAULT 30,
    "lat" double precision,
    "lng" double precision,
    "radio_geocerca_metros" integer DEFAULT 500
);

ALTER TABLE ONLY "public"."usa_proyectos" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_proyectos" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_proyectos" IS 'Almacena los proyectos específicos del área de Estados Unidos.';



CREATE OR REPLACE VIEW "public"."reporte_cumplimiento_seguimiento" WITH ("security_invoker"='on') AS
 SELECT "pe"."id" AS "proyeccion_id",
    "pe"."semana_fiscal",
    "proj"."nombre" AS "proyecto_nombre",
    "prod"."nombre_del_producto" AS "producto_nombre",
    "pe"."proyeccion_cajas",
    "pe"."lunes",
    "pe"."martes",
    "pe"."miercoles",
    "pe"."jueves",
    "pe"."viernes",
    "pe"."sabado",
    "pe"."domingo",
    "pe"."autorizado",
    "pe"."venta_real_manual",
    "pe"."ultima_sincronizacion"
   FROM (("public"."proyecciones_estrategicas" "pe"
     LEFT JOIN "public"."usa_proyectos" "proj" ON (("pe"."proyecto_id" = "proj"."id")))
     LEFT JOIN "public"."usa_productos" "prod" ON (("pe"."producto_id" = "prod"."id")));


ALTER VIEW "public"."reporte_cumplimiento_seguimiento" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."system_audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "user_name" "text" NOT NULL,
    "user_role" "text" NOT NULL,
    "action_type" "text" NOT NULL,
    "module" "text" NOT NULL,
    "details" "jsonb" DEFAULT '{}'::"jsonb",
    "ip_address" "text"
);


ALTER TABLE "public"."system_audit_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."system_audit_logs" IS 'Bitácora oficial de acciones críticas para cumplimiento normativo y fiscal.';



CREATE TABLE IF NOT EXISTS "public"."system_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_type" "text" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL
);


ALTER TABLE "public"."system_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."system_logs" IS 'Tabla de auditoría operativa - Branding v1.0';



CREATE TABLE IF NOT EXISTS "public"."temperature_history" (
    "id" bigint NOT NULL,
    "trip_id" "text" NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reading" double precision NOT NULL,
    "status" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."temperature_history" OWNER TO "postgres";


ALTER TABLE "public"."temperature_history" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."temperature_history_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tipo_unidad" (
    "id" bigint NOT NULL,
    "unidad" "text" NOT NULL,
    "capacidad" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."tipo_unidad" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."tipo_unidad" OWNER TO "postgres";


ALTER TABLE "public"."tipo_unidad" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."tipo_unidad_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."tive_alert_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "tracker_id" "text" NOT NULL,
    "temp_min" numeric DEFAULT 32,
    "temp_max" numeric DEFAULT 45,
    "enable_movement_alerts" boolean DEFAULT true,
    "enable_stop_alerts" boolean DEFAULT true,
    "cooldown_minutes" integer DEFAULT 30
);

ALTER TABLE ONLY "public"."tive_alert_config" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."tive_alert_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tive_alert_dictionary" (
    "alert_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "severity" "text" DEFAULT 'warning'::"text"
);

ALTER TABLE ONLY "public"."tive_alert_dictionary" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."tive_alert_dictionary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tive_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tracker_id" "text" NOT NULL,
    "timestamp" timestamp with time zone DEFAULT "now"(),
    "temperature" numeric,
    "humidity" numeric,
    "location" "text",
    "lat" double precision,
    "lng" double precision,
    "battery" integer,
    "alert_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "raw_data" "jsonb",
    "speed" double precision
);

ALTER TABLE ONLY "public"."tive_events" REPLICA IDENTITY FULL;

ALTER TABLE ONLY "public"."tive_events" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."tive_events" OWNER TO "postgres";


COMMENT ON TABLE "public"."tive_events" IS 'Historial de telemetría cruda recibida vía Webhook Tive.';



COMMENT ON COLUMN "public"."tive_events"."raw_data" IS 'Almacena el payload completo de Tive para análisis profundo y auditoría.';



COMMENT ON COLUMN "public"."tive_events"."speed" IS 'Velocidad en Km/h. Optimizada para capturar ráfagas de datos de sensores dinámicos.';



CREATE TABLE IF NOT EXISTS "public"."trackers" (
    "tracker_id" "text" NOT NULL,
    "shipment_id" "uuid" NOT NULL,
    "shipment_table" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."trackers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transferencias_stock" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "proyecto_origen_id" "uuid",
    "proyecto_destino_id" "uuid",
    "producto_id" "uuid",
    "cantidad" integer NOT NULL,
    "estatus" "text" DEFAULT 'Pendiente'::"text",
    "lote_vinculado_id" "uuid",
    "fecha_solicitud" timestamp with time zone DEFAULT "now"(),
    "fecha_resolucion" timestamp with time zone,
    "comentarios" "text"
);

ALTER TABLE ONLY "public"."transferencias_stock" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."transferencias_stock" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_brockers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text"
);


ALTER TABLE "public"."usa_brockers" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_brockers" IS 'Lista de brockers para el área de Estados Unidos.';



CREATE TABLE IF NOT EXISTS "public"."usa_catalogo_danos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "categoria" "text",
    "key_dano" "text",
    "label" "text",
    "grado" "text",
    "limite_amarillo" numeric,
    "limite_rojo" numeric,
    "condicion" boolean DEFAULT true
);


ALTER TABLE "public"."usa_catalogo_danos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_clientes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "direccion" "text",
    "radio_geocerca_metros" integer DEFAULT 1000,
    "lat" double precision,
    "lng" double precision,
    CONSTRAINT "check_radio_positivo_cliente" CHECK (("radio_geocerca_metros" >= 50))
);

ALTER TABLE ONLY "public"."usa_clientes" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_clientes" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_clientes" IS 'Lista de clientes del área de Estados Unidos.';



CREATE TABLE IF NOT EXISTS "public"."usa_embarques" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "fecha_embarque" timestamp without time zone NOT NULL,
    "folio_embarque" "text",
    "linea_transporte" "text",
    "nombre_operador" "text",
    "placas_caja" "text",
    "placas_tractor" "text",
    "temperatura_viaje" numeric,
    "destino" "text",
    "foto_remision" "text",
    "foto_termografo" "text",
    "foto_diesel" "text",
    "foto_refacciones" "text",
    "foto_temperatura" "text",
    "estatus_embarque" "text",
    "alerta_inspeccion_pt" boolean,
    "diferencias_auditoria" "jsonb"
);


ALTER TABLE "public"."usa_embarques" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_embarques_detalle" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "embarque_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "producto_id" "uuid" DEFAULT "gen_random_uuid"(),
    "remision" "text",
    "mid" "text",
    "lote_pt" "text",
    "cantidad_cajas" numeric,
    "tipo_empaque" "text",
    "peso_total" numeric
);


ALTER TABLE "public"."usa_embarques_detalle" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_escalas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text" NOT NULL
);


ALTER TABLE "public"."usa_escalas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_estatus" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text",
    "color" "text"
);

ALTER TABLE ONLY "public"."usa_estatus" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_estatus" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_estatus" IS 'Define los diferentes estatus y sus colores para el área de Estados Unidos.';



CREATE TABLE IF NOT EXISTS "public"."usa_fotos_inspeccion" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "inspeccion_id" "uuid" DEFAULT "gen_random_uuid"(),
    "foto_url" "text"
);


ALTER TABLE "public"."usa_fotos_inspeccion" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_huertas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "productor_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nombre_huerta" "text",
    "mid" "text",
    "condicion" boolean DEFAULT true
);


ALTER TABLE "public"."usa_huertas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_huertas_producto" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "huerta_id" "uuid" DEFAULT "gen_random_uuid"(),
    "producto_id" "uuid" DEFAULT "gen_random_uuid"()
);


ALTER TABLE "public"."usa_huertas_producto" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_inspecciones" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "producto_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "productor_id" "uuid" DEFAULT "gen_random_uuid"(),
    "huerta_id" "uuid" DEFAULT "gen_random_uuid"(),
    "tipo_inspeccion" "text",
    "zona" "text",
    "inspector" "text",
    "campo_mallas" "text",
    "tamano_muestra" numeric,
    "detalles_danos" "jsonb",
    "calidad_score" numeric,
    "estatus" "text",
    "observaciones" "text",
    "created_at" timestamp without time zone DEFAULT "now"(),
    "lote_origen" "text",
    "peso_neto" numeric,
    "maquina" "text",
    "lote_produccion" "text",
    "fecha_cosecha" "date",
    "peso_muestra_con_caja" numeric,
    "peso_caja" numeric,
    "peso_caja_sin_caja" numeric,
    "destino" "text",
    "numero_tarima" "text",
    "tarima_reprocesada" "text",
    "tarima_remuestreada" "text",
    "etiqueta_azul" "text",
    "peso_bascula" numeric,
    "resultado_calidad" "text",
    "accion_correctiva" "text",
    "canal_venta" "text"
);


ALTER TABLE "public"."usa_inspecciones" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_inspecciones_ia_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "inspeccion_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "foto_analizada_url" "text",
    "prompt_utilizado" "text",
    "respuesta_raw_ia" "jsonb",
    "precision_aprobada" boolean,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."usa_inspecciones_ia_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_lineas_transporte" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nombre" "text" NOT NULL,
    "contacto_emergencia" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."usa_lineas_transporte" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_lineas_transporte" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_productores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nombre_productor" "text",
    "condicion" boolean DEFAULT true
);


ALTER TABLE "public"."usa_productores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_proyecto_producto" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()) NOT NULL,
    "proyecto_id" "uuid",
    "producto_id" "uuid"
);

ALTER TABLE ONLY "public"."usa_proyecto_producto" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_proyecto_producto" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_proyecto_producto" IS 'Vinculación oficial entre empaques y sus productos autorizados.';



CREATE TABLE IF NOT EXISTS "public"."usa_responsables" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nombre" "text" NOT NULL,
    "puesto" "text",
    "horario_atencion" "text",
    "correo" "text",
    "numero_whatsapp" "text"
);

ALTER TABLE ONLY "public"."usa_responsables" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_responsables" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_servicios_aduanales" (
    "trip_id" "text" NOT NULL,
    "proveedor" "text" NOT NULL,
    "concepto" "text",
    "monto" numeric,
    "folio_factura" "text",
    "uuid" "text",
    "estatus_pago" "text",
    "responsable_pago" "text",
    "is_consolidated" boolean DEFAULT false,
    "desglose" "jsonb"
);


ALTER TABLE "public"."usa_servicios_aduanales" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_servicios_complementarios" (
    "trip_id" "text" NOT NULL,
    "proveedor" "text" NOT NULL,
    "concepto" "text",
    "monto" numeric,
    "folio_factura" "text",
    "uuid" "text",
    "responsable_pago" "text",
    "is_consolidated" boolean DEFAULT false,
    "desglose" "jsonb"
);


ALTER TABLE "public"."usa_servicios_complementarios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_shipment_alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "shipment_id" "uuid",
    "trip_id" "text",
    "alert_type" "text",
    "message" "text",
    "severity" "text" DEFAULT 'warning'::"text",
    "is_read" boolean DEFAULT false,
    "comment" "text"
);

ALTER TABLE ONLY "public"."usa_shipment_alerts" REPLICA IDENTITY FULL;

ALTER TABLE ONLY "public"."usa_shipment_alerts" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_shipment_alerts" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_shipment_alerts" IS 'Central de alertas para el motor de notificaciones en tiempo real.';



COMMENT ON COLUMN "public"."usa_shipment_alerts"."comment" IS 'Comentario de seguimiento u observación del operador sobre la alerta.';



CREATE TABLE IF NOT EXISTS "public"."usa_shipment_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" DEFAULT 'USA'::"text" NOT NULL,
    "trip_id" "text" NOT NULL,
    "project" "text",
    "departure_date_time" timestamp with time zone,
    "arrival_date_time" timestamp with time zone,
    "invoice" "jsonb",
    "logistic_status" "text" DEFAULT 'Pendiente'::"text",
    "current_temp" numeric,
    "ideal_temp" numeric,
    "temp_status" "text" DEFAULT 'Óptimo'::"text",
    "brokers" "text",
    "freight_forwarder" "text",
    "tracking_link" "text",
    "carrier" "text",
    "operator" "text",
    "freight_cost" numeric DEFAULT 0,
    "thermograph_serial" "text",
    "products" "jsonb",
    "responsible_tm" "text",
    "responsible_tv" "text",
    "responsible_docs" "text",
    "trip_number" "text",
    "packing_report_id" "text",
    "temperature_history" "jsonb",
    "location_history" "jsonb",
    "programacion_id" "text",
    "cliente" "text",
    "tipo_unidad" "text",
    "modo_transporte" "text",
    "incidents" "text" DEFAULT '[]'::"jsonb",
    "consolidado" boolean DEFAULT false,
    "pallets" integer,
    "escalas" "jsonb" DEFAULT '[]'::"jsonb",
    "is_insumos" boolean DEFAULT false NOT NULL,
    "insumos_origen" "text",
    "insumos_destino" "text",
    "insumos_desglose" "text",
    "client_id" "uuid",
    "unit_type" "text",
    "driver_name" "text",
    "box_number" "text",
    "seal_number" "text",
    "temperature" "text",
    "responsible_id" "uuid",
    "tive_tracker_id" "text",
    "is_consolidated" boolean DEFAULT false,
    "secondary_project" "text",
    "secondary_project_id" "text",
    "project_id" "uuid",
    "comments" "text",
    "has_thermal_excursion" boolean DEFAULT false,
    "expected_arrival" timestamp with time zone,
    "invoice_number" "text",
    "invoice_url" "text",
    "sucursal_id" "uuid",
    "stop_over_project_id" "uuid",
    "arrived_at_stop_over" timestamp with time zone,
    "departed_from_stop_over" timestamp with time zone,
    "linea_transportista_id" "uuid",
    "unidad_transporte_id" "uuid",
    "lote_original_id" "uuid",
    "caat" "text",
    "alpha" "text",
    "transfer_agent" "text",
    "transfer_phone" "text",
    "transfer_name" "text",
    "phone_number" "text",
    "tractor_plates" "text",
    "lote_secundario_id" "uuid",
    "last_known_eta" timestamp with time zone,
    "total_real_boxes" numeric,
    "carrier_rating" integer,
    "carrier_rating_comments" "text",
    "rating_pending" boolean DEFAULT false,
    "extra_costs" numeric DEFAULT 0,
    "fines" numeric DEFAULT 0,
    "freight_payer" "text",
    "reviewer_id" "text",
    "passed_to_payment" boolean DEFAULT false,
    "passed_to_payment_date" timestamp with time zone,
    "invoice_received" boolean DEFAULT false,
    "invoice_received_date" timestamp with time zone,
    "carrier_invoice_number" "text",
    "fiscal_folio" "text",
    "freight_in_portfolio" boolean DEFAULT false,
    "payment_status" "text" DEFAULT 'Pendiente'::"text",
    "real_departure_date" timestamp with time zone,
    "lotes_asociados" "jsonb" DEFAULT '[]'::"jsonb",
    "min_temp" numeric,
    "client_ids" "uuid"[],
    "driver_phone" "text",
    "requires_comp_services" boolean DEFAULT false,
    "requires_customs_services" boolean DEFAULT false,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "usa_shipment_reports_carrier_rating_check" CHECK ((("carrier_rating" >= 1) AND ("carrier_rating" <= 5)))
);

ALTER TABLE ONLY "public"."usa_shipment_reports" REPLICA IDENTITY FULL;

ALTER TABLE ONLY "public"."usa_shipment_reports" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_shipment_reports" OWNER TO "postgres";


COMMENT ON TABLE "public"."usa_shipment_reports" IS 'Soporte v3.0: Navegación inferior y Deeplinking activo.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."trip_id" IS 'ID de Viaje único asignado manualmente por el Coordinador Logístico.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."arrival_date_time" IS 'Fecha y hora exacta de llegada al destino (Llegada Real)';



COMMENT ON COLUMN "public"."usa_shipment_reports"."ideal_temp" IS 'Temperatura meta (F) seteada al momento del despacho para validación de excursión.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."freight_cost" IS 'Costo pactado del flete por unidad.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."products" IS 'Arreglo JSONB que almacena productId, quantity, realQty, invoiceNumber, invoiceUrl y originProjectId para trazabilidad total.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."has_thermal_excursion" IS 'Indica si el último reporte de telemetría está fuera del rango óptimo.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."invoice_number" IS 'Folio de factura principal del embarque para visualización rápida.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."invoice_url" IS 'Enlace al documento digital de la factura.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."sucursal_id" IS 'Identificador del punto de carga específico (Sucursal/Bodega) donde se origina el despacho.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."stop_over_project_id" IS 'ID de la sede consolidadora (E2). El campo project_id original actúa como E1 (Origen).';



COMMENT ON COLUMN "public"."usa_shipment_reports"."lote_original_id" IS 'ID del Lote Principal seleccionado desde el formulario.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."caat" IS 'Código CAAT de la línea transportista.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."alpha" IS 'Código ALPHA (SCAC) para cruce fronterizo.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."lote_secundario_id" IS 'ID del Lote Secundario (E2)';



COMMENT ON COLUMN "public"."usa_shipment_reports"."total_real_boxes" IS 'Conteo físico real ingresado por Tráfico, independiente del proyectado.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."rating_pending" IS 'Indica si un viaje finalizado automáticamente por geocerca requiere feedback.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."extra_costs" IS 'Insumos, estadías y otros costos extra.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."fines" IS 'Multas aplicadas al transportista.';



COMMENT ON COLUMN "public"."usa_shipment_reports"."real_departure_date" IS 'Fecha y hora exacta de salida del empaque (Salida Real)';



CREATE TABLE IF NOT EXISTS "public"."usa_sucursales" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "proyecto_id" "uuid",
    "nombre_sucursal" "text" NOT NULL,
    "direccion" "text" NOT NULL,
    "lat" double precision,
    "lng" double precision,
    "es_principal" boolean DEFAULT false,
    "radio_geocerca_metros" integer DEFAULT 500,
    "created_at" timestamp with time zone DEFAULT "timezone"('utc'::"text", "now"()),
    CONSTRAINT "check_radio_positivo" CHECK (("radio_geocerca_metros" >= 50))
);

ALTER TABLE ONLY "public"."usa_sucursales" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_sucursales" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_unidades_transporte" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "linea_id" "uuid",
    "placas_tractor" "text" NOT NULL,
    "placas_caja" "text",
    "numero_economico" "text",
    "tipo_unidad" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tipo_unidad_id" bigint
);

ALTER TABLE ONLY "public"."usa_unidades_transporte" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_unidades_transporte" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."usa_usuarios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "email" "text" NOT NULL,
    "role" "text" NOT NULL,
    "nombre" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "productor_id" "uuid"
);


ALTER TABLE "public"."usa_usuarios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ventas_domesticas_reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "type" "text" DEFAULT 'VentasDomesticas'::"text" NOT NULL,
    "año" integer,
    "semana" integer,
    "carga_semanal" "text",
    "cliente" "text",
    "origen" "text",
    "destino" "text",
    "productos" "jsonb",
    "fecha_carga" "date",
    "fecha_hora_cita" timestamp with time zone,
    "oc" "text",
    "cita" "text",
    "estatus_cita" "text",
    "factura" "jsonb",
    "estatus_comercial" "text",
    "estatus_produccion" "text",
    "logistics_status" "text",
    "pallets" numeric,
    "kilos_por_caja" numeric,
    "kilos_totales" numeric,
    "fecha_empaque" "date",
    "fecha_consumo_preferente" "date",
    "embalaje" "text",
    "estiba" "text",
    "comentarios" "text",
    "cajas_enviadas" integer,
    "cajas_recibidas" integer,
    "linea" "text",
    "reedireccion" "text",
    "area" "text"
);


ALTER TABLE "public"."ventas_domesticas_reports" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vista_cumplimiento_ejecutivo" WITH ("security_invoker"='on') AS
 WITH "real_data" AS (
         SELECT "usr"."project_id",
            COALESCE("p"."product_id", "p"."productId") AS "product_id",
            "sum"(COALESCE("p"."real_qty", "p"."realQty", "p"."quantity", 0)) AS "real_acumulado"
           FROM "public"."usa_shipment_reports" "usr",
            LATERAL "jsonb_to_recordset"("usr"."products") "p"("product_id" "uuid", "productId" "uuid", "quantity" integer, "real_qty" integer, "realQty" integer)
          WHERE (("usr"."logistic_status" ~~* 'En Tránsito'::"text") OR ("usr"."logistic_status" ~~* 'Finalizado'::"text") OR ("usr"."logistic_status" ~~* 'Cargado'::"text") OR ("usr"."logistic_status" ~~* 'Confirmado'::"text"))
          GROUP BY "usr"."project_id", COALESCE("p"."product_id", "p"."productId")
        )
 SELECT "pe"."semana_fiscal",
    "prod"."categoria",
    "prod"."nombre_del_producto",
    "pe"."ng_2025" AS "venta_ng_2025",
    "pe"."presupuesto_monetario" AS "presupuesto",
    "pe"."proyeccion_cajas",
    COALESCE("rd"."real_acumulado", (0)::bigint) AS "real_acumulado"
   FROM (("public"."proyecciones_estrategicas" "pe"
     JOIN "public"."usa_productos" "prod" ON (("pe"."producto_id" = "prod"."id")))
     LEFT JOIN "real_data" "rd" ON ((("pe"."proyecto_id" = "rd"."project_id") AND ("pe"."producto_id" = "rd"."product_id"))));


ALTER VIEW "public"."vista_cumplimiento_ejecutivo" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vista_eficiencia_transito" WITH ("security_invoker"='on') AS
 SELECT "trip_id",
    "departure_date_time",
    "arrival_date_time",
    (EXTRACT(epoch FROM ("arrival_date_time" - "departure_date_time")) / (3600)::numeric) AS "horas_totales"
   FROM "public"."usa_shipment_reports"
  WHERE ("logistic_status" = 'Finalizado'::"text");


ALTER VIEW "public"."vista_eficiencia_transito" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vista_logs_geocerca" WITH ("security_invoker"='on') AS
 SELECT "lg"."id",
    "lg"."timestamp",
    "lg"."tipo_evento",
    "lg"."zona_nombre",
    "usr"."trip_id",
    "usr"."project" AS "proyecto_origen",
    "usr"."driver_name" AS "operador",
    "lg"."lat",
    "lg"."lng"
   FROM ("public"."log_geocercas" "lg"
     JOIN "public"."usa_shipment_reports" "usr" ON (("lg"."shipment_id" = "usr"."id")))
  ORDER BY "lg"."timestamp" DESC;


ALTER VIEW "public"."vista_logs_geocerca" OWNER TO "postgres";


COMMENT ON VIEW "public"."vista_logs_geocerca" IS 'Bitácora maestra de detecciones satelitales automáticas.';



CREATE OR REPLACE VIEW "public"."vista_metas_agotadas" WITH ("security_invoker"='on') AS
 WITH "total_programado" AS (
         SELECT "lp"."project_id",
            "lp"."semana_fiscal",
            "p"."product_id",
            "sum"("p"."quantity") AS "cantidad_total"
           FROM "public"."lider_programacion_usa_reports" "lp",
            LATERAL "jsonb_to_recordset"("lp"."productos") "p"("product_id" "uuid", "quantity" integer)
          GROUP BY "lp"."project_id", "lp"."semana_fiscal", "p"."product_id"
        )
 SELECT "pe"."id" AS "projection_id",
    "pe"."proyeccion_cajas",
    COALESCE("tp"."cantidad_total", (0)::bigint) AS "cajas_programadas",
    ("pe"."proyeccion_cajas" - COALESCE("tp"."cantidad_total", (0)::bigint)) AS "balance_restante"
   FROM ("public"."proyecciones_estrategicas" "pe"
     LEFT JOIN "total_programado" "tp" ON ((("pe"."proyecto_id" = "tp"."project_id") AND ("pe"."semana_fiscal" = "tp"."semana_fiscal") AND ("pe"."producto_id" = "tp"."product_id"))));


ALTER VIEW "public"."vista_metas_agotadas" OWNER TO "postgres";


ALTER TABLE ONLY "public"."advertisements"
    ADD CONSTRAINT "advertisements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alert_recipients"
    ADD CONSTRAINT "alert_recipients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."alert_settings"
    ADD CONSTRAINT "alert_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_clientes"
    ADD CONSTRAINT "industria_clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_escalas"
    ADD CONSTRAINT "industria_escalas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_estatus"
    ADD CONSTRAINT "industria_estatus_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_productos"
    ADD CONSTRAINT "industria_productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_proyectos"
    ADD CONSTRAINT "industria_proyectos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_shipment_reports"
    ADD CONSTRAINT "industria_shipment_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."industria_shipment_reports"
    ADD CONSTRAINT "industria_shipment_reports_trip_id_key" UNIQUE ("trip_id");



ALTER TABLE ONLY "public"."inventario_proyectos"
    ADD CONSTRAINT "inventario_proyectos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inventario_proyectos"
    ADD CONSTRAINT "inventario_proyectos_proyecto_id_producto_id_key" UNIQUE ("proyecto_id", "producto_id");



ALTER TABLE ONLY "public"."lider_programacion_usa_reports"
    ADD CONSTRAINT "lider_programacion_usa_reports_lote_id_key" UNIQUE ("lote_id");



ALTER TABLE ONLY "public"."lider_programacion_usa_reports"
    ADD CONSTRAINT "lider_programacion_usa_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."location_history"
    ADD CONSTRAINT "location_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."log_geocercas"
    ADD CONSTRAINT "log_geocercas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacional_logistic_statuses"
    ADD CONSTRAINT "nacional_logistic_statuses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacional_logistic_statuses"
    ADD CONSTRAINT "nacional_logistic_statuses_status_key" UNIQUE ("status");



ALTER TABLE ONLY "public"."nacional_shipment_reports"
    ADD CONSTRAINT "nacional_shipment_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacional_shipment_reports"
    ADD CONSTRAINT "nacional_shipment_reports_trip_id_key" UNIQUE ("trip_id");



ALTER TABLE ONLY "public"."nacionales_clientes"
    ADD CONSTRAINT "nacionales_clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacionales_escalas"
    ADD CONSTRAINT "nacionales_escalas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacionales_estatus"
    ADD CONSTRAINT "nacionales_estatus_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacionales_productos"
    ADD CONSTRAINT "nacionales_productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nacionales_proyectos"
    ADD CONSTRAINT "nacionales_proyectos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."offline_sync_audit"
    ADD CONSTRAINT "offline_sync_audit_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."private_messages"
    ADD CONSTRAINT "private_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proyecciones_estrategicas"
    ADD CONSTRAINT "proyecciones_estrategicas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_user_name_key" UNIQUE ("user_name");



ALTER TABLE ONLY "public"."system_audit_logs"
    ADD CONSTRAINT "system_audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."system_logs"
    ADD CONSTRAINT "system_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."temperature_history"
    ADD CONSTRAINT "temperature_history_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tipo_unidad"
    ADD CONSTRAINT "tipo_unidad_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tipo_unidad"
    ADD CONSTRAINT "tipo_unidad_unidad_key" UNIQUE ("unidad");



ALTER TABLE ONLY "public"."tive_alert_config"
    ADD CONSTRAINT "tive_alert_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."tive_alert_config"
    ADD CONSTRAINT "tive_alert_config_tracker_id_key" UNIQUE ("tracker_id");



ALTER TABLE ONLY "public"."tive_alert_dictionary"
    ADD CONSTRAINT "tive_alert_dictionary_pkey" PRIMARY KEY ("alert_key");



ALTER TABLE ONLY "public"."tive_events"
    ADD CONSTRAINT "tive_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trackers"
    ADD CONSTRAINT "trackers_pkey" PRIMARY KEY ("tracker_id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_brockers"
    ADD CONSTRAINT "usa_brockers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_catalogo_danos"
    ADD CONSTRAINT "usa_catalogo_danos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_clientes"
    ADD CONSTRAINT "usa_clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_embarques_detalle"
    ADD CONSTRAINT "usa_embarques_detalle_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_embarques"
    ADD CONSTRAINT "usa_embarques_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_escalas"
    ADD CONSTRAINT "usa_escalas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_estatus"
    ADD CONSTRAINT "usa_estatus_nombre_key" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."usa_estatus"
    ADD CONSTRAINT "usa_estatus_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_fotos_inspeccion"
    ADD CONSTRAINT "usa_fotos_inspeccion_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_huertas"
    ADD CONSTRAINT "usa_huertas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_huertas_producto"
    ADD CONSTRAINT "usa_huertas_producto_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_inspecciones_ia_logs"
    ADD CONSTRAINT "usa_inspecciones_ia_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_inspecciones"
    ADD CONSTRAINT "usa_inspecciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_lineas_transporte"
    ADD CONSTRAINT "usa_lineas_transporte_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_productores"
    ADD CONSTRAINT "usa_productores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_productos"
    ADD CONSTRAINT "usa_productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_proyecto_producto"
    ADD CONSTRAINT "usa_proyecto_producto_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_proyecto_producto"
    ADD CONSTRAINT "usa_proyecto_producto_proyecto_id_producto_id_key" UNIQUE ("proyecto_id", "producto_id");



ALTER TABLE ONLY "public"."usa_proyectos"
    ADD CONSTRAINT "usa_proyectos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_responsables"
    ADD CONSTRAINT "usa_responsables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_servicios_aduanales"
    ADD CONSTRAINT "usa_servicios_aduanales_pkey" PRIMARY KEY ("trip_id");



ALTER TABLE ONLY "public"."usa_servicios_complementarios"
    ADD CONSTRAINT "usa_servicios_complementarios_pkey" PRIMARY KEY ("trip_id");



ALTER TABLE ONLY "public"."usa_shipment_alerts"
    ADD CONSTRAINT "usa_shipment_alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_trip_id_key" UNIQUE ("trip_id");



ALTER TABLE ONLY "public"."usa_sucursales"
    ADD CONSTRAINT "usa_sucursales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_unidades_transporte"
    ADD CONSTRAINT "usa_unidades_transporte_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usa_usuarios"
    ADD CONSTRAINT "usa_usuarios_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."usa_usuarios"
    ADD CONSTRAINT "usa_usuarios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ventas_domesticas_reports"
    ADD CONSTRAINT "ventas_domesticas_reports_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_inventory_product" ON "public"."inventario_proyectos" USING "btree" ("producto_id");



CREATE INDEX "idx_inventory_project" ON "public"."inventario_proyectos" USING "btree" ("proyecto_id");



CREATE INDEX "idx_lider_assigned_trip" ON "public"."lider_programacion_usa_reports" USING "btree" ("assigned_trip_id");



CREATE INDEX "idx_lider_consolidacion_lookup" ON "public"."lider_programacion_usa_reports" USING "btree" ("semana_fiscal", "usa_logistics_status");



CREATE INDEX "idx_lider_consolidation" ON "public"."lider_programacion_usa_reports" USING "btree" ("consolidation_partner_id");



CREATE INDEX "idx_lider_fecha_salida" ON "public"."lider_programacion_usa_reports" USING "btree" ("fecha_salida");



CREATE INDEX "idx_lider_programacion_semana" ON "public"."lider_programacion_usa_reports" USING "btree" ("semana_fiscal");



CREATE INDEX "idx_lider_programacion_semana_proyecto" ON "public"."lider_programacion_usa_reports" USING "btree" ("semana_fiscal", "project_id");



CREATE INDEX "idx_lider_project" ON "public"."lider_programacion_usa_reports" USING "btree" ("proyecto");



CREATE INDEX "idx_lider_reports_semana" ON "public"."lider_programacion_usa_reports" USING "btree" ("semana_fiscal");



CREATE INDEX "idx_lineas_nombre" ON "public"."usa_lineas_transporte" USING "btree" ("nombre");



CREATE INDEX "idx_log_geocercas_shipment" ON "public"."log_geocercas" USING "btree" ("shipment_id");



CREATE INDEX "idx_lp_consolidation" ON "public"."lider_programacion_usa_reports" USING "btree" ("consolidation_partner_id");



CREATE INDEX "idx_offline_sync_user" ON "public"."offline_sync_audit" USING "btree" ("user_name");



CREATE INDEX "idx_proyecciones_semana" ON "public"."proyecciones_estrategicas" USING "btree" ("semana_fiscal");



CREATE INDEX "idx_proyecciones_semana_proyecto" ON "public"."proyecciones_estrategicas" USING "btree" ("semana_fiscal", "proyecto_id");



CREATE INDEX "idx_proyecciones_unique_lookup" ON "public"."proyecciones_estrategicas" USING "btree" ("proyecto_id", "producto_id", "semana_fiscal");



CREATE INDEX "idx_shipment_lote_origin" ON "public"."usa_shipment_reports" USING "btree" ("lote_original_id");



CREATE INDEX "idx_shipments_created" ON "public"."usa_shipment_reports" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_tive_events_tracker_timestamp" ON "public"."tive_events" USING "btree" ("tracker_id", "timestamp" DESC);



CREATE INDEX "idx_tive_timestamp" ON "public"."tive_events" USING "btree" ("timestamp" DESC);



CREATE INDEX "idx_tive_tracker" ON "public"."tive_events" USING "btree" ("tracker_id");



CREATE INDEX "idx_tracker_status" ON "public"."usa_shipment_reports" USING "btree" ("tive_tracker_id") WHERE ("logistic_status" <> 'Finalizado'::"text");



CREATE INDEX "idx_transfers_status" ON "public"."transferencias_stock" USING "btree" ("estatus");



CREATE INDEX "idx_unidades_linea" ON "public"."usa_unidades_transporte" USING "btree" ("linea_id");



CREATE INDEX "idx_usa_shipment_project" ON "public"."usa_shipment_reports" USING "btree" ("project");



CREATE INDEX "idx_usa_shipment_reports_programacion_id" ON "public"."usa_shipment_reports" USING "btree" ("programacion_id");



CREATE INDEX "idx_usa_shipment_sec_project" ON "public"."usa_shipment_reports" USING "btree" ("secondary_project");



CREATE INDEX "idx_usa_shipment_status" ON "public"."usa_shipment_reports" USING "btree" ("logistic_status");



CREATE INDEX "idx_usa_shipment_tive" ON "public"."usa_shipment_reports" USING "btree" ("tive_tracker_id");



CREATE INDEX "idx_usa_shipments_tive_tracker" ON "public"."usa_shipment_reports" USING "btree" ("tive_tracker_id");



CREATE INDEX "idx_usa_shipments_trip_id_lookup" ON "public"."usa_shipment_reports" USING "btree" ("trip_id");



CREATE INDEX "idx_usr_logistic_status" ON "public"."usa_shipment_reports" USING "btree" ("logistic_status");



CREATE INDEX "idx_usr_tive_tracker" ON "public"."usa_shipment_reports" USING "btree" ("tive_tracker_id");



CREATE INDEX "idx_usr_trip_id" ON "public"."usa_shipment_reports" USING "btree" ("trip_id");



CREATE INDEX "location_history_trip_id_idx" ON "public"."location_history" USING "btree" ("trip_id");



CREATE INDEX "temperature_history_trip_id_idx" ON "public"."temperature_history" USING "btree" ("trip_id");



CREATE OR REPLACE TRIGGER "Alerta_Cambio_Estatus" AFTER INSERT OR UPDATE ON "public"."usa_shipment_reports" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://sucvgevhsmxrpkpvrblm.supabase.co/functions/v1/tive-webhook', 'POST', '{"Content-type":"application/json"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "tr_push_on_alert" AFTER INSERT ON "public"."usa_shipment_alerts" FOR EACH ROW EXECUTE FUNCTION "public"."fn_dispatch_push_notification"();



CREATE OR REPLACE TRIGGER "tr_push_on_new_alert" AFTER INSERT ON "public"."usa_shipment_alerts" FOR EACH ROW EXECUTE FUNCTION "public"."fn_dispatch_alert_push"();



CREATE OR REPLACE TRIGGER "tr_push_on_status_change" AFTER UPDATE ON "public"."usa_shipment_reports" FOR EACH ROW EXECUTE FUNCTION "public"."fn_dispatch_push_notification"();



CREATE OR REPLACE TRIGGER "trigger_update_inventory_timestamp" BEFORE UPDATE ON "public"."inventario_proyectos" FOR EACH ROW EXECUTE FUNCTION "public"."update_inventory_timestamp"();



CREATE OR REPLACE TRIGGER "trigger_update_updated_at" BEFORE UPDATE ON "public"."usa_shipment_reports" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."inventario_proyectos"
    ADD CONSTRAINT "inventario_proyectos_proyecto_id_fkey" FOREIGN KEY ("proyecto_id") REFERENCES "public"."usa_proyectos"("id");



ALTER TABLE ONLY "public"."lider_programacion_usa_reports"
    ADD CONSTRAINT "lider_programacion_usa_reports_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."usa_clientes"("id");



ALTER TABLE ONLY "public"."log_geocercas"
    ADD CONSTRAINT "log_geocercas_shipment_id_fkey" FOREIGN KEY ("shipment_id") REFERENCES "public"."usa_shipment_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."proyecciones_estrategicas"
    ADD CONSTRAINT "proyecciones_estrategicas_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."usa_clientes"("id");



ALTER TABLE ONLY "public"."proyecciones_estrategicas"
    ADD CONSTRAINT "proyecciones_estrategicas_lider_proyecto_id_fkey" FOREIGN KEY ("lider_proyecto_id") REFERENCES "public"."usa_responsables"("id");



ALTER TABLE ONLY "public"."proyecciones_estrategicas"
    ADD CONSTRAINT "proyecciones_estrategicas_linea_transportista_id_fkey" FOREIGN KEY ("linea_transportista_id") REFERENCES "public"."usa_lineas_transporte"("id");



ALTER TABLE ONLY "public"."proyecciones_estrategicas"
    ADD CONSTRAINT "proyecciones_estrategicas_proyecto_id_fkey" FOREIGN KEY ("proyecto_id") REFERENCES "public"."usa_proyectos"("id");



ALTER TABLE ONLY "public"."proyecciones_estrategicas"
    ADD CONSTRAINT "proyecciones_estrategicas_unidad_transporte_id_fkey" FOREIGN KEY ("unidad_transporte_id") REFERENCES "public"."usa_unidades_transporte"("id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_lote_vinculado_id_fkey" FOREIGN KEY ("lote_vinculado_id") REFERENCES "public"."lider_programacion_usa_reports"("id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_proyecto_destino_id_fkey" FOREIGN KEY ("proyecto_destino_id") REFERENCES "public"."usa_proyectos"("id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_proyecto_origen_id_fkey" FOREIGN KEY ("proyecto_origen_id") REFERENCES "public"."usa_proyectos"("id");



ALTER TABLE ONLY "public"."usa_embarques_detalle"
    ADD CONSTRAINT "usa_embarques_detalle_embarque_id_fkey" FOREIGN KEY ("embarque_id") REFERENCES "public"."usa_embarques"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_embarques_detalle"
    ADD CONSTRAINT "usa_embarques_detalle_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."usa_productos"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_huertas_producto"
    ADD CONSTRAINT "usa_huertas_producto_huerta_id_fkey" FOREIGN KEY ("huerta_id") REFERENCES "public"."usa_huertas"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_huertas_producto"
    ADD CONSTRAINT "usa_huertas_producto_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."usa_productos"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_huertas"
    ADD CONSTRAINT "usa_huertas_productor_id_fkey" FOREIGN KEY ("productor_id") REFERENCES "public"."usa_productores"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_inspecciones"
    ADD CONSTRAINT "usa_inspecciones_huerta_id_fkey" FOREIGN KEY ("huerta_id") REFERENCES "public"."usa_huertas"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_inspecciones_ia_logs"
    ADD CONSTRAINT "usa_inspecciones_ia_logs_inspeccion_id_fkey" FOREIGN KEY ("inspeccion_id") REFERENCES "public"."usa_inspecciones"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_inspecciones"
    ADD CONSTRAINT "usa_inspecciones_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."usa_productos"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_inspecciones"
    ADD CONSTRAINT "usa_inspecciones_productor_id_fkey" FOREIGN KEY ("productor_id") REFERENCES "public"."usa_productores"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_proyecto_producto"
    ADD CONSTRAINT "usa_proyecto_producto_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."usa_productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_proyecto_producto"
    ADD CONSTRAINT "usa_proyecto_producto_proyecto_id_fkey" FOREIGN KEY ("proyecto_id") REFERENCES "public"."usa_proyectos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_shipment_alerts"
    ADD CONSTRAINT "usa_shipment_alerts_shipment_id_fkey" FOREIGN KEY ("shipment_id") REFERENCES "public"."usa_shipment_reports"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."usa_clientes"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_linea_transportista_id_fkey" FOREIGN KEY ("linea_transportista_id") REFERENCES "public"."usa_lineas_transporte"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_lote_original_id_fkey" FOREIGN KEY ("lote_original_id") REFERENCES "public"."lider_programacion_usa_reports"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_lote_secundario_id_fkey" FOREIGN KEY ("lote_secundario_id") REFERENCES "public"."lider_programacion_usa_reports"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_responsible_id_fkey" FOREIGN KEY ("responsible_id") REFERENCES "public"."usa_responsables"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_stop_over_project_id_fkey" FOREIGN KEY ("stop_over_project_id") REFERENCES "public"."usa_proyectos"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."usa_sucursales"("id");



ALTER TABLE ONLY "public"."usa_shipment_reports"
    ADD CONSTRAINT "usa_shipment_reports_unidad_transporte_id_fkey" FOREIGN KEY ("unidad_transporte_id") REFERENCES "public"."usa_unidades_transporte"("id");



ALTER TABLE ONLY "public"."usa_sucursales"
    ADD CONSTRAINT "usa_sucursales_proyecto_id_fkey" FOREIGN KEY ("proyecto_id") REFERENCES "public"."usa_proyectos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_unidades_transporte"
    ADD CONSTRAINT "usa_unidades_transporte_linea_id_fkey" FOREIGN KEY ("linea_id") REFERENCES "public"."usa_lineas_transporte"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usa_unidades_transporte"
    ADD CONSTRAINT "usa_unidades_transporte_tipo_unidad_id_fkey" FOREIGN KEY ("tipo_unidad_id") REFERENCES "public"."tipo_unidad"("id");



CREATE POLICY "Acceso a eventos tive" ON "public"."tive_events" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso publico para pruebas tive" ON "public"."tive_events" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a clientes" ON "public"."usa_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a escalas" ON "public"."usa_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a estatus" ON "public"."usa_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a programacion" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a proyecciones" ON "public"."proyecciones_estrategicas" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a proyectos" ON "public"."usa_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total a tipo_unidad" ON "public"."tipo_unidad" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total para gestión logística" ON "public"."tive_alert_config" USING (true);



CREATE POLICY "Acceso total para registro" ON "public"."push_subscriptions" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso total para usuarios autenticados" ON "public"."alert_recipients" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Acceso_Seguro_Responsables" ON "public"."usa_responsables" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Actualización para usuarios autenticados" ON "public"."usa_productos" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Admins gestionan anuncios" ON "public"."advertisements" USING (true);



CREATE POLICY "Allow auth users to manage nacional statuses" ON "public"."nacional_logistic_statuses" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated read access to location history" ON "public"."location_history" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read access to temperature history" ON "public"."temperature_history" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read and insert" ON "public"."trackers" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Allow authenticated users to manage nacional reports" ON "public"."nacional_shipment_reports" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated users to perform all actions" ON "public"."industria_shipment_reports" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow authenticated users to perform all actions" ON "public"."nacional_shipment_reports" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Allow individual user access to their own profile" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Allow individual user to update their own profile" ON "public"."profiles" FOR UPDATE USING (("auth"."uid"() = "id"));



CREATE POLICY "Allow public read access to nacional statuses" ON "public"."nacional_logistic_statuses" FOR SELECT USING (true);



CREATE POLICY "Allow service_role to insert" ON "public"."location_history" FOR INSERT WITH CHECK (true);



CREATE POLICY "Allow service_role to insert" ON "public"."temperature_history" FOR INSERT WITH CHECK (true);



CREATE POLICY "Anuncios visibles por todos" ON "public"."advertisements" FOR SELECT USING (true);



CREATE POLICY "Authenticated insert access" ON "public"."tive_events" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable all actions for all users" ON "public"."industria_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all actions for all users" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all actions for all users" ON "public"."nacional_logistic_statuses" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all actions for all users" ON "public"."nacional_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all actions for all users" ON "public"."ventas_domesticas_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."usa_fotos_inspeccion" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."usa_inspecciones" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable insert for authenticated users only" ON "public"."usa_inspecciones_ia_logs" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."industria_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."industria_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."industria_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."industria_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."industria_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."industria_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."nacional_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."nacionales_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."nacionales_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."nacionales_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."nacionales_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."nacionales_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."tipo_unidad" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."usa_brockers" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."usa_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."usa_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."usa_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."usa_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Enable public access" ON "public"."ventas_domesticas_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Enable read access for all users" ON "public"."tive_events" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."usa_catalogo_danos" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."usa_huertas" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."usa_productores" FOR SELECT USING (true);



CREATE POLICY "Enable read access for all users" ON "public"."usa_productos" FOR SELECT USING (true);



CREATE POLICY "Enable read access for authenticated users" ON "public"."location_history" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Enable read access for authenticated users" ON "public"."temperature_history" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Escritura universal lider_programacion_usa_reports" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal tipo_unidad" ON "public"."tipo_unidad" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal tive_alert_config" ON "public"."tive_alert_config" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_brockers" ON "public"."usa_brockers" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_clientes" ON "public"."usa_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_escalas" ON "public"."usa_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_estatus" ON "public"."usa_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_lineas_transporte" ON "public"."usa_lineas_transporte" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_productos" ON "public"."usa_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_proyecto_producto" ON "public"."usa_proyecto_producto" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_proyectos" ON "public"."usa_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_shipment_alerts" ON "public"."usa_shipment_alerts" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_sucursales" ON "public"."usa_sucursales" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_unidades_transporte" ON "public"."usa_unidades_transporte" USING (true) WITH CHECK (true);



CREATE POLICY "Escritura universal usa_usuarios" ON "public"."usa_usuarios" USING (true) WITH CHECK (true);



CREATE POLICY "Gestión de inventario para autenticados" ON "public"."inventario_proyectos" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Inserción para usuarios autenticados" ON "public"."usa_productos" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Lectura para usuarios autenticados" ON "public"."usa_productos" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Lectura pública de usuarios" ON "public"."usa_usuarios" FOR SELECT USING (true);



CREATE POLICY "Lectura universal lider_programacion_usa_reports" ON "public"."lider_programacion_usa_reports" FOR SELECT USING (true);



CREATE POLICY "Lectura universal tipo_unidad" ON "public"."tipo_unidad" FOR SELECT USING (true);



CREATE POLICY "Lectura universal tive_alert_config" ON "public"."tive_alert_config" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_brockers" ON "public"."usa_brockers" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_clientes" ON "public"."usa_clientes" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_escalas" ON "public"."usa_escalas" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_estatus" ON "public"."usa_estatus" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_lineas_transporte" ON "public"."usa_lineas_transporte" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_productos" ON "public"."usa_productos" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_proyecto_producto" ON "public"."usa_proyecto_producto" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_proyectos" ON "public"."usa_proyectos" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_shipment_alerts" ON "public"."usa_shipment_alerts" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_sucursales" ON "public"."usa_sucursales" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_unidades_transporte" ON "public"."usa_unidades_transporte" FOR SELECT USING (true);



CREATE POLICY "Lectura universal usa_usuarios" ON "public"."usa_usuarios" FOR SELECT USING (true);



CREATE POLICY "P_Total_Escritura_Lectura" ON "public"."usa_shipment_reports" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."nacionales_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."nacionales_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."nacionales_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."nacionales_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."nacionales_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."tive_alert_config" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_brockers" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_lineas_transporte" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_proyecto_producto" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_sucursales" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir Todo" ON "public"."usa_unidades_transporte" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir a todos insertar sus propios tokens" ON "public"."push_subscriptions" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir actualización pública" ON "public"."usa_productos" FOR UPDATE USING (true) WITH CHECK (true);



CREATE POLICY "Permitir borrado público" ON "public"."usa_productos" FOR DELETE USING (true);



CREATE POLICY "Permitir inserción a autenticados" ON "public"."usa_proyecto_producto" USING (true);



CREATE POLICY "Permitir inserción pública" ON "public"."usa_productos" FOR INSERT WITH CHECK (true);



CREATE POLICY "Permitir inserción webhook" ON "public"."tive_events" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "Permitir lectura a usuarios autenticados" ON "public"."tive_events" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Permitir lectura pública" ON "public"."usa_proyecto_producto" FOR SELECT USING (true);



CREATE POLICY "Permitir registro de dispositivos" ON "public"."push_subscriptions" TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir todo a usuarios anonimos" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir todo a usuarios autenticados" ON "public"."inventario_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir todo a usuarios autenticados" ON "public"."transferencias_stock" USING (true) WITH CHECK (true);



CREATE POLICY "Permitir todo en suscripciones" ON "public"."push_subscriptions" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."advertisements" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."industria_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."industria_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."industria_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."industria_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."industria_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."industria_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."inventario_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."location_history" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."log_geocercas" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacional_logistic_statuses" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacional_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacionales_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacionales_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacionales_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacionales_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."nacionales_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."offline_sync_audit" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."private_messages" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."profiles" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."proyecciones_estrategicas" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."push_subscriptions" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."system_audit_logs" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."system_logs" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."temperature_history" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."tipo_unidad" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."tive_alert_config" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."tive_alert_dictionary" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."tive_events" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."trackers" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."transferencias_stock" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_brockers" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_lineas_transporte" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_proyecto_producto" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_shipment_alerts" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_sucursales" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_unidades_transporte" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."usa_usuarios" USING (true) WITH CHECK (true);



CREATE POLICY "Public All" ON "public"."ventas_domesticas_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public access industria_clientes" ON "public"."industria_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Public access industria_escalas" ON "public"."industria_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Public access industria_estatus" ON "public"."industria_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Public access industria_productos" ON "public"."industria_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Public access industria_proyectos" ON "public"."industria_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public access industria_shipment_reports" ON "public"."industria_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public access lider_programacion_usa_reports" ON "public"."lider_programacion_usa_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public access location_history" ON "public"."location_history" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacional_logistic_statuses" ON "public"."nacional_logistic_statuses" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacional_shipment_reports" ON "public"."nacional_shipment_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacionales_clientes" ON "public"."nacionales_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacionales_escalas" ON "public"."nacionales_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacionales_estatus" ON "public"."nacionales_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacionales_productos" ON "public"."nacionales_productos" USING (true) WITH CHECK (true);



CREATE POLICY "Public access nacionales_proyectos" ON "public"."nacionales_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public access profiles" ON "public"."profiles" USING (true) WITH CHECK (true);



CREATE POLICY "Public access temperature_history" ON "public"."temperature_history" USING (true) WITH CHECK (true);



CREATE POLICY "Public access tipo_unidad" ON "public"."tipo_unidad" USING (true) WITH CHECK (true);



CREATE POLICY "Public access tive_events" ON "public"."tive_events" USING (true) WITH CHECK (true);



CREATE POLICY "Public access trackers" ON "public"."trackers" USING (true) WITH CHECK (true);



CREATE POLICY "Public access usa_brockers" ON "public"."usa_brockers" USING (true) WITH CHECK (true);



CREATE POLICY "Public access usa_clientes" ON "public"."usa_clientes" USING (true) WITH CHECK (true);



CREATE POLICY "Public access usa_escalas" ON "public"."usa_escalas" USING (true) WITH CHECK (true);



CREATE POLICY "Public access usa_estatus" ON "public"."usa_estatus" USING (true) WITH CHECK (true);



CREATE POLICY "Public access usa_proyectos" ON "public"."usa_proyectos" USING (true) WITH CHECK (true);



CREATE POLICY "Public access ventas_domesticas_reports" ON "public"."ventas_domesticas_reports" USING (true) WITH CHECK (true);



CREATE POLICY "Public insert clients" ON "public"."usa_clientes" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Public read" ON "public"."usa_proyectos" FOR SELECT USING (true);



CREATE POLICY "Public read access" ON "public"."tive_events" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Public read clients" ON "public"."usa_clientes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Public read permission" ON "public"."tive_events" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "Role-based delete" ON "public"."usa_proyectos" FOR DELETE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['Administrativo'::"text", 'Coordinador 1'::"text", 'Coordinador 2'::"text"])));



CREATE POLICY "Role-based insert" ON "public"."usa_proyectos" FOR INSERT TO "authenticated" WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['Administrativo'::"text", 'Coordinador 1'::"text", 'Coordinador 2'::"text"])));



CREATE POLICY "Role-based update" ON "public"."usa_proyectos" FOR UPDATE TO "authenticated" USING ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['Administrativo'::"text", 'Coordinador 1'::"text", 'Coordinador 2'::"text"]))) WITH CHECK ((("auth"."jwt"() ->> 'user_role'::"text") = ANY (ARRAY['Administrativo'::"text", 'Coordinador 1'::"text", 'Coordinador 2'::"text"])));



CREATE POLICY "Select Proyectos Público" ON "public"."usa_proyectos" FOR SELECT USING (true);



CREATE POLICY "Solo personal autorizado puede leer proyecciones" ON "public"."proyecciones_estrategicas" FOR SELECT TO "authenticated" USING (("auth"."email"() IN ( SELECT "usa_responsables"."correo"
   FROM "public"."usa_responsables")));



CREATE POLICY "Users can see their own conversations" ON "public"."private_messages" FOR SELECT USING (((("auth"."uid"())::"text" = "from_user") OR (("auth"."uid"())::"text" = "to_user") OR ("to_user" = 'COORDINADOR'::"text")));



CREATE POLICY "Users can view their own profile" ON "public"."profiles" FOR SELECT USING (("auth"."uid"() = "id"));



CREATE POLICY "Webhook insert permission" ON "public"."tive_events" FOR INSERT TO "service_role" WITH CHECK (true);



ALTER TABLE "public"."advertisements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alert_recipients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alert_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "anon_can_read_usa_shipment_reports" ON "public"."usa_shipment_reports" FOR SELECT TO "anon" USING (true);



ALTER TABLE "public"."industria_clientes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."industria_escalas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."industria_estatus" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."industria_productos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."industria_proyectos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."industria_shipment_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inventario_proyectos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "inventario_proyectos authenticated delete" ON "public"."inventario_proyectos" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "inventario_proyectos authenticated insert" ON "public"."inventario_proyectos" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "inventario_proyectos authenticated read" ON "public"."inventario_proyectos" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "inventario_proyectos authenticated update" ON "public"."inventario_proyectos" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."lider_programacion_usa_reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "lider_programacion_usa_reports authenticated delete" ON "public"."lider_programacion_usa_reports" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "lider_programacion_usa_reports authenticated insert" ON "public"."lider_programacion_usa_reports" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "lider_programacion_usa_reports authenticated read" ON "public"."lider_programacion_usa_reports" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "lider_programacion_usa_reports authenticated update" ON "public"."lider_programacion_usa_reports" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."location_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."log_geocercas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacional_logistic_statuses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacional_shipment_reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacionales_clientes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacionales_escalas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacionales_estatus" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacionales_productos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."nacionales_proyectos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."offline_sync_audit" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."private_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."proyecciones_estrategicas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "proyecciones_estrategicas authenticated delete" ON "public"."proyecciones_estrategicas" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "proyecciones_estrategicas authenticated insert" ON "public"."proyecciones_estrategicas" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "proyecciones_estrategicas authenticated read" ON "public"."proyecciones_estrategicas" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "proyecciones_estrategicas authenticated update" ON "public"."proyecciones_estrategicas" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."push_subscriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "push_subscriptions authenticated delete" ON "public"."push_subscriptions" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "push_subscriptions authenticated insert" ON "public"."push_subscriptions" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "push_subscriptions authenticated read" ON "public"."push_subscriptions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "push_subscriptions authenticated update" ON "public"."push_subscriptions" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."system_audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."system_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."temperature_history" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."tipo_unidad" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tipo_unidad authenticated delete" ON "public"."tipo_unidad" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "tipo_unidad authenticated insert" ON "public"."tipo_unidad" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "tipo_unidad authenticated read" ON "public"."tipo_unidad" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "tipo_unidad authenticated update" ON "public"."tipo_unidad" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."tive_alert_config" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tive_alert_config authenticated delete" ON "public"."tive_alert_config" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "tive_alert_config authenticated insert" ON "public"."tive_alert_config" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "tive_alert_config authenticated read" ON "public"."tive_alert_config" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "tive_alert_config authenticated update" ON "public"."tive_alert_config" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."tive_alert_dictionary" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tive_alert_dictionary authenticated delete" ON "public"."tive_alert_dictionary" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "tive_alert_dictionary authenticated insert" ON "public"."tive_alert_dictionary" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "tive_alert_dictionary authenticated read" ON "public"."tive_alert_dictionary" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "tive_alert_dictionary authenticated update" ON "public"."tive_alert_dictionary" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."tive_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tive_events authenticated delete" ON "public"."tive_events" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "tive_events authenticated insert" ON "public"."tive_events" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "tive_events authenticated read" ON "public"."tive_events" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "tive_events authenticated update" ON "public"."tive_events" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."trackers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transferencias_stock" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transferencias_stock authenticated delete" ON "public"."transferencias_stock" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "transferencias_stock authenticated insert" ON "public"."transferencias_stock" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "transferencias_stock authenticated read" ON "public"."transferencias_stock" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "transferencias_stock authenticated update" ON "public"."transferencias_stock" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_brockers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_catalogo_danos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_clientes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_clientes authenticated delete" ON "public"."usa_clientes" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_clientes authenticated insert" ON "public"."usa_clientes" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_clientes authenticated read" ON "public"."usa_clientes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_clientes authenticated update" ON "public"."usa_clientes" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_embarques" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_embarques_detalle" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_escalas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_estatus" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_estatus authenticated delete" ON "public"."usa_estatus" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_estatus authenticated insert" ON "public"."usa_estatus" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_estatus authenticated read" ON "public"."usa_estatus" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_estatus authenticated update" ON "public"."usa_estatus" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_fotos_inspeccion" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_huertas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_huertas_producto" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_inspecciones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_inspecciones_ia_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_lineas_transporte" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_lineas_transporte authenticated delete" ON "public"."usa_lineas_transporte" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_lineas_transporte authenticated insert" ON "public"."usa_lineas_transporte" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_lineas_transporte authenticated read" ON "public"."usa_lineas_transporte" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_lineas_transporte authenticated update" ON "public"."usa_lineas_transporte" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_productores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_productos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_productos authenticated delete" ON "public"."usa_productos" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_productos authenticated insert" ON "public"."usa_productos" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_productos authenticated read" ON "public"."usa_productos" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_productos authenticated update" ON "public"."usa_productos" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_proyecto_producto" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_proyecto_producto authenticated delete" ON "public"."usa_proyecto_producto" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_proyecto_producto authenticated insert" ON "public"."usa_proyecto_producto" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_proyecto_producto authenticated read" ON "public"."usa_proyecto_producto" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_proyecto_producto authenticated update" ON "public"."usa_proyecto_producto" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_proyectos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_proyectos authenticated delete" ON "public"."usa_proyectos" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_proyectos authenticated insert" ON "public"."usa_proyectos" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_proyectos authenticated read" ON "public"."usa_proyectos" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_proyectos authenticated update" ON "public"."usa_proyectos" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_responsables" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_responsables authenticated delete" ON "public"."usa_responsables" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_responsables authenticated insert" ON "public"."usa_responsables" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_responsables authenticated read" ON "public"."usa_responsables" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_responsables authenticated update" ON "public"."usa_responsables" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_servicios_aduanales" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_servicios_complementarios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usa_shipment_alerts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_shipment_alerts authenticated delete" ON "public"."usa_shipment_alerts" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_shipment_alerts authenticated insert" ON "public"."usa_shipment_alerts" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_shipment_alerts authenticated read" ON "public"."usa_shipment_alerts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_shipment_alerts authenticated update" ON "public"."usa_shipment_alerts" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_shipment_reports" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_shipment_reports authenticated delete" ON "public"."usa_shipment_reports" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_shipment_reports authenticated insert" ON "public"."usa_shipment_reports" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_shipment_reports authenticated read" ON "public"."usa_shipment_reports" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_shipment_reports authenticated update" ON "public"."usa_shipment_reports" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_sucursales" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_sucursales authenticated delete" ON "public"."usa_sucursales" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_sucursales authenticated insert" ON "public"."usa_sucursales" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_sucursales authenticated read" ON "public"."usa_sucursales" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_sucursales authenticated update" ON "public"."usa_sucursales" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_unidades_transporte" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usa_unidades_transporte authenticated delete" ON "public"."usa_unidades_transporte" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "usa_unidades_transporte authenticated insert" ON "public"."usa_unidades_transporte" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "usa_unidades_transporte authenticated read" ON "public"."usa_unidades_transporte" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "usa_unidades_transporte authenticated update" ON "public"."usa_unidades_transporte" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."usa_usuarios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ventas_domesticas_reports" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."inventario_proyectos";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."location_history";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."proyecciones_estrategicas";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."temperature_history";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."tive_events";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."transferencias_stock";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."usa_shipment_alerts";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";















































































































































































































GRANT ALL ON FUNCTION "public"."append_to_location_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."append_to_location_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."append_to_location_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."append_to_temperature_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb", "new_current_temp" numeric, "new_temp_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."append_to_temperature_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb", "new_current_temp" numeric, "new_temp_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."append_to_temperature_history"("table_name" "text", "report_id_to_update" "uuid", "new_entry" "jsonb", "new_current_temp" numeric, "new_temp_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_user_allowed"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_user_allowed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_user_allowed"() TO "service_role";



GRANT ALL ON FUNCTION "public"."claim_mining_rewards"("user_id_input" "uuid", "claim_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."claim_mining_rewards"("user_id_input" "uuid", "claim_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."claim_mining_rewards"("user_id_input" "uuid", "claim_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_tables"("table_names" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."delete_tables"("table_names" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_tables"("table_names" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_dispatch_alert_push"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_dispatch_alert_push"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_dispatch_alert_push"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_dispatch_push_notification"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_dispatch_push_notification"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_dispatch_push_notification"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_coordination_audit_data"("p_project_id" "uuid", "p_product_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_coordination_audit_data"("p_project_id" "uuid", "p_product_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_coordination_audit_data"("p_project_id" "uuid", "p_product_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_product_goal_health"("p_project_id" "uuid", "p_semana_fiscal" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_product_goal_health"("p_project_id" "uuid", "p_semana_fiscal" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_product_goal_health"("p_project_id" "uuid", "p_semana_fiscal" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_remaining_authorized_boxes"("p_project_id" "uuid", "p_week" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_remaining_authorized_boxes"("p_project_id" "uuid", "p_week" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_remaining_authorized_boxes"("p_project_id" "uuid", "p_week" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_auri_balance"("user_id_input" "uuid", "amount_input" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."increment_auri_balance"("user_id_input" "uuid", "amount_input" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_auri_balance"("user_id_input" "uuid", "amount_input" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."purge_default_auri_users"() TO "anon";
GRANT ALL ON FUNCTION "public"."purge_default_auri_users"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."purge_default_auri_users"() TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_inventory_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_inventory_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_inventory_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";






























GRANT ALL ON TABLE "public"."advertisements" TO "anon";
GRANT ALL ON TABLE "public"."advertisements" TO "authenticated";
GRANT ALL ON TABLE "public"."advertisements" TO "service_role";



GRANT ALL ON TABLE "public"."alert_recipients" TO "anon";
GRANT ALL ON TABLE "public"."alert_recipients" TO "authenticated";
GRANT ALL ON TABLE "public"."alert_recipients" TO "service_role";



GRANT ALL ON SEQUENCE "public"."alert_recipients_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."alert_recipients_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."alert_recipients_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."alert_settings" TO "anon";
GRANT ALL ON TABLE "public"."alert_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."alert_settings" TO "service_role";



GRANT ALL ON TABLE "public"."industria_clientes" TO "anon";
GRANT ALL ON TABLE "public"."industria_clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."industria_clientes" TO "service_role";



GRANT ALL ON TABLE "public"."industria_escalas" TO "anon";
GRANT ALL ON TABLE "public"."industria_escalas" TO "authenticated";
GRANT ALL ON TABLE "public"."industria_escalas" TO "service_role";



GRANT ALL ON TABLE "public"."industria_estatus" TO "anon";
GRANT ALL ON TABLE "public"."industria_estatus" TO "authenticated";
GRANT ALL ON TABLE "public"."industria_estatus" TO "service_role";



GRANT ALL ON TABLE "public"."industria_productos" TO "anon";
GRANT ALL ON TABLE "public"."industria_productos" TO "authenticated";
GRANT ALL ON TABLE "public"."industria_productos" TO "service_role";



GRANT ALL ON TABLE "public"."industria_proyectos" TO "anon";
GRANT ALL ON TABLE "public"."industria_proyectos" TO "authenticated";
GRANT ALL ON TABLE "public"."industria_proyectos" TO "service_role";



GRANT ALL ON TABLE "public"."industria_shipment_reports" TO "anon";
GRANT ALL ON TABLE "public"."industria_shipment_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."industria_shipment_reports" TO "service_role";



GRANT ALL ON TABLE "public"."inventario_proyectos" TO "anon";
GRANT ALL ON TABLE "public"."inventario_proyectos" TO "authenticated";
GRANT ALL ON TABLE "public"."inventario_proyectos" TO "service_role";



GRANT ALL ON TABLE "public"."lider_programacion_usa_reports" TO "anon";
GRANT ALL ON TABLE "public"."lider_programacion_usa_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."lider_programacion_usa_reports" TO "service_role";



GRANT ALL ON TABLE "public"."location_history" TO "anon";
GRANT ALL ON TABLE "public"."location_history" TO "authenticated";
GRANT ALL ON TABLE "public"."location_history" TO "service_role";



GRANT ALL ON SEQUENCE "public"."location_history_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."location_history_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."location_history_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."log_geocercas" TO "anon";
GRANT ALL ON TABLE "public"."log_geocercas" TO "authenticated";
GRANT ALL ON TABLE "public"."log_geocercas" TO "service_role";



GRANT ALL ON TABLE "public"."nacional_logistic_statuses" TO "anon";
GRANT ALL ON TABLE "public"."nacional_logistic_statuses" TO "authenticated";
GRANT ALL ON TABLE "public"."nacional_logistic_statuses" TO "service_role";



GRANT ALL ON TABLE "public"."nacional_shipment_reports" TO "anon";
GRANT ALL ON TABLE "public"."nacional_shipment_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."nacional_shipment_reports" TO "service_role";



GRANT ALL ON TABLE "public"."nacionales_clientes" TO "anon";
GRANT ALL ON TABLE "public"."nacionales_clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."nacionales_clientes" TO "service_role";



GRANT ALL ON TABLE "public"."nacionales_escalas" TO "anon";
GRANT ALL ON TABLE "public"."nacionales_escalas" TO "authenticated";
GRANT ALL ON TABLE "public"."nacionales_escalas" TO "service_role";



GRANT ALL ON TABLE "public"."nacionales_estatus" TO "anon";
GRANT ALL ON TABLE "public"."nacionales_estatus" TO "authenticated";
GRANT ALL ON TABLE "public"."nacionales_estatus" TO "service_role";



GRANT ALL ON TABLE "public"."nacionales_productos" TO "anon";
GRANT ALL ON TABLE "public"."nacionales_productos" TO "authenticated";
GRANT ALL ON TABLE "public"."nacionales_productos" TO "service_role";



GRANT ALL ON TABLE "public"."nacionales_proyectos" TO "anon";
GRANT ALL ON TABLE "public"."nacionales_proyectos" TO "authenticated";
GRANT ALL ON TABLE "public"."nacionales_proyectos" TO "service_role";



GRANT ALL ON TABLE "public"."offline_sync_audit" TO "anon";
GRANT ALL ON TABLE "public"."offline_sync_audit" TO "authenticated";
GRANT ALL ON TABLE "public"."offline_sync_audit" TO "service_role";



GRANT ALL ON TABLE "public"."private_messages" TO "anon";
GRANT ALL ON TABLE "public"."private_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."private_messages" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."proyecciones_estrategicas" TO "anon";
GRANT ALL ON TABLE "public"."proyecciones_estrategicas" TO "authenticated";
GRANT ALL ON TABLE "public"."proyecciones_estrategicas" TO "service_role";



GRANT ALL ON TABLE "public"."push_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."usa_productos" TO "anon";
GRANT ALL ON TABLE "public"."usa_productos" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_productos" TO "service_role";



GRANT ALL ON TABLE "public"."usa_proyectos" TO "anon";
GRANT ALL ON TABLE "public"."usa_proyectos" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_proyectos" TO "service_role";



GRANT ALL ON TABLE "public"."reporte_cumplimiento_seguimiento" TO "anon";
GRANT ALL ON TABLE "public"."reporte_cumplimiento_seguimiento" TO "authenticated";
GRANT ALL ON TABLE "public"."reporte_cumplimiento_seguimiento" TO "service_role";



GRANT ALL ON TABLE "public"."system_audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."system_audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."system_audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."system_logs" TO "anon";
GRANT ALL ON TABLE "public"."system_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."system_logs" TO "service_role";



GRANT ALL ON TABLE "public"."temperature_history" TO "anon";
GRANT ALL ON TABLE "public"."temperature_history" TO "authenticated";
GRANT ALL ON TABLE "public"."temperature_history" TO "service_role";



GRANT ALL ON SEQUENCE "public"."temperature_history_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."temperature_history_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."temperature_history_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tipo_unidad" TO "anon";
GRANT ALL ON TABLE "public"."tipo_unidad" TO "authenticated";
GRANT ALL ON TABLE "public"."tipo_unidad" TO "service_role";



GRANT ALL ON SEQUENCE "public"."tipo_unidad_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."tipo_unidad_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."tipo_unidad_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."tive_alert_config" TO "anon";
GRANT ALL ON TABLE "public"."tive_alert_config" TO "authenticated";
GRANT ALL ON TABLE "public"."tive_alert_config" TO "service_role";



GRANT ALL ON TABLE "public"."tive_alert_dictionary" TO "anon";
GRANT ALL ON TABLE "public"."tive_alert_dictionary" TO "authenticated";
GRANT ALL ON TABLE "public"."tive_alert_dictionary" TO "service_role";



GRANT ALL ON TABLE "public"."tive_events" TO "anon";
GRANT ALL ON TABLE "public"."tive_events" TO "authenticated";
GRANT ALL ON TABLE "public"."tive_events" TO "service_role";



GRANT ALL ON TABLE "public"."trackers" TO "anon";
GRANT ALL ON TABLE "public"."trackers" TO "authenticated";
GRANT ALL ON TABLE "public"."trackers" TO "service_role";



GRANT ALL ON TABLE "public"."transferencias_stock" TO "anon";
GRANT ALL ON TABLE "public"."transferencias_stock" TO "authenticated";
GRANT ALL ON TABLE "public"."transferencias_stock" TO "service_role";



GRANT ALL ON TABLE "public"."usa_brockers" TO "anon";
GRANT ALL ON TABLE "public"."usa_brockers" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_brockers" TO "service_role";



GRANT ALL ON TABLE "public"."usa_catalogo_danos" TO "anon";
GRANT ALL ON TABLE "public"."usa_catalogo_danos" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_catalogo_danos" TO "service_role";



GRANT ALL ON TABLE "public"."usa_clientes" TO "anon";
GRANT ALL ON TABLE "public"."usa_clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_clientes" TO "service_role";



GRANT ALL ON TABLE "public"."usa_embarques" TO "anon";
GRANT ALL ON TABLE "public"."usa_embarques" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_embarques" TO "service_role";



GRANT ALL ON TABLE "public"."usa_embarques_detalle" TO "anon";
GRANT ALL ON TABLE "public"."usa_embarques_detalle" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_embarques_detalle" TO "service_role";



GRANT ALL ON TABLE "public"."usa_escalas" TO "anon";
GRANT ALL ON TABLE "public"."usa_escalas" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_escalas" TO "service_role";



GRANT ALL ON TABLE "public"."usa_estatus" TO "anon";
GRANT ALL ON TABLE "public"."usa_estatus" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_estatus" TO "service_role";



GRANT ALL ON TABLE "public"."usa_fotos_inspeccion" TO "anon";
GRANT ALL ON TABLE "public"."usa_fotos_inspeccion" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_fotos_inspeccion" TO "service_role";



GRANT ALL ON TABLE "public"."usa_huertas" TO "anon";
GRANT ALL ON TABLE "public"."usa_huertas" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_huertas" TO "service_role";



GRANT ALL ON TABLE "public"."usa_huertas_producto" TO "anon";
GRANT ALL ON TABLE "public"."usa_huertas_producto" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_huertas_producto" TO "service_role";



GRANT ALL ON TABLE "public"."usa_inspecciones" TO "anon";
GRANT ALL ON TABLE "public"."usa_inspecciones" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_inspecciones" TO "service_role";



GRANT ALL ON TABLE "public"."usa_inspecciones_ia_logs" TO "anon";
GRANT ALL ON TABLE "public"."usa_inspecciones_ia_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_inspecciones_ia_logs" TO "service_role";



GRANT ALL ON TABLE "public"."usa_lineas_transporte" TO "anon";
GRANT ALL ON TABLE "public"."usa_lineas_transporte" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_lineas_transporte" TO "service_role";



GRANT ALL ON TABLE "public"."usa_productores" TO "anon";
GRANT ALL ON TABLE "public"."usa_productores" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_productores" TO "service_role";



GRANT ALL ON TABLE "public"."usa_proyecto_producto" TO "anon";
GRANT ALL ON TABLE "public"."usa_proyecto_producto" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_proyecto_producto" TO "service_role";



GRANT ALL ON TABLE "public"."usa_responsables" TO "anon";
GRANT ALL ON TABLE "public"."usa_responsables" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_responsables" TO "service_role";



GRANT ALL ON TABLE "public"."usa_servicios_aduanales" TO "anon";
GRANT ALL ON TABLE "public"."usa_servicios_aduanales" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_servicios_aduanales" TO "service_role";



GRANT ALL ON TABLE "public"."usa_servicios_complementarios" TO "anon";
GRANT ALL ON TABLE "public"."usa_servicios_complementarios" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_servicios_complementarios" TO "service_role";



GRANT ALL ON TABLE "public"."usa_shipment_alerts" TO "anon";
GRANT ALL ON TABLE "public"."usa_shipment_alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_shipment_alerts" TO "service_role";



GRANT ALL ON TABLE "public"."usa_shipment_reports" TO "anon";
GRANT ALL ON TABLE "public"."usa_shipment_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_shipment_reports" TO "service_role";



GRANT ALL ON TABLE "public"."usa_sucursales" TO "anon";
GRANT ALL ON TABLE "public"."usa_sucursales" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_sucursales" TO "service_role";



GRANT ALL ON TABLE "public"."usa_unidades_transporte" TO "anon";
GRANT ALL ON TABLE "public"."usa_unidades_transporte" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_unidades_transporte" TO "service_role";



GRANT ALL ON TABLE "public"."usa_usuarios" TO "anon";
GRANT ALL ON TABLE "public"."usa_usuarios" TO "authenticated";
GRANT ALL ON TABLE "public"."usa_usuarios" TO "service_role";



GRANT ALL ON TABLE "public"."ventas_domesticas_reports" TO "anon";
GRANT ALL ON TABLE "public"."ventas_domesticas_reports" TO "authenticated";
GRANT ALL ON TABLE "public"."ventas_domesticas_reports" TO "service_role";



GRANT ALL ON TABLE "public"."vista_cumplimiento_ejecutivo" TO "anon";
GRANT ALL ON TABLE "public"."vista_cumplimiento_ejecutivo" TO "authenticated";
GRANT ALL ON TABLE "public"."vista_cumplimiento_ejecutivo" TO "service_role";



GRANT ALL ON TABLE "public"."vista_eficiencia_transito" TO "anon";
GRANT ALL ON TABLE "public"."vista_eficiencia_transito" TO "authenticated";
GRANT ALL ON TABLE "public"."vista_eficiencia_transito" TO "service_role";



GRANT ALL ON TABLE "public"."vista_logs_geocerca" TO "anon";
GRANT ALL ON TABLE "public"."vista_logs_geocerca" TO "authenticated";
GRANT ALL ON TABLE "public"."vista_logs_geocerca" TO "service_role";



GRANT ALL ON TABLE "public"."vista_metas_agotadas" TO "anon";
GRANT ALL ON TABLE "public"."vista_metas_agotadas" TO "authenticated";
GRANT ALL ON TABLE "public"."vista_metas_agotadas" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































