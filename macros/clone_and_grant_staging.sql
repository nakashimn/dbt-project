{% macro grant_privilege_on_object(target_database, target_schema, target_dbrole, object, privileges) %}

{#
  オブジェクトの権限をデータベースロールに付与するマクロ

  引数の説明
    - target_database: 対象のデータベース名
    - target_schema: 対象のスキーマ名
    - target_dbrole: 権限付与対象のデータベースロール名
    - object: 対象のオブジェクト
    - privilege: 対象の権限
#}

  {{ log("[grant privilege on object]", info=true) }}

  {% set query %}
    GRANT {{ privilege }} ON {{ object }} IN SCHEMA {{ target_database }}.{{ target_schema }} TO DATABASE ROLE {{ target_dbrole }}
  {% endset %}
  {{ log("run: " ~ query, info=true) }}
  {% do run_query(query) %}

{% end macro %}

{% macro grant_privileges(target_database, target_schema, target_dbrole, object_privileges) %}

{#
  スキーマ以下のオブジェクトの権限をデータベースロールに付与するマクロ

  引数の説明
    - target_database: 対象のデータベース名
    - target_schema: 対象のスキーマ名
    - target_dbrole: 権限付与対象のデータベースロール名
    - object_privileges: 対象のオブジェクトと権限リストの辞書  ex) { "ALL TABLES": ["SELECT"] }
#}

  {{ log("[grant privileges]", info=true) }}

  -- スキーマのUSAGE権限付与処理
  {% set query %}
    GRANT USAGE ON SCHEMA {{ target_database }}.{{ target_schema }} TO DATABASE ROLE {{ target_dbrole }}
  {% endset %}
  {{ log("run: " ~ query, info=true) }}
  {% do run_query(query) %}

  -- オブジェクトへの権限付与処理
  {% for object, privileges in object_privileges.items() %}
    {% for privilege in privileges %}
      {{ grant_privilege_on_object(target_database, target_schema, target_dbrole, object, privilege) }}
    {% endfor %}
  {% endfor %}

{% endmacro %}

{% macro clone_schema(src_database, dst_database, target_schema, data_retention_days=0, comment="") %}

{#
  スキーマをクローンするマクロ

  引数の説明
    - src_database: クローン元のデータベース名
    - dst_database: クローン先のデータベース名
    - target_schema: クローン対象のスキーマ名
    - data_retention_days: TimeTravel用履歴の保持日数
    - comment: スキーマのコメント
#}

  {{ log("[clone schema]", info=true) }}

  {% set query %}
    CREATE OR REPLACE SCHEMA {{ dst_database }}.{{ target_schema }} CLONE {{ src_database }}.{{ target_schema }}
    DATA_RETENTION_IN_DAYS = {{ data_retention_days }}
    COMMENT = "{{ comment }}"
  {% endset %}
  {{ log("run: " ~ query, info=true) }}
  {% do run_query(query) %}

{% endmacro %}

{% macro enable_managed_access(target_database, target_schema) %}

{#
  スキーマのManaged Accessを有効化するマクロ

  引数の説明
    - target_database: 対象のデータベース名
    - target_schema: 対象のスキーマ名
#}

  {{ log("[enable managed access]", info=true) }}

  {% set query %}
    ALTER SCHEMA {{ target_database }}.{{ target_schema }} ENABLE MANAGED ACCESS
  {% endset %}
  {{ log("run: " ~ query, info=true) }}
  {% do run_query(query) %}

{% endmacro %}

{% macro grant_ownership_on_all_objects(target_database, target_schema, target_objects, target_role) %}

{#
  スキーマ内の全オブジェクトのオーナーシップをロールに付与するマクロ

  引数の説明
    - target_database: 対象のデータベース名
    - target_schema: 対象のスキーマ名
    - target_objects: 対象のオブジェクトのリスト
    - target_role: オーナーシップ付与対象のロール名
#}

  {% for item in sequence %}
    {{ log("[grant ownership on all " ~ object ~ " ]", info=true) }}
    {% set query %}
      GRANT OWNERSHIP ON ALL {{ object }} IN SCHEMA {{ target_database }}.{{ target_schema }} TO ROLE {{ target_role }} COPY CURRENT GRANTS
    {% endset %}
    {{ log("run: " ~ query, info=true) }}
    {% do run_query(query) %}
  {% endfor %}

{% endmacro %}

{% macro clone_production(dst_database, target_schemas=["STAGING", "FACT", "DIMENSION"], owner_role="", managed_access=true) %}

{#
  本番環境のスキーマを検証用環境・開発環境にクローンするマクロ

  引数の説明
    - dst_database: クローン先のデータベース名
    - target_schemas: クローン対象のスキーマ名のリスト
    - owner_role: オーナーとするロール名
    - managed_access: クローン先のスキーマのManagedAccessを有効化するフラグ

  実行コマンド
  `>dbt run-operation clone_production --args "{dst_database: STAGING}" --target stg`

#}

  {{ log("[clone production]", info=true) }}

  -- パラメータ
  {% set src_database = "PRODUCTION" %}
  {% set data_retention_days = 0 %}
  {% set readwrite_object_privileges = {
    "ALL TABLES": ["ALL"],
    "ALL VIEWS": ["ALL"],
    "FUTURE TABLES": ["ALL"],
    "FUTURE VIEWS": ["ALL"]
  } %}
  {% set readonly_object_privileges = {
    "ALL TABLES": ["SELECT"],
    "ALL VIEWS": ["SELECT"],
    "FUTURE TABLES": ["SELECT"],
    "FUTURE VIEWS": ["SELECT"]
  } %}
  {% set ownership_grantee_objects = ["TABLES", "VIEWS"] %}

  -- デバッグログ
  {{ log("parameters: ", info=true) }}
  {{ log("  src database: " ~ src_database, info=true) }}
  {{ log("  dst database: " ~ dst_database, info=true) }}
  {{ log("  target schemas: " ~ target_schemas, info=true) }}

  {% for target_schema in target_schemas %}

    -- スキーマのクローン処理
    {% set comment = src_database ~ "." ~ target_schema ~ "の定期クローン" %}
    {{ clone_schema(src_database, dst_database, target_schema, data_retention_days=0, comment=comment) }}

    -- Managed Access有効化
    {% if managed_access %}
      {{ enable_managed_access(dst_database, target_schema) }}
    {% endif %}

    -- READWRITE権限付与処理
    -- 権限付与先は"{スキーマ名}_READWRITE"の名称を持つデータベースロールを想定する
    {% set target_dbrole = dst_database ~ "." ~ target_schema ~ "_READWRITE" %}
    {{ grant_privileges(dst_database, target_schema, target_dbrole, readwrite_object_privileges) }}

    -- READONLY権限付与処理
    -- 権限付与先は"{スキーマ名}_READONLY"の名称を持つデータベースロールを想定する
    {% set target_dbrole = dst_database ~ "." ~ target_schema ~ "_READONLY" %}
    {{ grant_privileges(dst_database, target_schema, target_dbrole, readonly_object_privileges) }}

    -- Ownership権限移譲処理
    {% if owner_role != "" %}
      {{ grant_ownership_on_all_objects(dst_database, target_schema, ownership_grantee_objects, owner_role) }}
    {% endif %}

  {% endfor %}

{% endmacro %}
