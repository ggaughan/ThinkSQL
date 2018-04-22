--may fail if constraint names change

SELECT  
PKTABLE_CAT, PKTABLE_SCHEM, PKTABLE_NAME, PKCOLUMN_NAME,  FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, FKCOLUMN_NAME,  column_sequence AS KEY_SEQ,  CASE FK_on_update_action   WHEN 0 THEN 0    WHEN 1 THEN 2    WHEN 2 THEN 3    WHEN 3 THEN 4  END AS UPDATE_RULE,  CASE FK_on_delete_action    WHEN 0 THEN 0    WHEN 1 THEN 2    WHEN 2 THEN 3    WHEN 3 THEN 4  END AS DELETE_RULE,  constraint_name AS FK_NAME,  CASE initially_deferred    WHEN 'Y' THEN 5  ELSE   CASE "deferrable"      WHEN 'Y' THEN 6    ELSE      7    END  END AS DEFERRABILITY 
FROM  

(  SELECT  PC.catalog_name AS PKTABLE_CAT, PS.schema_name AS PKTABLE_SCHEM, PT.table_name AS PKTABLE_NAME, PL.column_name AS PKCOLUMN_NAME,  constraint_id,  column_sequence ,  FK_child_table_id  FROM  

CATALOG_DEFINITION_SCHEMA.sysCatalog PC,  CATALOG_DEFINITION_SCHEMA.sysSchema PS,  CATALOG_DEFINITION_SCHEMA.sysColumn PL,  CATALOG_DEFINITION_SCHEMA.sysTable PT2,  CATALOG_DEFINITION_SCHEMA.sysTable PT,  (CATALOG_DEFINITION_SCHEMA.sysConstraintColumn J natural join  CATALOG_DEFINITION_SCHEMA.sysConstraint )  

WHERE  parent_or_child_table='P'  AND FK_parent_table_id=PT.table_id  AND PT.schema_id=PS.schema_id  AND PS.catalog_id=PC.catalog_id  AND J.column_id=PL.column_id  AND PL.table_id=PT.table_id  AND FK_child_table_id=PT2.table_id  AND PC.catalog_name ='db1'  AND PS.schema_name ='RESTAURANT'  AND PT.table_name LIKE '%'  AND PT2.table_name LIKE 'CHECK_DETAIL'  ) AS FKPARENT  

JOIN  

(  SELECT  PC.catalog_name AS FKTABLE_CAT, PS.schema_name AS FKTABLE_SCHEM, PT.table_name AS FKTABLE_NAME, PL.column_name AS FKCOLUMN_NAME,  constraint_id,  column_sequence,  FK_on_update_action,  FK_on_delete_action,  constraint_name,  initially_deferred,  "deferrable",  FK_child_table_id  FROM  

CATALOG_DEFINITION_SCHEMA.sysCatalog PC,  CATALOG_DEFINITION_SCHEMA.sysSchema PS,  CATALOG_DEFINITION_SCHEMA.sysColumn PL,  CATALOG_DEFINITION_SCHEMA.sysTable PT2,  CATALOG_DEFINITION_SCHEMA.sysTable PT,  (CATALOG_DEFINITION_SCHEMA.sysConstraintColumn J natural join  CATALOG_DEFINITION_SCHEMA.sysConstraint )  

WHERE  parent_or_child_table='C'  AND FK_parent_table_id<>0  AND FK_child_table_id=PT.table_id  AND PT.schema_id=PS.schema_id  AND PS.catalog_id=PC.catalog_id  AND J.column_id=PL.column_id  AND PL.table_id=PT.table_id  AND PC.catalog_name ='db1'  AND PS.schema_name ='RESTAURANT'  AND FK_parent_table_id=PT2.table_id  AND PT2.table_name LIKE '%'  AND PT.table_name LIKE 'CHECK_DETAIL'  ) AS FKCHILD  

USING (constraint_id, column_sequence, FK_child_table_id) 
ORDER BY FKTABLE_CAT, FKTABLE_SCHEM, FKTABLE_NAME, KEY_SEQ 