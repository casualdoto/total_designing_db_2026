-- Сравнение исходной и восстановленной схемы без владельцев, ACL и служебных OID.
-- psql -X -At -v ON_ERROR_STOP=1 -f db/schema_inventory.sql
SET search_path = pg_catalog;
SELECT jsonb_build_object(
    'enum_types',(SELECT jsonb_agg(jsonb_build_object('name',t.typname,'labels',
        (SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid=t.oid)) ORDER BY t.typname)
        FROM pg_type t WHERE t.typnamespace='khrestianovskii_food'::regnamespace AND t.typtype='e'),
    'relations',(SELECT jsonb_agg(jsonb_build_object('name',c.relname,'kind',c.relkind,'options',c.reloptions,
        'columns',(SELECT jsonb_agg(jsonb_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),
            'not_null',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid)) ORDER BY a.attnum)
            FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
            WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped),
        'view',CASE WHEN c.relkind='v' THEN pg_get_viewdef(c.oid,true) END) ORDER BY c.relname)
        FROM pg_class c WHERE c.relnamespace='khrestianovskii_food'::regnamespace AND c.relkind IN ('r','v')),
    'constraints',(SELECT jsonb_agg(jsonb_build_object('table',c.conrelid::regclass::text,'name',c.conname,
        'definition',pg_get_constraintdef(c.oid,true),'validated',c.convalidated) ORDER BY c.conrelid::regclass::text,c.conname)
        FROM pg_constraint c WHERE c.connamespace='khrestianovskii_food'::regnamespace),
    'indexes',(SELECT jsonb_agg(pg_get_indexdef(i.indexrelid) ORDER BY c.relname)
        FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE c.relnamespace='khrestianovskii_food'::regnamespace),
    'triggers',(SELECT jsonb_agg(pg_get_triggerdef(t.oid,true) ORDER BY c.relname,t.tgname)
        FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        WHERE c.relnamespace='khrestianovskii_food'::regnamespace AND NOT t.tgisinternal),
    'routines',(SELECT jsonb_agg(pg_get_functiondef(p.oid) ORDER BY p.proname,pg_get_function_identity_arguments(p.oid))
        FROM pg_proc p WHERE p.pronamespace='khrestianovskii_food'::regnamespace)
);
