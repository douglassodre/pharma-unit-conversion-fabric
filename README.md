# 💊 Pharmaceutical Unit Conversion Factor — Data Engineering with Power Query M (Microsoft Fabric)

## Overview

This project addresses a real-world data quality problem in a **healthcare ERP system**: a product catalog table where unit-of-measure information was embedded as unstructured free text inside a description field — making it impossible to perform volume-based price comparisons, inventory analysis, or dosage calculations directly from the database.

The solution is a fully automated **data ingestion and transformation pipeline** built with **Power Query M Language** inside a **Microsoft Fabric Dataflow Gen2**, which enriches the source table by deriving and adding a `conversion_factor` column without modifying the source system.

---

## The Problem

The source ERP database stores pharmaceutical products in a `mat` table where the column `mat_desc_resumida` contains descriptions like:

```
AMOXICILINA 250 mg/5 ml susp.oral fr.75ML
CEFADROXIL 250 mg. po oral fr. vd.80 ml.
MAALOX PLUS 240 ml - sabor cereja
FLUOXETINA 20 mg/ml sol. oral fr. 20 ml
HEPARINA SODICA 5000 UI/0,25 ML SUBCUT
```

The **unit of measure** (volume in ml, UI — international units, grams, etc.) was buried inside this string, with **no consistent format or pattern**. Some products measured in `ML` (uppercase), others in `ml` (lowercase). Some used punctuation as delimiters, others had the number at different positions within the string. Specialized products (e.g. insulin, hormone solutions) followed completely different conventions.

Without a clean `conversion_factor` column, it was impossible to:
- Normalize prices to cost-per-ml for liquid medications
- Aggregate inventory by standardized volume
- Feed downstream reports and BI dashboards correctly

---

## Solution Architecture

```
SQL Server (ERP SmartCare)
        │
        │  DirectQuery via Sql.Database()
        ▼
┌─────────────────────────────────┐
│   Microsoft Fabric Dataflow     │
│        (Dataflow Gen2)          │
│                                 │
│  Power Query M Pipeline:        │
│  ┌──────────────────────────┐   │
│  │ 1. SQL Ingestion         │   │
│  │ 2. ML Detection (upper)  │   │
│  │ 3. ml Detection (lower)  │   │
│  │ 4. Text Parsing          │   │
│  │ 5. Error Handling        │   │
│  │ 6. Lookup Table          │   │
│  │ 7. Priority Override     │   │
│  │ 8. Final Merge Logic     │   │
│  └──────────────────────────┘   │
└─────────────────────────────────┘
        │
        ▼
  Enriched Table (with conversion_factor)
        │
        ▼
  Power BI / Lakehouse / Reports
```

---

## Multi-Strategy Extraction Logic

Because the source data had no single reliable pattern, a **layered extraction strategy** was designed with explicit priority and fallback rules:

```
Priority 1 → Manual override flag (Priorizar_Avulso)
    ↓ if null
Priority 2 → Detected " ML" (uppercase) → regex-style text parsing
    ↓ if null
Priority 3 → Detected " ml" (lowercase) → delimiter-based parsing
    ↓ if null
Priority 4 → Lookup table (known products with hardcoded values)
    ↓ if null
Priority 5 → Default fallback = 1 (unit product, no volume conversion)
```

---

## Key Techniques Used

### 1. SQL Integration via DirectQuery
The pipeline connects directly to the operational database using `Sql.Database()`, passing a custom SQL query that also retrieves the most recent stock movement per product via a correlated subquery.

```powerquery
Fonte = Sql.Database("server_ip", "DatabaseName", [
    Query = "
        SELECT
            (SELECT TOP 1 mma_mat_cod
             FROM mma AS mmab
             WHERE mmab.mma_mat_cod = mat_cod
             ORDER BY mmab.MMA_DATA_MOV DESC) AS mmat_mat_cod,
        mat_cod,
        mat_smk_tipo,
        MAT_CTF_TIPO,
        mat_desc_resumida,
        mat_smk_cod,
        MAT_PRC_ULT_ENTRADA,
        mat_vlr_pm,
        mat_unm_venda,
        mat_fat_conv_frac
        FROM mat
    "
])
```

### 2. Pattern Detection (Conditional Columns)

The first step flags which unit pattern is present in the description, enabling downstream strategy selection:

```powerquery
#"ML Detection" = Table.AddColumn(Source, "has_ML",
    each if Text.Contains([mat_desc_resumida], " ML") then " ML" else null),

#"ml Detection" = Table.AddColumn(#"ML Detection", "has_ml",
    each if Text.Contains([mat_desc_resumida], " ml") then " ml" else null)
```

### 3. Positional Text Parsing with Splitter + List.Reverse

For descriptions containing ` ML`, the number immediately before the unit marker is extracted using delimiter-based splitting and list reversal — a technique that navigates variable-length strings without regex:

```powerquery
#"ML Conversion" = Table.AddColumn(#"ml Detection", "conversion_ML",
    each let
        parts = Splitter.SplitTextByDelimiter("   ", QuoteStyle.None)([mat_desc_resumida]),
        tokens = List.Reverse(Splitter.SplitTextByDelimiter(" ", QuoteStyle.None)(parts{0}?))
    in tokens{1}?,
    type text)
```

For the `ml` (lowercase) pattern, a more complex extraction handles descriptions where the number appears after a period-delimited section:

```powerquery
each let
    byMlDot   = Splitter.SplitTextByDelimiter(" ml.", QuoteStyle.None)([mat_desc_resumida]),
    reversed  = List.Reverse(Splitter.SplitTextByDelimiter(" ", QuoteStyle.None)(byMlDot{0}?)),
    byMl      = List.Reverse(Splitter.SplitTextByDelimiter("ml", QuoteStyle.None)([mat_desc_resumida])),
    innerPart = List.Reverse(Splitter.SplitTextByDelimiter(".", QuoteStyle.None)(byMl{1}?))
in Text.Combine({reversed{0}?, Text.Middle(innerPart{0}?, 4)})
```

`Text.Reverse` + `Text.Middle` were also combined as a technique to extract characters from the *end* of a string — since M Language lacks a native `Right()` function.

### 4. Structured Error Handling

Every numeric conversion step wraps errors with a sentinel value (`999999999999`), which is then used in conditional logic to trigger the next fallback strategy:

```powerquery
#"ML Typed"          = Table.TransformColumnTypes(#"ML Conversion", {{"conversion_ML", type number}}),
#"ML Errors Handled" = Table.ReplaceErrorValues(#"ML Typed", {{"conversion_ML", 1}})
```

For the ml-parsing column:
```powerquery
#"Errors to Sentinel" = Table.ReplaceErrorValues(#"ml Typed", {{"conversion_ml", 999999999999}})
```

### 5. Lookup Table for Known Exceptions

Products whose descriptions could not be reliably parsed (due to irregular formats, acronyms, or domain-specific notation like `UI` — International Units) were handled via an explicit lookup table — a large conditional column mapping exact descriptions to their known conversion factors:

```powerquery
#"Lookup Overrides" = Table.AddColumn(#"Previous Step", "lookup_value",
    each
        if [mat_desc_resumida] = "PRODUCT_A 250 mg/5 ml fr. 100ml" then 100
        else if [mat_desc_resumida] = "PRODUCT_B NASAL SPRAY 15 ml"   then 15
        else if [mat_desc_resumida] = "HORMONE_C 5000 UI 50 FA"       then 5000
        // ... 200+ entries covering edge cases
        else 1,
    type any)
```

This pattern trades flexibility for correctness — a deliberate engineering decision when the data source cannot be fixed upstream.

### 6. Priority Override Flag

Certain products required the lookup table to take precedence *even when* the text parser would find a match (because the parser would extract the wrong number). An explicit flag column was introduced:

```powerquery
#"Priority Flag" = Table.AddColumn(#"Lookup Overrides", "force_lookup",
    each
        if [mat_desc_resumida] = "PRODUCT_X 100 UI/ML FRA 10 ML" then "yes"
        else if [mat_desc_resumida] = "PRODUCT_Y 2,5 MCG FR 4ML"     then "yes"
        else null)
```

### 7. Final Merge Logic

All strategy outputs are consolidated into a single `conversion_factor` column via a cascading conditional:

```powerquery
#"Final Merge" = Table.AddColumn(#"Priority Flag", "conversion_factor",
    each
        if [has_ML] <> null and [conversion_ML] <> null and [force_lookup] = null
            then [conversion_ML]
        else if [has_ml] <> null and [conversion_ml] <> null and [force_lookup] = null
            then [conversion_ml]
        else
            [lookup_value])
```

### 8. Data Cleaning and Column Governance

After transformation, cleanup steps are applied for downstream compatibility:

```powerquery
// Trim whitespace from key code columns
#"Trimmed" = Table.TransformColumns(#"Final Merge", {
    {"mat_smk_cod",  Text.Trim, type text},
    {"mat_smk_tipo", Text.Trim, type text},
    {"MAT_CTF_TIPO", Text.Trim, type text}
}),

// Null coalescing for classification field
#"Type Adapter" = Table.AddColumn(#"Trimmed", "mat_smk_tipo_adapt",
    each if [mat_smk_tipo] = null then [MAT_CTF_TIPO] else [mat_smk_tipo]),

// Composite key for downstream joins
#"Composite Key" = Table.AddColumn(#"Type Adapter", "smk_cod_tipo",
    each [mat_smk_cod] & "_" & [mat_smk_tipo_adapt]),

// Intermediate columns removed before output
#"Final Cleanup" = Table.RemoveColumns(#"Composite Key", {
    "has_ML", "has_ml", "lookup_raw", "parse_raw",
    "sentinel_col", "force_lookup"
})
```

---

## Output Schema

| Column | Description |
|---|---|
| `mat_cod` | Product code (PK) |
| `mmat_mat_cod` | Latest stock movement reference |
| `mat_desc_resumida` | Original product description (source) |
| `mat_smk_tipo` | Product classification type |
| `MAT_CTF_TIPO` | Regulatory category |
| `mat_smk_cod` | SMK code |
| `MAT_PRC_ULT_ENTRADA` | Last entry price |
| `mat_vlr_pm` | Weighted average cost |
| `mat_unm_venda` | Sales unit of measure |
| `mat_fat_conv_frac` | Fractional conversion factor (source system) |
| `conversion_factor` | **Derived: volume/unit conversion factor (this project)** |
| `smk_cod_tipo` | Composite classification key |
| `mat_smk_tipo_adapt` | Normalized classification type |

---

## Technologies

| Technology | Role |
|---|---|
| Microsoft Fabric | Platform (Dataflow Gen2) |
| Power Query M Language | Transformation logic |
| SQL Server | Source ERP database |
| T-SQL | Source query (correlated subquery for last movement) |

---

## Challenges & Engineering Decisions

**Why not use SQL for this?**
The transformation requires complex positional string parsing with multiple fallback strategies. Power Query M's functional approach (lazy evaluation, step-by-step lineage, built-in error handling per cell) is better suited than SQL string functions for this volume and variety of edge cases.

**Why a lookup table instead of a smarter parser?**
The product descriptions were created by users over 15+ years with no enforced format. Some categories (e.g. hormones measured in International Units) have values embedded in ways that would require domain knowledge to parse programmatically. The lookup table is the pragmatic choice for correctness over generality.

**Why sentinel values instead of direct null checks?**
M Language's `Table.ReplaceErrorValues` operates at the table level and replaces type errors (conversion failures) with a scalar. Using a sentinel like `999999999999` allows the downstream conditional logic to distinguish "value not found" from "value is legitimately null" — which matters for the priority cascade.

---

## How to Reproduce

1. Open Microsoft Fabric and create a new **Dataflow Gen2**
2. In the Advanced Editor, paste the M code from [`transformation.pq`](./transformation.pq)
3. Update the server IP and database name in the `Sql.Database()` call
4. Adjust the lookup table entries (`#"Lookup Overrides"` step) for your product catalog
5. Publish and schedule the dataflow

---

## Repository Structure

```
.
├── README.md               ← This file
├── transformation.pq       ← Full Power Query M source code
└── docs/
    └── extraction_logic.md ← Detailed documentation of the parsing strategies
```
