WITH base AS (
    SELECT
        study_name,
        TRIM(BOTH ',' FROM CONCAT_WS(',',
            -- Case 1: Explicit CPT keyword
            IF(study_name REGEXP '\\bCPT\\s*[0-9]{5}\\b',
                REGEXP_REPLACE(REGEXP_SUBSTR(study_name, 'CPT\\s*[0-9]{5}'), '[^0-9]', ''), NULL),
            -- Case 2a-c: Standalone 5-digit codes (suppressed when CPT keyword present)
            IF(study_name NOT REGEXP '\\bCPT\\s*[0-9]{5}\\b' AND study_name REGEXP '(^|[^0-9])[0-9]{5}([^0-9]|$)',
                REGEXP_REPLACE(REGEXP_SUBSTR(study_name, '(^|[^0-9])[0-9]{5}([^0-9]|$)', 1, 1), '[^0-9]', ''), NULL),
            IF(study_name NOT REGEXP '\\bCPT\\s*[0-9]{5}\\b',
                NULLIF(REGEXP_REPLACE(REGEXP_SUBSTR(study_name, '(^|[^0-9])[0-9]{5}([^0-9]|$)', 1, 2), '[^0-9]', ''), ''), NULL),
            IF(study_name NOT REGEXP '\\bCPT\\s*[0-9]{5}\\b',
                NULLIF(REGEXP_REPLACE(REGEXP_SUBSTR(study_name, '(^|[^0-9])[0-9]{5}([^0-9]|$)', 1, 3), '[^0-9]', ''), ''), NULL),
            -- Case 3: Internal IDs (only when no 5-digit found)
            IF(study_name NOT REGEXP '(^|[^0-9])[0-9]{5}([^0-9]|$)' AND study_name REGEXP '[A-Za-z]+[0-9]{6,}',
                REGEXP_SUBSTR(study_name, '[A-Za-z]+[0-9]{6,}'), NULL),
            -- Case 4: HCPCS format (1 letter + 4 digits)
            NULLIF(REGEXP_SUBSTR(study_name, '\\b[A-Za-z][0-9]{4}\\b'), '')
        )) AS extracted_codes
    FROM (
        SELECT REGEXP_REPLACE(
                REGEXP_REPLACE(study_name,
                    '([0-9]{5})\\s+[Oo][Rr]\\s+([0-9]{5})', '\\1,\\2'),
                '([0-9]{5})\\s*/\\s*([0-9]{5})', '\\1,\\2')
               AS study_name
        FROM rgd_udm_silver.radiology
    ) normalized
),

code_lookup AS (
    SELECT
        b.study_name,
        b.extracted_codes,
        GROUP_CONCAT(DISTINCT cpt.PROCEDURECODE  ORDER BY cpt.PROCEDURECODE  SEPARATOR ',') AS cpt_codes_std,
        GROUP_CONCAT(DISTINCT hcpcs.HCPC         ORDER BY hcpcs.HCPC         SEPARATOR ',') AS hcpcs_codes_std,
        GROUP_CONCAT(DISTINCT COALESCE(cpt.COMMONDESCRIPTION, cpt.DESCRIPTION, hcpcs.`SHORT DESCRIPTION`)
            ORDER BY COALESCE(cpt.PROCEDURECODE, hcpcs.HCPC) SEPARATOR ' | ')               AS code_descriptions,
        COUNT(DISTINCT cpt.PROCEDURECODE) + COUNT(DISTINCT hcpcs.HCPC)                      AS total_match_count
    FROM base b
    LEFT JOIN JSON_TABLE(
        CONCAT('["', REPLACE(b.extracted_codes, ',', '","'), '"]'),
        '$[*]' COLUMNS (code VARCHAR(20) PATH '$')
    ) codes ON TRUE
    LEFT JOIN tncpa.PROCEDURECODEREFERENCE cpt
        ON codes.code = cpt.PROCEDURECODE AND codes.code REGEXP '^[0-9]{5}$'
    LEFT JOIN semantics.hcpcs hcpcs
        ON codes.code = hcpcs.HCPC        AND codes.code REGEXP '^[A-Za-z][0-9]{4}$'
    GROUP BY b.study_name, b.extracted_codes
),

cpt_std AS (
    SELECT
        l.study_name,
        l.extracted_codes,
        COALESCE(l.cpt_codes_std,    'NS') AS cpt_codes_std,
        COALESCE(l.hcpcs_codes_std,  'NS') AS hcpcs_codes_std,
        COALESCE(l.code_descriptions,'NS') AS code_descriptions,
        CASE
            WHEN l.extracted_codes REGEXP '[A-Za-z]+[0-9]{6,}' AND l.total_match_count = 0 THEN 'Internal Identifier Only'
            WHEN l.total_match_count >= 3  THEN 'Three Codes Present'
            WHEN l.total_match_count = 2   THEN 'Two Codes Present'
            WHEN l.total_match_count = 1   THEN 'Single Code'
            WHEN l.extracted_codes IS NOT NULL AND l.extracted_codes != '' THEN 'Extracted But Not Matched'
            ELSE 'No CPT Code'
        END AS cpt_count_flag
    FROM code_lookup l
)

SELECT DISTINCT
    c.study_name,
    c.extracted_codes,
    c.cpt_codes_std,
    c.hcpcs_codes_std,
    c.code_descriptions,
    c.cpt_count_flag,

    -- PRIMARY MODALITY — derived from study_name only, no CPT description dependency
    CASE
        WHEN c.study_name REGEXP '\\bCT\\b|\\bCAT\\b|\\bNCT\\b|\\bLDCT\\b|\\bCTA\\b|\\bCTV\\b|\\bCTAC\\b|\\bCTC\\b|\\bCTP\\b' THEN 'Computed Tomography'
        WHEN c.study_name REGEXP '\\bPET\\b|\\bPT\\b'                                                                            THEN 'Positron emission tomography (PET)'
        WHEN c.study_name REGEXP '\\bMRA\\b|\\bzzMRA\\b'                                                                         THEN 'Magnetic resonance angiography'
        WHEN c.study_name REGEXP '\\bMRI\\b|\\bMRCP\\b|\\bMRV\\b|\\bTMRI\\b|\\b3TMRI\\b|\\bMR\\b'                               THEN 'Magnetic Resonance'
        WHEN c.study_name REGEXP '\\bMAM\\b|\\bMAMM\\b|\\bMAMMO\\b|\\bMMAMMO\\b|\\bMG\\b|\\bMAMMOGRAM\\b|\\bMAMMOGRAPHY\\b|\\bDEXA\\b|\\bDXA\\b' THEN 'Mammography'
        WHEN c.study_name REGEXP '\\bUS\\b|\\bULTRASOUND\\b|\\bUSV\\b|\\bBI US\\b|\\bOB US\\b'                                   THEN 'Ultrasound'
        WHEN c.study_name REGEXP '\\bXA\\b|\\bANG\\b|\\bANGIO\\b'                                                                THEN 'X-Ray Angiography'
        WHEN c.study_name REGEXP '\\bCR\\b'                                                                                       THEN 'Computed Radiography'
        WHEN c.study_name REGEXP '\\bDX\\b|\\bDR\\b|\\bXR\\b|\\bX-RAY\\b|\\bXRAY\\b|\\bXRY\\b'                                  THEN 'Digital Radiography'
        WHEN c.study_name REGEXP '\\bRF\\b|\\bFL\\b|\\bFLUORO\\b|\\bFLU\\b'                                                      THEN 'Radio Fluoroscopy'
        WHEN c.study_name REGEXP '\\bFS\\b'                                                                                       THEN 'Fundoscopy'
        WHEN c.study_name REGEXP '\\bNM\\b'                                                                                       THEN 'Nuclear Medicine'
        WHEN c.study_name REGEXP '\\bECHO\\b|\\bECHOCARDIOGRAM\\b'                                                               THEN 'Echocardiography'
        WHEN c.study_name REGEXP '\\bECG\\b|\\bEKG\\b'                                                                           THEN 'Electrocardiography'
        WHEN c.study_name REGEXP '\\bEEG\\b|\\bELECTROCEPHANLOGRAM\\b'                                                           THEN 'Electroencephalography'
        WHEN c.study_name REGEXP '\\bENDOSCOPY\\b'                                                                               THEN 'Endoscopy'
        WHEN c.study_name REGEXP '\\bCD\\b'                                                                                       THEN 'Color flow Doppler'
        WHEN c.study_name REGEXP '\\bTCD\\b|\\bDUPLEX\\b|\\bDOPPLER\\b'                                                          THEN 'Duplex Doppler'
        WHEN c.study_name REGEXP '\\bAUDIO\\b|\\bAUDIOMETRY\\b|\\bAUDITORY\\b|\\bHEARING\\b|\\bAUDIOGRAM\\b|\\bACOUSTIC\\b'     THEN 'Audio'
        WHEN c.study_name REGEXP '\\bRP\\b'                                                                                       THEN 'Radiotherapy Plan'
        WHEN c.study_name REGEXP '\\bRT\\b|\\bRAD\\b|\\bIR\\b|\\bINTERVENTIONAL RADIOLOGY\\b'                                    THEN 'Radiographic imaging'
        WHEN c.study_name REGEXP '\\bSPECT\\b'                                                                                    THEN 'Single-photon emission computed tomography (SPECT)'
        WHEN c.study_name REGEXP '\\bBX\\b|\\bBIOPSY\\b|\\bVL\\b|\\bOHS\\b|\\bI-123\\b|\\b1-131\\b|\\bMPI\\b'                   THEN 'Other'
        ELSE 'Other'
    END AS modality,

    -- COMBINED MODALITY — derived from study_name only, no CPT description dependency
    CASE
        WHEN c.study_name REGEXP '\\bPET/CT\\b|\\bPET CT\\b'                        THEN 'Positron emission tomography (PET) / Computed Tomography'
        WHEN c.study_name REGEXP '\\bXR/RF\\b'                                       THEN 'Digital Radiography / Radio Fluoroscopy'
        WHEN c.study_name REGEXP '\\bUS DOPPLER\\b|\\bUS DUPLEX\\b'                  THEN 'Ultrasound / Duplex Doppler'
        WHEN c.study_name REGEXP '\\bUS ECHOCARDIOGRAM\\b'                           THEN 'Ultrasound / Echocardiography'
        WHEN c.study_name REGEXP '\\bXA US\\b'                                       THEN 'X-Ray Angiography / Ultrasound'
        WHEN c.study_name REGEXP '\\bCT\\b|\\bCAT\\b|\\bNCT\\b|\\bLDCT\\b|\\bCTA\\b|\\bCTV\\b|\\bCTAC\\b|\\bCTC\\b|\\bCTP\\b' THEN 'Computed Tomography'
        WHEN c.study_name REGEXP '\\bPET\\b|\\bPT\\b'                                THEN 'Positron emission tomography (PET)'
        WHEN c.study_name REGEXP '\\bMRA\\b|\\bzzMRA\\b'                             THEN 'Magnetic resonance angiography'
        WHEN c.study_name REGEXP '\\bMRI\\b|\\bMRCP\\b|\\bMRV\\b|\\bTMRI\\b|\\b3TMRI\\b|\\bMR\\b' THEN 'Magnetic Resonance'
        WHEN c.study_name REGEXP '\\bMAM\\b|\\bMAMM\\b|\\bMAMMO\\b|\\bMMAMMO\\b|\\bMG\\b|\\bMAMMOGRAM\\b|\\bMAMMOGRAPHY\\b|\\bDEXA\\b|\\bDXA\\b' THEN 'Mammography'
        WHEN c.study_name REGEXP '\\bUS\\b|\\bULTRASOUND\\b|\\bUSV\\b|\\bBI US\\b|\\bOB US\\b'     THEN 'Ultrasound'
        WHEN c.study_name REGEXP '\\bXA\\b|\\bANG\\b|\\bANGIO\\b'                   THEN 'X-Ray Angiography'
        WHEN c.study_name REGEXP '\\bCR\\b'                                           THEN 'Computed Radiography'
        WHEN c.study_name REGEXP '\\bDX\\b|\\bDR\\b|\\bXR\\b|\\bX-RAY\\b|\\bXRAY\\b|\\bXRY\\b'    THEN 'Digital Radiography'
        WHEN c.study_name REGEXP '\\bRF\\b|\\bFL\\b|\\bFLUORO\\b|\\bFLU\\b'         THEN 'Radio Fluoroscopy'
        WHEN c.study_name REGEXP '\\bFS\\b'                                           THEN 'Fundoscopy'
        WHEN c.study_name REGEXP '\\bNM\\b'                                           THEN 'Nuclear Medicine'
        WHEN c.study_name REGEXP '\\bECHO\\b|\\bECHOCARDIOGRAM\\b'                   THEN 'Echocardiography'
        WHEN c.study_name REGEXP '\\bECG\\b|\\bEKG\\b'                               THEN 'Electrocardiography'
        WHEN c.study_name REGEXP '\\bEEG\\b|\\bELECTROCEPHANLOGRAM\\b'               THEN 'Electroencephalography'
        WHEN c.study_name REGEXP '\\bENDOSCOPY\\b'                                   THEN 'Endoscopy'
        WHEN c.study_name REGEXP '\\bCD\\b'                                           THEN 'Color flow Doppler'
        WHEN c.study_name REGEXP '\\bTCD\\b|\\bDUPLEX\\b|\\bDOPPLER\\b'              THEN 'Duplex Doppler'
        WHEN c.study_name REGEXP '\\bAUDIO\\b|\\bAUDIOMETRY\\b|\\bAUDITORY\\b|\\bHEARING\\b|\\bAUDIOGRAM\\b|\\bACOUSTIC\\b' THEN 'Audio'
        WHEN c.study_name REGEXP '\\bRP\\b'                                           THEN 'Radiotherapy Plan'
        WHEN c.study_name REGEXP '\\bRT\\b|\\bRAD\\b|\\bIR\\b|\\bINTERVENTIONAL RADIOLOGY\\b'      THEN 'Radiographic imaging'
        WHEN c.study_name REGEXP '\\bSPECT\\b'                                        THEN 'Single-photon emission computed tomography (SPECT)'
        WHEN c.study_name REGEXP '\\bBX\\b|\\bBIOPSY\\b|\\bVL\\b|\\bOHS\\b|\\bI-123\\b|\\b1-131\\b|\\bMPI\\b' THEN 'Other'
        ELSE 'Other'
    END AS modality_combined

FROM cpt_std c;
