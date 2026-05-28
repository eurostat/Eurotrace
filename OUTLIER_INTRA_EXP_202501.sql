DECLARE @THR_AVG_ZSC Float
DECLARE @THR_MED_ZSC Float
DECLARE @THR_NBOBSMIN int
DECLARE @THR_QUART1 Float
DECLARE @THR_QUART2 Float

-- parameters applied HR_AVG_ZSC above 3 is a possible outlier , HR_MED_ZSC above 5.2, 
-- THR_QUART1 used to test the outliers based on quartile 1 and 3 according to the method 1 TEST_IQ1 : (R.HS_Q1/@THR_QUART1))<=  S.UV <= (R.HS_Q3*@THR_QUART1)
-- THR_QUART2 used in the second method based on quartile 1 and 3 according to the method 2 TEST_IQ2: (R.HS_Q1 - ABS(R.HS_Q3-R.HS_Q1)*@THR_QUART2)) <= S.UV <=(S.UV <= (R.HS_Q3 + ABS(R.HS_Q3-R.HS_Q1)*@THR_QUART2))
-- THR_NBOBSMIN : minimal number of observations expected to allow testing the combination (year, reporter, product, flow)

SELECT	@THR_AVG_ZSC=3.0 
		, @THR_MED_ZSC=5.2
		, @THR_QUART1=3.0
		, @THR_QUART2=1.5
		, @THR_NBOBSMIN=30;
		
-- source: original source taken into account : public ITGS DETAILED DATA excluding special code X and QTYSU 0 for intraeu data

WITH SOURCE AS (
					SELECT 
						[YEAR] AS YEAR
						,[Period] AS MONTH
						,REPORTER AS REPORTER
						,PARTNER AS PARTNER
						,[PRODUCTNC] AS PRODUCT
						, FLOW
						,VALUENAC AS VAL
						,QUANTITYSUPPLUNIT AS QSU
						,ISNULL(VALUENAC,0)/QUANTITYSUPPLUNIT AS UV
					FROM [PWBI_DATA_EUMONTHLY] AS D
					INNER JOIN [PWBI_DIC_INTRA] AS S ON D.PARTNER=S.CODE
					WHERE FLOW='2'
					AND (CHARINDEX('X', [PRODUCTNAX, C], 0)=0)
					AND IsNull(QUANTITYSUPPLUNIT, 0) <> 0)

-- SRCTRS_1: add to SOURCE the calculation of HS_COUNT, HS_MEAN, S_MIN, S_MAX, HS_STDEV and associate the value to each record (recnum) (several records per year, reporter, product, flow) based on SOURCE 
-- RECNUM - rownumber() attribute a row number inside each cluster of year, reporter, product and flow sorted by uv asc which will be used in SRCTRS_2 
, SRCTRS_1 AS (
					SELECT	*
							, COUNT(*) OVER (
								PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_COUNT
							, AVG(UV) OVER (
								PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_MEAN
							, MIN(UV) OVER (
								PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_MIN
							, MAX(UV) OVER (
								PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_MAX
							, IsNull(STDEV(UV) OVER (
								PARTITION BY YEAR, REPORTER, PRODUCT, FLOW), 0) AS HS_STDEV
							, ROW_NUMBER() OVER (
								PARTITION BY YEAR, REPORTER, PRODUCT, FLOW
								ORDER BY UV ASC) AS RECNUM
						FROM SOURCE
) 
-- SRCTRS_2: add to SRCTRS_1 the calculation of HS_MED, HS_Q1, HS_Q3 compared to SRCTRS_1 taken into account only  stdev <> 0 (not a standard price) and a minimal number of occurences = THR_NBOBSMIN (for instance 30)
-- add also RECNUMMAD field - rownumber() attribute a row number inside each cluster of year, reporter, product and flow sorted by uv-HS-MED asc which will be used in SRCTRS_FIN 

, SRCTRS_2 AS (		SELECT	*
					, ROW_NUMBER() OVER (
						PARTITION BY YEAR, REPORTER, PRODUCT, FLOW
						ORDER BY ABS(UV-HS_MED) ASC) AS RECNUM_MAD
					FROM (SELECT	*
							, AVG(CASE 
									WHEN ABS(CAST(RECNUM AS FLOAT)-((CAST(HS_COUNT AS FLOAT)+1)/2))>=1 THEN Null 
									ELSE UV END
										) OVER (PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_MED
							, AVG(CASE 
									WHEN ABS(CAST(RECNUM AS FLOAT)-((CAST(HS_COUNT AS FLOAT)+1)/4))>=1 THEN Null 
									ELSE UV END
										) OVER (PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_Q1
							, AVG(CASE 
									WHEN ABS(CAST(RECNUM AS FLOAT)-((CAST(HS_COUNT AS FLOAT)+1)*3/4))>=1 THEN Null 
									ELSE UV END
										) OVER (PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_Q3

						FROM SRCTRS_1
						WHERE (HS_STDEV<>0) AND (HS_COUNT>@THR_NBOBSMIN)) AS INT
)

-- add to SRCTRS_2 the calculation of HSMAD to have  SRCTRS_FIN

, SRCTRS_FIN AS (		
					SELECT	*
					FROM (SELECT	*
							, AVG(CASE 
									WHEN ABS(CAST(RECNUM_MAD AS FLOAT)-((CAST(HS_COUNT AS FLOAT)+1)/2))>=1 THEN Null 
									ELSE ABS(UV-HS_MED) END
										) OVER (PARTITION BY YEAR, REPORTER, PRODUCT, FLOW) AS HS_MAD
						FROM SRCTRS_2
						) AS INT
),

--aggregate the information calculated previously SRCTRS_FIN by YEAR, REPORTER, PRODUCT, FLOW in MYREF to be used for the detection of outliers 
MYREF AS (
SELECT	YEAR, REPORTER, PRODUCT, FLOW
		, SUM(VAL) AS VAL
		, SUM(QSU) AS QSU
		, MIN(HS_COUNT) AS HS_COUNT
		, MIN(HS_MEAN) AS HS_MEAN
		, MIN(HS_MIN) AS HS_MIN
		, MIN(HS_MAX) AS HS_MAX
		, MIN(HS_STDEV) AS HS_STDEV
		, MIN(HS_MED) AS HS_MED
		, MIN(HS_Q1) AS HS_Q1
		, MIN(HS_Q3) AS HS_Q3
		, MIN(HS_MAD) AS HS_MAD
FROM SRCTRS_FIN
GROUP BY YEAR, REPORTER, PRODUCT, FLOW)

--identification of the outliers based on the previous year data by calculating 
-- Z_AVG: (S.UV-R.HS_MEAN)/R.HS_STDEV
-- Z_MED:  S.UV-R.HS_MED)/R.HS_MAD
-- TEST_IQ1 : (R.HS_Q1/@THR_QUART1))<=  S.UV <= (R.HS_Q3*@THR_QUART1)
-- TEST_IQ2: (R.HS_Q1 - ABS(R.HS_Q3-R.HS_Q1)*@THR_QUART2)) <= S.UV <=(S.UV <= (R.HS_Q3 + ABS(R.HS_Q3-R.HS_Q1)*@THR_QUART2))
-- TEST_ZS_AVG : (S.UV-R.HS_MEAN)/R.HS_STDEV < @THR_AVG_ZSC
-- TEST_ZS_MED : (S.UV-R.HS_MED)/R.HS_MAD < @THR_MED_ZSC 

-- only records with QSU > 10 and  VAL > 10000  and Zscore > THR_AVG_ZSC are extracted

SELECT 
	S.UV,
	R.HS_Q1,
	R.HS_Q3,
	CASE
		WHEN IsNull(R.HS_STDEV, 0.0)= 0.0 THEN 0.0 
		ELSE ABS(S.UV-R.HS_MEAN)/R.HS_STDEV  END AS Z_AVG,
	CASE
		WHEN IsNull(R.HS_MAD, 0.0)= 0.0 THEN 0.0 
		ELSE ABS(S.UV-R.HS_MED)/R.HS_MAD  END AS Z_MED,
	CASE
		WHEN (S.UV >= (R.HS_Q1/@THR_QUART1)) AND (S.UV <= (R.HS_Q3*@THR_QUART1)) THEN 'OK' ELSE 'KO' END AS TEST_IQ1,
	CASE
		WHEN ABS(R.HS_Q3-R.HS_Q1)=0 THEN 'OK'
		WHEN (S.UV >= (R.HS_Q1 - ABS(R.HS_Q3-R.HS_Q1)*@THR_QUART2)) AND (S.UV <= (R.HS_Q3 + ABS(R.HS_Q3-R.HS_Q1)*@THR_QUART2)) THEN 'OK' ELSE 'KO' END AS TEST_IQ2,
	CASE
		WHEN IsNull(R.HS_STDEV, 0.0)= 0.0 THEN 'NL' 
		WHEN ABS(S.UV-R.HS_MEAN)/R.HS_STDEV < @THR_AVG_ZSC THEN 'OK' ELSE 'KO' END AS TEST_ZS_AVG,
	CASE 
		WHEN IsNull(R.HS_MAD, 0.0)= 0.0 THEN 'NL' 
		WHEN ABS(S.UV-R.HS_MED)/R.HS_MAD < @THR_MED_ZSC THEN 'OK' ELSE 'KO' END AS TEST_ZS_MED,
	S.*,
	R.*
FROM SOURCE AS S
INNER JOIN MYREF AS R
ON S.FLOW=R.FLOW
AND S.YEAR=(R.YEAR+1) -- Here compare 2025 with 2024
AND S.REPORTER=R.REPORTER
AND S.PRODUCT=R.PRODUCT

WHERE (S.QSU > 10)
AND (S.VAL > 10000)
AND (

	CASE 
		WHEN IsNull(R.HS_STDEV, 0)= 0 THEN 0.0000
		ELSE ABS(S.UV-R.HS_MEAN)/R.HS_STDEV END) > @THR_AVG_ZSC

