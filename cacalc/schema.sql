-- Version 1. Decimal values are stored as text and calculated with Decimal.
PRAGMA application_id = 1128350529;
PRAGMA user_version = 1;

CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE products (
    barcode TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    brands TEXT NOT NULL,
    search_name TEXT NOT NULL,
    countries_tags TEXT NOT NULL,
    basis_unit TEXT NOT NULL CHECK (basis_unit IN ('unknown', 'g', 'ml')),
    energy_kcal_100 TEXT,
    energy_kj_100 TEXT,
    protein_g_100 TEXT,
    fat_g_100 TEXT,
    carbohydrate_g_100 TEXT,
    energy_origin TEXT NOT NULL CHECK (energy_origin IN ('kcal', 'kj', 'missing')),
    source_url TEXT,
    source_modified_at TEXT,
    raw_nutrition_json TEXT NOT NULL,
    issues_json TEXT NOT NULL
);

