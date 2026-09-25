--exec nvk_sp_InsertaIncidencias 'NVK',33,16,'JRIVERA4', NULL,NULL
SET DATEFIRST 7
SET ANSI_NULLS OFF
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
SET LOCK_TIMEOUT -1
SET QUOTED_IDENTIFIER OFF
GO
--EXEC spALTER_TABLE 'Humand', 'Procesado', 'bit not null DEFAULT (0)'
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Humand') AND name = 'Procesado')
    ALTER TABLE dbo.Humand ADD Procesado bit NOT NULL CONSTRAINT DF_Humand_Procesado DEFAULT (0)
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Humand') AND name = 'FechaProceso')
    ALTER TABLE dbo.Humand ADD FechaProceso datetime NULL
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Humand') AND name = 'UsuarioProceso')
    ALTER TABLE dbo.Humand ADD UsuarioProceso varchar(10) NULL
GO
/*nvk_sp_InsertaIncidencias*/
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'nvk_sp_InsertaIncidencias_Semanal' AND type = 'P')
    DROP PROC dbo.nvk_sp_InsertaIncidencias_Semanal
GO
CREATE PROC dbo.nvk_sp_InsertaIncidencias_Semanal
    @Empresa    char(5),
    @Semana     varchar(5)      NULL,
    @Quincena   varchar(5)      NULL,
	@Usuario	varchar(10)		
    --,@Ok         int             NULL,-- OUTPUT,
    --@OkRef      varchar(255)    NULL --OUTPUT
AS
BEGIN
	SET NOCOUNT ON
	SET XACT_ABORT ON -- si un statement truena dentro de la transaccion, se cancela y se hace ROLLBACK automatico

    DECLARE
        @Fecha      DATE = GETDATE(),
        @Ejercicio  int,
        @Cuantos    int = 0,
        @IDGenera   int,
		@Mov		varchar(20),
		@FechaEmision	DATE,
		    -- Nuevas variables auxiliares
		@PrimerDiaSemana    DATE,
		@PrimerDiaQuincena  DATE,
		@PrimerSemana       DATE,
		@PrimerLunes        DATE,
        @UltimoViernes		DATE,
		@Marcados			int = 0,
		@FechaD				date,
		@FechaA				date

    SELECT
        @Ejercicio = YEAR(@Fecha),
        @Semana    = CASE WHEN ISNULL(@Semana,'')   = '' THEN (DATEPART(ISO_WEEK, @Fecha) - 1) ELSE @Semana END

	SELECT @FechaD = FechaDCorte, @FechaA = FechaACorte
	  FROM nvk_tb_IncidenciasSemanal
	 WHERE Semana = @Semana

	/*-------------------------------------------------
	Se calculan los primeros días de la semana y de la quincena,
	para la fecha de emisión de los movimientos
		----------------------------------------------------*/

	SET @PrimerSemana = DATEFROMPARTS(@Ejercicio, 1, 4);

	-- Retrocedemos hasta el lunes de esa semana, sin depender de @@DATEFIRST
	SET @PrimerLunes = DATEADD(DAY,
							1 - ((DATEPART(WEEKDAY, @PrimerSemana) + @@DATEFIRST - 2) % 7 + 1),
							@PrimerSemana);

	SET @PrimerDiaSemana = DATEADD(WEEK, CAST(@Semana AS int) - 1, @PrimerLunes)

	-- =========================================================
	-- 2) Primer día de la QUINCENA
	-- =========================================================
	-- Quincenas impares (1,3,5,...) inician el día 1 del mes
	-- Quincenas pares  (2,4,6,...) inician el día 16 del mes
	SET @PrimerDiaQuincena = DATEFROMPARTS(
			@Ejercicio,
			CEILING(CAST(@Quincena AS int) / 2.0),
			CASE WHEN CAST(@Quincena AS int) % 2 = 1 THEN 1 ELSE 16 END
		)

	/* ---------------------------------------------------------------------
		  Se calcula el viernes previo al día de trabajo para determinar si se procesa
		  el periodo quincenal
		   --------------------------------------------------------------------- */
	DECLARE @DiaSemanaNorm int = (DATEPART(WEEKDAY, @Fecha) + @@DATEFIRST - 2) % 7 + 1
	SET @UltimoViernes = DATEADD(DAY,
        -(((@DiaSemanaNorm - 5 + 7) % 7) + CASE WHEN @DiaSemanaNorm = 5 THEN 7 ELSE 0 END),
        @Fecha)
    /* ---------------------------------------------------------------------
      Periodos unificados (Semanal + Quincenal en una sola tabla)
       --------------------------------------------------------------------- */
    SELECT
					PeriodoTipo            ='Quincenal', 
					PeriodoValor            =	CONVERT(varchar(5), Periodo), 
					FechaDCorte, 
					FechaACorte,
					FechaPago,
					AplicaSancionEspecial
    INTO #Periodos
    FROM nvk_tb_IncidenciasQuincenal

    INSERT INTO #Periodos 
			(PeriodoTipo, 
			PeriodoValor, 
			FechaDCorte, 
			FechaACorte,
			FechaPago,
			AplicaSancionEspecial)
    SELECT 'Semanal',
        CONVERT(varchar(5), Semana),
        FechaDCorte, FechaACorte, FechaPago,AplicaSancionEspecial
    FROM nvk_tb_IncidenciasSemanal

	/*---------------------------------------------------------------------
	Actualización de registros procesados
	---------------------------------------------------------------------*/

	BEGIN TRY
		BEGIN TRAN
		--SELECT TOP 0 id, employeeId, tipoMarcaje, clasificacion, Fecha
  --      INTO #HumandProcesar
  --      FROM Humand


	CREATE TABLE #HumandProcesar (
	id						int, 
	employeeId				varchar(50), 
	tipoMarcaje				varchar(20), 
	clasificacion			varchar(100), 
	Fecha					date
	)
        UPDATE a
            SET a.Procesado      = 1,
                a.FechaProceso   = @Fecha,
                a.UsuarioProceso = @Usuario
        OUTPUT  inserted.id, inserted.employeeId, inserted.tipoMarcaje, inserted.clasificacion, inserted.Fecha
            INTO #HumandProcesar (id, employeeId, tipoMarcaje, clasificacion, Fecha)
        FROM Humand a
        JOIN Personal b ON a.employeeId = b.Personal
        WHERE ISNULL(a.clasificacion, '') IN ('RETARDO_MENOR', 'RETRASO_COMIDA_MENOR', 'RETARDO_MAYOR', 'RETRASO_COMIDA_MAYOR',/*'SALIDA_ANTICIPADA',*/'FALTA','PERMISO_HORAS'/*,'REVISAR_HORARIO'*/)
          AND ISNULL(a.tipoIncidenciaAplicada, '') = ''
          AND ISNULL(a.Procesado, 0) = 0
          AND b.Estatus IN ('ALTA')
          AND b.PeriodoTipo IN ('Semanal')
          AND b.Empresa = @Empresa
		  AND a.fecha >= @FechaD
		  AND a.fecha <= @FechaA
		  --and a.fecha >= '2026-08-10'

        SELECT @Marcados = @@ROWCOUNT




    SELECT
        b.Personal,
        b.PeriodoTipo,
        b.Empresa,
        a.Fecha,
		b.Categoria,
		b.Departamento,
		b.SucursalTrabajo,
        SUM(CASE WHEN a.tipoMarcaje = 'ENTRADA'        AND a.clasificacion = 'RETARDO_MENOR'          THEN 1 ELSE 0 END) AS RetardoMenorEntrada, --RETARDO_MENOR
        SUM(CASE WHEN a.tipoMarcaje = 'REGRESO_COMIDA' AND a.clasificacion = 'RETRASO_COMIDA_MENOR'    THEN 1 ELSE 0 END) AS RetardoMenorComida, --RETRASO_COMIDA_MENOR
        SUM(CASE WHEN a.tipoMarcaje = 'ENTRADA'        AND a.clasificacion = 'RETARDO_MAYOR'           THEN 1 ELSE 0 END) AS RetardoMayorEntrada,  ----RETARDO_MAYOR
        SUM(CASE WHEN a.tipoMarcaje = 'REGRESO_COMIDA' AND a.clasificacion = 'RETRASO_COMIDA_MAYOR'     THEN 1 ELSE 0 END) AS RetardoMayorComida, --RETRASO_COMIDA_MAYOR
        --SUM(CASE WHEN a.tipoMarcaje = 'SALIDA'         AND a.clasificacion = 'SALIDA_ANTICIPADA'        THEN 1 ELSE 0 END) AS SalidasAnticipadas,	--SALIDA_ANTICIPADA
		SUM(CASE WHEN a.tipoMarcaje = 'FALTA'          AND a.clasificacion = 'FALTA'        THEN 1 ELSE 0 END) AS Falta, --FALTA
		SUM(CASE WHEN a.tipoMarcaje IN ('ENTRADA','REGRESO_COMIDA') AND a.clasificacion = 'PERMISO_HORAS'        THEN 1 ELSE 0 END) AS PermisoHoras--, --ENTRADA,REGRESO_COMIDA
		--SUM(CASE WHEN a.tipoMarcaje IN ('REGRESO_COMIDA','SALIDA','ENTRADA') AND a.clasificacion = 'REVISAR_HORARIO'        THEN 1 ELSE 0 END) AS RevisarHorario --REGRESO_COMIDA,SALIDA,ENTRADA
    INTO #Incidencias
    FROM #HumandProcesar a
	JOIN Personal b ON a.employeeId = b.Personal
   GROUP BY b.Departamento,b.SucursalTrabajo,b.Categoria,b.Personal, b.PeriodoTipo, b.Empresa, a.Fecha

    /* ---------------------------------------------------------------------
       Detalle aplanado (una fila por Personal/Fecha/TipoIncidencia)
       --------------------------------------------------------------------- */
    SELECT Personal, PeriodoTipo, Fecha, TipoIncidencia,SucursalTrabajo,Categoria, Valor
    INTO #Detalle
    FROM #Incidencias
    UNPIVOT (Valor FOR TipoIncidencia IN (RetardoMenorEntrada, RetardoMenorComida, RetardoMayorEntrada,RetardoMayorComida,/*SalidasAnticipadas,*/Falta,PermisoHoras/*,RevisarHorario*/)) AS u

    /* ---------------------------------------------------------------------
        Catalogo de reglas de negocio por tipo de incidencia
          Concepto / texto base de Observaciones / umbral / si usa el
          divisor de sancion especial (4 si AplicaSancionEspecial, si no 3)
       --------------------------------------------------------------------- */
    SELECT * INTO #Reglas
    FROM (VALUES
        ('RetardoMenorEntrada',     'RetardoMenorEntrada',      'RetardoMenorEntrada',                  3, 1),
        ('RetardoMenorComida',      'Retardos Menores',         'Retardos Menores Comida Acumulados',	3, 1),
        ('RetardoMayorEntrada',     'Retardos Mayores',         'Retardos Mayor Entrada',				1, 0),
		('RetardoMayorComida',	    'Retardos Mayores',         'Retardos Mayor Entrada Comida',		1, 0),
        --('SalidasAnticipadas',	    'Salida Anticipada',        'Salidas Anticipada',					1, 0),
		('Falta',				    'Falta Injustificada',			        'Falta',								1, 0),
		('Falta',				    'Falta Justificada',			        'Falta',								1, 0),
		('PermisoHoras',		    'Permiso Horas',         'Permiso Horas',						1, 0)--,
		--('RevisarHorario',		    'Revisar Horario',          'Revisar Horarios',						1, 0)
    ) AS R(TipoIncidencia, Concepto, ObservacionBase, UmbralBase, UsaDivisorSancion)

    /* ---------------------------------------------------------------------
       Combinaciones a procesar: cada regla x cada tipo de periodo
          presente en #Periodos (Semanal / Quincenal)
       --------------------------------------------------------------------- */
    SELECT
        r.TipoIncidencia, r.Concepto, r.ObservacionBase, r.UmbralBase, r.UsaDivisorSancion,
        p.PeriodoTipo,
		s.Sucursal,
        PeriodoValor = @Semana,
        Rn = ROW_NUMBER() OVER (ORDER BY r.TipoIncidencia, p.PeriodoTipo)
    INTO #Combinaciones
    FROM #Reglas r
    CROSS JOIN (SELECT DISTINCT PeriodoTipo FROM #Periodos WHERE PeriodoTipo = 'Semanal') p
	CROSS JOIN (SELECT DISTINCT Sucursal FROM Sucursal WHERE Estatus = 'ALTA' AND Sucursal NOT IN (99,999)) S

    DECLARE @Total int = (SELECT COUNT(*) FROM #Combinaciones), @i int = 1 --Agregar NULL en el where de combinaciones ???
    DECLARE
        @Id					int,
		@TipoIncidencia     varchar(30),
        @Concepto           varchar(50),
        @ObservacionBase    varchar(100),
        @Observaciones      varchar(255),
        @UmbralBase         int,
        @UsaDivisorSancion  bit,
        @PeriodoTipo        varchar(20),
        @PeriodoValor       varchar(5),
		@Sucursal			int

    /* ---------------------------------------------------------------------
      Bloque UNICO de insercion Nomina/NominaD, ejecutado una vez por
          combinacion (antes este bloque estaba repetido 6 veces en el SP)
       --------------------------------------------------------------------- */
    WHILE @i <= @Total
    BEGIN

		/* ----------------------------------------------------------------
			Se llenan las variables para recorrerlas con el While
		---------------------------------------------------------------- */
        SELECT
            @TipoIncidencia		= TipoIncidencia, 
			@Concepto			= Concepto, 
			@ObservacionBase	= ObservacionBase,
            @UmbralBase			= UmbralBase, 
			@UsaDivisorSancion	= UsaDivisorSancion,
            @PeriodoTipo		= PeriodoTipo, 
			@PeriodoValor		= PeriodoValor,
			@Sucursal			= Sucursal
        FROM #Combinaciones
        WHERE Rn = @i


		--exec nvk_sp_InsertaIncidencias_Semanal 'NVK',NULL,NULL,'JRIVERA4'
		--update Humand set Procesado = 0, FechaProceso = NULL, UsuarioProceso = NULL WHERE PROCESADO =1

		/*----------------------------------------------------------------
			Se valida que existan registros por procesar en cada tipo
			de incidencia
		------------------------------------------------------------------*/

        IF EXISTS (
            SELECT 1
            FROM #Detalle d
            JOIN #Periodos p ON p.PeriodoTipo = d.PeriodoTipo
                             AND d.Fecha >= p.FechaDCorte AND d.Fecha <= p.FechaACorte
            WHERE d.PeriodoTipo = @PeriodoTipo
              AND d.TipoIncidencia = @TipoIncidencia
              AND p.PeriodoValor = ISNULL(@PeriodoValor, p.PeriodoValor)
              AND d.Valor >= @UmbralBase
			  AND d.SucursalTrabajo = @Sucursal
        )
        BEGIN
            SELECT @Observaciones = @ObservacionBase + ' '
                 + CASE @PeriodoTipo WHEN 'Semanal ' THEN 'Semana ' ELSE 'Quincena ' END
                 + @PeriodoValor,
				 @Mov = CASE @TipoIncidencia WHEN 'Falta' THEN 'Faltas' ELSE 'Prestacion' END
				 ,@FechaEmision = CASE @PeriodoTipo WHEN 'Semanal ' THEN  @PrimerDiaSemana ELSE @PrimerDiaQuincena END

            INSERT INTO Nomina
              (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota,
              OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)
            VALUES
              (@Empresa, @Mov, NULL, @FechaEmision, @Fecha, @Concepto, NULL, 'Pesos', 1, @Usuario, NULL, NULL, @Observaciones, 'SINAFECTAR', NULL, NULL, NULL, NULL,
              NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, @Sucursal, @Sucursal, NULL, @FechaEmision, 0, @PeriodoTipo, @PeriodoValor)

            SELECT @IDGenera = SCOPE_IDENTITY()

            INSERT INTO NominaD
                  (ID, Renglon, Modulo, Personal, Horas, Cantidad, Referencia, FechaD, Activo, Sucursal, SucursalOrigen)
            SELECT
                @IDGenera,
                ROW_NUMBER() OVER (ORDER BY d.Personal) * 2048,
                'NOM',
                d.Personal,
                '01:00',
                SUM(CASE WHEN @UsaDivisorSancion = 1
                         THEN d.Valor / CASE WHEN p.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END
                         ELSE d.Valor END),
                CONVERT(varchar(50), d.Fecha),
                @Fecha,
                1, 0, 0
            FROM #Detalle d
            JOIN #Periodos p ON p.PeriodoTipo = d.PeriodoTipo
                             AND d.Fecha >= p.FechaDCorte AND d.Fecha <= p.FechaACorte
            WHERE d.PeriodoTipo = @PeriodoTipo
              AND d.TipoIncidencia = @TipoIncidencia
              AND d.Valor >= CASE WHEN @UsaDivisorSancion = 1
                                   THEN CASE WHEN p.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END
                                   ELSE @UmbralBase END
              AND d.Personal IS NOT NULL
              AND p.PeriodoValor = ISNULL(@PeriodoValor, p.PeriodoValor)
			  AND d.SucursalTrabajo = @Sucursal
			  AND d.Categoria = CASE WHEN d.TipoIncidencia IN  ('RetardoMayorEntrada','RetardoMayorComida') THEN 'Confianza A' ELSE d.Categoria END
            GROUP BY d.Personal, d.Fecha

            SELECT @Cuantos = @Cuantos + 1
        END

        SELECT @i = @i + 1
    END

	COMMIT TRAN

    --SELECT @Ok = 20515, @OkRef = 'Se generaron ' + TRIM(CONVERT(char, @Cuantos)) + ' Movimientos'
	SELECT 'Se generaron ' + TRIM(CONVERT(char, @Cuantos)) + ' Movimientos'

	END TRY
	BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRAN  -- deshace tambien el marcado de Procesado en Humand: las filas quedan disponibles para el siguiente intento

        SELECT 'Error al procesar incidencias: ' + ERROR_MESSAGE() --@Ok = 99999, @OkRef = 'Error al procesar incidencias: ' + ERROR_MESSAGE()		
	END CATCH
    RETURN
END
GO