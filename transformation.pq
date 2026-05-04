// ============================================================
// Pharmaceutical Unit Conversion Factor
// Power Query M — Microsoft Fabric Dataflow Gen2
//
// Author: [Your Name]
// Description: Derives a conversion_factor column from
//              unstructured product description text in the
//              ERP mat table.
// ============================================================

let
  // ─────────────────────────────────────────────────────────
  // STEP 1 — Source ingestion via DirectQuery
  // Custom SQL includes a correlated subquery to retrieve
  // the most recent stock movement per product.
  // ─────────────────────────────────────────────────────────
  Fonte = Sql.Database(
    "YOUR_SERVER_IP",
    "YOUR_DATABASE_NAME",
    [
      Query = "
        select
          (
            SELECT TOP 1 mma_mat_cod
            FROM mma as mmab
            WHERE mmab.mma_mat_cod = mat_cod
            ORDER BY mmab.MMA_DATA_MOV DESC
          ) as mmat_mat_cod,
          mat_cod,
          mat_smk_tipo,
          MAT_CTF_TIPO,
          mat_desc_resumida,
          mat_smk_cod,
          MAT_PRC_ULT_ENTRADA,
          mat_vlr_pm,
          mat_unm_venda,
          mat_fat_conv_frac
        from mat
      "
    ]
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 2 — Detect uppercase " ML" pattern in description
  // ─────────────────────────────────────────────────────────
  #"Coluna Condicional Adicionada" = Table.AddColumn(
    Fonte,
    " ML",
    each if Text.Contains([mat_desc_resumida], " ML") then " ML" else null
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 3 — Parse volume value when " ML" pattern detected
  // Uses delimiter splitting + list reversal to locate the
  // numeric token immediately preceding the " ML" marker.
  // ─────────────────────────────────────────────────────────
  #"Coluna Personalizada Adicionada" = Table.AddColumn(
    #"Coluna Condicional Adicionada",
    "Conversão "" ML""",
    each
      let
        splitmatdescresumida      = Splitter.SplitTextByDelimiter("   ", QuoteStyle.None)([mat_desc_resumida]),
        splitsplitmatdescresumida0 = List.Reverse(Splitter.SplitTextByDelimiter(" ", QuoteStyle.None)(splitmatdescresumida{0}?))
      in
        splitsplitmatdescresumida0{1}?,
    type text
  ),

  #"Tipo Alterado"    = Table.TransformColumnTypes(#"Coluna Personalizada Adicionada", {{"Conversão "" ML""", type number}}),
  #"Erros Substituídos" = Table.ReplaceErrorValues(#"Tipo Alterado", {{"Conversão "" ML""", 1}}),

  // ─────────────────────────────────────────────────────────
  // STEP 4 — Detect lowercase " ml" pattern
  // ─────────────────────────────────────────────────────────
  #"Coluna Condicional Adicionada1" = Table.AddColumn(
    #"Erros Substituídos",
    " ml",
    each if Text.Contains([mat_desc_resumida], " ml") then " ml" else null
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 5 — Extract all digits from description as fallback
  // ─────────────────────────────────────────────────────────
  #"Caracteres Mantidos Inseridos" = Table.AddColumn(
    #"Coluna Condicional Adicionada1",
    "Caracteres Mantidos",
    each Text.Select([mat_desc_resumida], {"0".."9"}),
    type text
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 6 — Parse volume value when " ml" (lowercase) detected
  // More complex extraction: handles descriptions where value
  // follows a period-delimited segment.
  // Text.Reverse + Text.Middle used to extract from end of string
  // (M Language has no native Right() function).
  // ─────────────────────────────────────────────────────────
  #"Coluna Personalizada Adicionada1" = Table.AddColumn(
    #"Caracteres Mantidos Inseridos",
    "Personalizar",
    each
      let
        splitmatdescresumida      = Splitter.SplitTextByDelimiter(" ml.", QuoteStyle.None)([mat_desc_resumida]),
        splitsplitmatdescresumida0 = List.Reverse(Splitter.SplitTextByDelimiter(" ", QuoteStyle.None)(splitmatdescresumida{0}?)),
        splitmatdescresumida2     = List.Reverse(Splitter.SplitTextByDelimiter(" ", QuoteStyle.None)([mat_desc_resumida])),
        byMl                      = List.Reverse(Splitter.SplitTextByDelimiter("ml", QuoteStyle.None)([mat_desc_resumida])),
        splitsplitmatdescresumida31 = List.Reverse(Splitter.SplitTextByDelimiter(".", QuoteStyle.None)(byMl{1}?))
      in
        Text.Combine({
          splitsplitmatdescresumida0{0}?,
          Text.Middle(splitmatdescresumida2{8}?, 4)
        }),
    type text
  ),

  #"Coluna Condicional Adicionada2" = Table.AddColumn(
    #"Coluna Personalizada Adicionada1",
    "Personalizar.1",
    each if [Personalizar] = "" then [Caracteres Mantidos] else [Personalizar]
  ),

  #"Tipo Alterado1"    = Table.TransformColumnTypes(#"Coluna Condicional Adicionada2", {{"Personalizar.1", type number}}),
  #"Erros Substituídos1" = Table.ReplaceErrorValues(#"Tipo Alterado1", {{"Personalizar.1", 999999999999}}),

  #"Coluna Condicional Adicionada3" = Table.AddColumn(
    #"Erros Substituídos1",
    "Personalizar.2",
    each if [Personalizar.1] = 999999999999 then [Caracteres Mantidos] else [Personalizar.1]
  ),

  #"Personalização Adicionada" = Table.AddColumn(
    #"Coluna Condicional Adicionada3",
    "Personalizar.3",
    each [Personalizar.2] * 1
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 7 — Remove intermediate parsing columns
  // ─────────────────────────────────────────────────────────
  #"Colunas Removidas" = Table.RemoveColumns(
    #"Personalização Adicionada",
    {"Caracteres Mantidos", "Personalizar", "Personalizar.1", "Personalizar.2"}
  ),

  #"Erros Substituídos2" = Table.ReplaceErrorValues(#"Colunas Removidas", {{"Personalizar.3", 9999999999}}),

  // ─────────────────────────────────────────────────────────
  // STEP 8 — Secondary ml parsing strategy (position-based)
  // Combines Text.Reverse + Text.Middle to extract numeric
  // tokens from specific character positions in edge-case
  // description formats.
  // ─────────────────────────────────────────────────────────
  #"Coluna Personalizada Adicionada2" = Table.AddColumn(
    #"Erros Substituídos2",
    "Personalizar",
    each
      let
        byDotSpace       = List.Reverse(Splitter.SplitTextByDelimiter(". ", QuoteStyle.None)([mat_desc_resumida])),
        innerByDot       = Splitter.SplitTextByDelimiter(".", QuoteStyle.None)(byDotSpace{1}?),
        byDotPad         = Splitter.SplitTextByDelimiter(".   ", QuoteStyle.None)([mat_desc_resumida]),
        tokensBySpace    = Splitter.SplitTextByDelimiter(" ", QuoteStyle.None)(byDotPad{0}?),
        reversedByDot    = List.Reverse(Splitter.SplitTextByDelimiter(".", QuoteStyle.None)(byDotPad{0}?)),
        byMl             = List.Reverse(Splitter.SplitTextByDelimiter("ml", QuoteStyle.None)([mat_desc_resumida])),
        innerMlByDot     = List.Reverse(Splitter.SplitTextByDelimiter(".", QuoteStyle.None)(byMl{1}?))
      in
        Text.Combine({
          Text.Reverse(Text.Middle(Text.Reverse(innerByDot{1}?), 5)),
          Text.Reverse(Text.Middle(Text.Reverse(tokensBySpace{7}?), 2)),
          Text.Middle(reversedByDot{0}?, 27, 1),
          Text.Reverse(Text.Middle(Text.Reverse(innerMlByDot{0}?), 1, 2))
        }),
    type text
  ),

  #"Tipo Alterado2"    = Table.TransformColumnTypes(#"Coluna Personalizada Adicionada2", {{"Personalizar", type number}}),
  #"Erros Substituídos3" = Table.ReplaceErrorValues(#"Tipo Alterado2", {{"Personalizar", 9999999999}}),

  // ─────────────────────────────────────────────────────────
  // STEP 9 — Priority override flag
  // Some products match a text pattern but the extracted value
  // would be wrong. Flag forces lookup table usage instead.
  // ─────────────────────────────────────────────────────────
  #"Coluna Condicional Adicionada12" = Table.AddColumn(
    #"Erros Substituídos3",
    "Priorizar_Avulso",
    each
      if [mat_desc_resumida] = "PRODUCT_A 50 MCG/ML FR 2,5 ML        " then "sim"
      else if [mat_desc_resumida] = "PRODUCT_B 100 UI/ML FRA 10 ML     " then "sim"
      else if [mat_desc_resumida] = "PRODUCT_C 100 UI/ML 3 ML          " then "sim"
      // Add additional overrides as needed
      else null
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 10 — Lookup table for known exception products
  // Products where text parsing is unreliable are mapped
  // explicitly. This covers ~200+ distinct descriptions.
  //
  // Categories handled:
  //   - Oral liquid solutions (ml)
  //   - Injectable solutions (ml)
  //   - Hormones/biologics measured in UI (International Units)
  //   - Topical products measured in grams
  //   - Medical tapes/dressings measured in mm x m
  //   - Ophthalmic drops (ml)
  //   - Nutritional supplements (g / ml)
  // ─────────────────────────────────────────────────────────
  #"Coluna Condicional Adicionada9" = Table.AddColumn(
    #"Coluna Condicional Adicionada12",
    "Personalizar.1",
    each
      // ── Oral liquids ──────────────────────────────────────
      if [Personalizar] = "PRODUCT_ORAL_LIQ_A 250 mg. fr. 75ML      " then 75
      else if [Personalizar] = "PRODUCT_ORAL_LIQ_B 10MG/ML 50ML SOL     " then 50
      // ── Injectable / IV bags ──────────────────────────────
      else if [Personalizar] = "PRODUCT_INJ_A 2 MG/ML BOL 100ML         " then 100
      else if [Personalizar] = "PRODUCT_INJ_B 100 MG/100ML BOL          " then 100
      // ── International Units (UI) ──────────────────────────
      else if [Personalizar] = "PRODUCT_UI_A 400.000 UI FRA             " then 400000
      else if [Personalizar] = "PRODUCT_UI_B 5000 UI cx. 2 amps.        " then 5000
      else if [Personalizar] = "PRODUCT_UI_C 1.000.000 UI 25 FA         " then 1000000
      // ── Insulin products ──────────────────────────────────
      else if [Personalizar] = "INSULIN_A 100 UI/ML FRA 10 ML           " then 100
      else if [Personalizar] = "INSULIN_B 100 UI/ML 3 ML                " then 100
      // ── Nutritional supplements ───────────────────────────
      else if [Personalizar] = "SUPPLEMENT_A 1000ML SIST.AB.            " then 1000
      else if [Personalizar] = "SUPPLEMENT_B 400 GR                     " then 400
      // ── Topical / dermatological ──────────────────────────
      else if [Personalizar] = "TOPICAL_A 60 GR                         " then 60
      else if [Personalizar] = "TOPICAL_B 5% ESMALTE 2,5ML              " then 25
      // ── Medical tapes (converted to mm) ───────────────────
      else if [Personalizar] = "TAPE_A 100 MM X 4,5 M                   " then 4500
      else if [Personalizar] = "TAPE_B 50 MM X 10 M                     " then 1000
      // ── Ophthalmic drops ──────────────────────────────────
      else if [Personalizar] = "EYE_DROP_A 10ML                         " then 10
      else if [Personalizar] = "EYE_DROP_B 5ML                          " then 5
      // ── Default: no conversion (unit product) ─────────────
      else 1,
    type any
  ),

  #"Tipo Alterado3"   = Table.TransformColumnTypes(#"Coluna Condicional Adicionada9", {{"Personalizar.1", Int64.Type}}),
  #"Colunas Renomeadas1" = Table.RenameColumns(#"Tipo Alterado3", {{"Personalizar.1", "Conversão avulso"}}),

  // ─────────────────────────────────────────────────────────
  // STEP 11 — Trim whitespace from key columns
  // ─────────────────────────────────────────────────────────
  #"Texto Aparado" = Table.TransformColumns(
    #"Colunas Renomeadas1",
    {
      {"mat_smk_cod",  Text.Trim, type text},
      {"mat_smk_tipo", Text.Trim, type text}
    }
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 12 — Final merge: apply priority cascade to produce
  //           the single conversion_factor output column.
  //
  //   Priority 1: text-parsed ML (uppercase) if no override flag
  //   Priority 2: text-parsed ml (lowercase) if no override flag
  //   Priority 3: lookup table value (handles overrides + unknowns)
  // ─────────────────────────────────────────────────────────
  #"Coluna Condicional Adicionada10" = Table.AddColumn(
    #"Texto Aparado",
    "conversão_final",
    each
      if [#" ML"] <> null and [#"Conversão "" ML"""] <> null and [Priorizar_Avulso] = null
        then [#"Conversão "" ML"""]
      else if [#" ml"] <> null and [#"Conversão ""ml"""] <> null and [Priorizar_Avulso] = null
        then [#"Conversão ""ml"""]
      else
        [Conversão avulso]
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 13 — Null coalescing for classification type
  //           and composite key creation for downstream joins
  // ─────────────────────────────────────────────────────────
  #"Texto Aparado1" = Table.TransformColumns(
    #"Coluna Condicional Adicionada10",
    {
      {"mat_smk_tipo", Text.Trim, type text},
      {"MAT_CTF_TIPO", Text.Trim, type text}
    }
  ),

  #"Coluna Condicional Adicionada11" = Table.AddColumn(
    #"Texto Aparado1",
    "mat_smk_tipo_adapt",
    each if [mat_smk_tipo] = null then [MAT_CTF_TIPO] else [mat_smk_tipo]
  ),

  #"Personalização Adicionada1" = Table.AddColumn(
    #"Coluna Condicional Adicionada11",
    "smk_cod_tipo",
    each [mat_smk_cod] & "_" & [mat_smk_tipo_adapt]
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 14 — Type enforcement and error cleanup
  // ─────────────────────────────────────────────────────────
  #"Transformar colunas" = Table.TransformColumnTypes(
    #"Personalização Adicionada1",
    {
      {" ML",              type text},
      {" ml",              type text},
      {"Conversão ""ml""", type text},
      {"Personalizar",     type text},
      {"Priorizar_Avulso", type text},
      {"conversão_final",  type text},
      {"mat_smk_tipo_adapt", type text},
      {"smk_cod_tipo",     type text}
    }
  ),

  #"Substituir erros" = Table.ReplaceErrorValues(
    #"Transformar colunas",
    {
      {" ML",              null},
      {" ml",              null},
      {"Conversão ""ml""", null},
      {"Personalizar",     null},
      {"Priorizar_Avulso", null},
      {"conversão_final",  null},
      {"mat_smk_tipo_adapt", null},
      {"smk_cod_tipo",     null}
    }
  ),

  // ─────────────────────────────────────────────────────────
  // STEP 15 — Final column rename for output clarity
  // ─────────────────────────────────────────────────────────
  #"Colunas renomeadas 1" = Table.RenameColumns(
    #"Substituir erros",
    {{" ML", "ML"}, {" ml", "ml 1"}}
  )

in
  #"Colunas renomeadas 1"
