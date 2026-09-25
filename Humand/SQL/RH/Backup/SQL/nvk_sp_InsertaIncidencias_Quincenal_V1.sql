--exec nvk_sp_InsertaIncidencias_Quincenal 'NVK',NULL,NULL,'JRIVERA4'
--update Humand set Procesado = 0, FechaProceso = NULL, UsuarioProceso = NULL WHERE PROCESADO =1
SET DATEFIRST 7
SET ANSI_NULLS OFF
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
SET LOCK_TIMEOUT -1
SET QUOTED_IDENTIFIER OFF
GO
----EXEC spALTER_TABLE 'Humand', 'Procesado', 'bit not null DEFAULT (0)'
--/*nvk_sp_InsertaIncidencias*/
IF EXISTS (SELECT 1 FROM sys.objects WHERE name = 'nvk_sp_InsertaIncidencias_Quincenal' AND type = 'P')
    DROP PROC dbo.nvk_sp_InsertaIncidencias_Quincenal
GO
CREATE PROC dbo.nvk_sp_InsertaIncidencias_Quincenal
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
		@fechaA				date

    SELECT
        @Ejercicio = YEAR(@Fecha),
        @Quincena  = CASE WHEN ISNULL(@Quincena,'') = '' THEN (MONTH(@Fecha) - 1) * 2 + CASE WHEN DAY(@Fecha) <= 15 THEN 1 ELSE 2 END
                          ELSE @Quincena END


	SELECT @FechaD = FechaDCorte, @FechaA = FechaACorte
	  FROM nvk_tb_IncidenciasQuincenal
	 WHERE Periodo = @Quincena

	/*-------------------------------------------------
	Vailda que los periodos semanales o quincenales, existan
		----------------------------------------------------*/
    --IF NOT EXISTS (SELECT 1 FROM nvk_tb_IncidenciasQuincenal WHERE Periodo = @Quincena)
    --    SELECT @Ok = 10051, @OkRef = 'El periodo Quincenal no existe por favor revisar'
    --ELSE
    --    IF NOT EXISTS (SELECT 1 FROM nvk_tb_IncidenciasSemanal WHERE Semana = @Semana)
    --        SELECT @Ok = 10051, @OkRef = 'El periodo Semanal no existe por favor revisar'

    --IF ISNULL(@Ok, '') <> ''
    --    RETURN

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
        id                  int,
        employeeId          varchar(50),
        tipoMarcaje         varchar(20),
        clasificacion       varchar(100),
        Fecha               date,
        FechaInicio         date NULL,
        FechaFin            date NULL,
        Estatus             varchar(20) NULL,
        Comentario          varchar(500) NULL,
        CapturadoPor        varchar(100) NULL,
        FechaCaptura        datetime2(7) NULL,
        HumandRequestId     int NULL
    )
	
        UPDATE a
            SET a.Procesado      = 1,
                a.FechaProceso   = @Fecha,
                a.UsuarioProceso = @Usuario
        OUTPUT  inserted.id, inserted.employeeId, inserted.tipoMarcaje, inserted.clasificacion, inserted.Fecha
            INTO #HumandProcesar (id, employeeId, tipoMarcaje, clasificacion, Fecha)
        FROM [Humand].[dbo].[Humand] a
        JOIN Personal b ON a.employeeId = b.Personal
        WHERE ISNULL(a.clasificacion, '') IN ('RETARDO_MENOR', 'RETRASO_COMIDA_MENOR', 'RETARDO_MAYOR', 'RETRASO_COMIDA_MAYOR',/*'SALIDA_ANTICIPADA',*/'FALTA','PERMISO_HORAS'/*,'REVISAR_HORARIO'*/)
          AND ISNULL(a.tipoIncidenciaAplicada, '') = ''
          AND ISNULL(a.Procesado, 0) = 0
          AND b.Estatus IN ('ALTA')
          AND b.PeriodoTipo IN ('Quincenal')
          AND b.Empresa = @Empresa
		  AND a.fecha >= @FechaD
		  AND a.fecha <= @fechaA
		  --and a.fecha >= '2026-08-10'

        SELECT @Marcados = @@ROWCOUNT
        /*
           Incidencias aprobadas sincronizadas desde Humand. Se expande cada
           rango FechaInicio-FechaFin a una fila diaria para que el cálculo
           quincenal conserve las reglas por día y por empleado.
        */
        ;WITH FechasIncidencia AS (
            SELECT
                i.id,
                i.Personal,
                i.TipoIncidencia,
                Fecha = CASE WHEN i.FechaInicio < @FechaD THEN @FechaD ELSE i.FechaInicio END,
                i.FechaInicio,
                i.FechaFin,
                i.Estatus,
                i.Comentario,
                i.CapturadoPor,
                i.FechaCaptura,
                i.HumandRequestId
            FROM [Humand].[dbo].[IncidenciaHumand] i
            JOIN Personal b ON i.Personal = b.Personal
            WHERE i.TipoIncidencia IN (
                'PERMISO_DEFUNCIÓN_FAM_DIRECTO',
                'PERMISO_DEFUNCIÓN_FAM_INDIRECTO',
                'PERMISO_PATERNIDAD',
                'TIEMPO_POR_TIEMPO_HORAS',
                'VACACIONES',
                'INCAPACIDAD_ENFERMEDAD',
                'INCAPACIDAD_ACCIDENTE'
            )
              AND i.Estatus = 'APROBADO'
              AND i.FechaFin <= @FechaA
              AND i.FechaInicio >= @FechaD
              AND b.Estatus = 'ALTA'
              AND b.PeriodoTipo = 'Quincenal'
              AND b.Empresa = @Empresa

            UNION ALL

            SELECT
                id,
                Personal,
                TipoIncidencia,
                DATEADD(DAY, 1, Fecha),
                FechaInicio,
                FechaFin,
                Estatus,
                Comentario,
                CapturadoPor,
                FechaCaptura,
                HumandRequestId
            FROM FechasIncidencia
            WHERE Fecha < FechaFin
              AND Fecha < @FechaA
        )
        INSERT INTO #HumandProcesar
            (id, employeeId, tipoMarcaje, clasificacion, Fecha,
             FechaInicio, FechaFin, Estatus, Comentario, CapturadoPor,
             FechaCaptura, HumandRequestId)
        SELECT
            id,
            Personal,
            'JUSTIFICADO',
            TipoIncidencia,
            Fecha,
            FechaInicio,
            FechaFin,
            Estatus,
            Comentario,
            CapturadoPor,
            FechaCaptura,
            HumandRequestId
        FROM FechasIncidencia
        OPTION (MAXRECURSION 0);

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
		SUM(CASE WHEN a.tipoMarcaje IN ('ENTRADA','REGRESO_COMIDA') AND a.clasificacion = 'PERMISO_HORAS'        THEN 1 ELSE 0 END) AS PermisoHoras, --ENTRADA,REGRESO_COMIDA
        SUM(CASE WHEN a.clasificacion = 'PERMISO_DEFUNCIÓN_FAM_DIRECTO'   THEN 1 ELSE 0 END) AS PermisoDefuncionFamDirecto,
        SUM(CASE WHEN a.clasificacion = 'PERMISO_DEFUNCIÓN_FAM_INDIRECTO' THEN 1 ELSE 0 END) AS PermisoDefuncionFamIndirecto,
        SUM(CASE WHEN a.clasificacion = 'PERMISO_PATERNIDAD'              THEN 1 ELSE 0 END) AS PermisoPaternidad,
        SUM(CASE WHEN a.clasificacion = 'TIEMPO_POR_TIEMPO_HORAS'         THEN 1 ELSE 0 END) AS TiempoPorTiempoHoras,
        SUM(CASE WHEN a.clasificacion = 'VACACIONES'                      THEN 1 ELSE 0 END) AS Vacaciones,
        SUM(CASE WHEN a.clasificacion = 'INCAPACIDAD_ENFERMEDAD'          THEN 1 ELSE 0 END) AS IncapacidadEnfermedad,
        SUM(CASE WHEN a.clasificacion = 'INCAPACIDAD_ACCIDENTE'           THEN 1 ELSE 0 END) AS IncapacidadAccidente--,
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
    UNPIVOT (Valor FOR TipoIncidencia IN (RetardoMenorEntrada, RetardoMenorComida, RetardoMayorEntrada,RetardoMayorComida,/*SalidasAnticipadas,*/Falta,PermisoHoras,PermisoDefuncionFamDirecto,PermisoDefuncionFamIndirecto,PermisoPaternidad,TiempoPorTiempoHoras,Vacaciones,IncapacidadEnfermedad,IncapacidadAccidente/*,RevisarHorario*/)) AS u

    /* ---------------------------------------------------------------------
        Catalogo de reglas de negocio por tipo de incidencia
          Concepto / texto base de Observaciones / umbral / si usa el
          divisor de sancion especial (4 si AplicaSancionEspecial, si no 3)
       --------------------------------------------------------------------- */
    SELECT * INTO #Reglas
    FROM (VALUES
        ('RetardoMenorEntrada',					'RetardoMenorEntrada',					'RetardoMenorEntrada',                  3, 1),
        ('RetardoMenorComida',					'Retardos Menores',						'Retardos Menores Comida Acumulados',	3, 1),
        ('RetardoMayorEntrada',					'Retardos Mayores',						'Retardos Mayor Entrada',				1, 0),
		('RetardoMayorComida',					'Retardos Mayores',						'Retardos Mayor Entrada Comida',		1, 0),
        --('SalidasAnticipadas',	    'Salida Anticipada',        'Salidas Anticipada',					1, 0),
		('Falta',								'Falta Injustificada',			        'Falta',								1, 0),
		--('Falta',								'Falta Justificada',			        'Falta',								1, 0),
        ('PermisoHoras',						'Permiso Horas',						'Permiso Horas',						1, 0),
        ('PermisoDefuncionFamDirecto',			'Permiso Defuncion',					'Permiso Defunción Fam. Directo',		1, 0),
        ('PermisoDefuncionFamIndirecto',		'Permiso Defuncion',					'Permiso Defunción Fam. Indirecto',		1, 0),
        ('PermisoPaternidad',					'Permiso Nacimiento',					'Permiso Paternidad',					1, 0),
        ('TiempoPorTiempoHoras',				'Permiso Horas',						'Tiempo por Tiempo Horas',				1, 0),
        ('Vacaciones',							'.',									'Vacaciones',							1, 0),
        ('IncapacidadEnfermedad',				'Enfermedad General Inicial',			'Incapacidad Enfermedad',				1, 0),
        ('IncapacidadAccidente',				'Enfermedad General Inicial',			'Incapacidad Accidente',				1, 0)--,
		--('RevisarHorario',		    'Revisar Horario',          'Revisar Horarios',						1, 0)
    ) AS R(TipoIncidencia,						Concepto,								ObservacionBase,				UmbralBase, UsaDivisorSancion)

    /* ---------------------------------------------------------------------
       Combinaciones a procesar: cada regla x cada tipo de periodo
          presente en #Periodos (Semanal / Quincenal)
       --------------------------------------------------------------------- */
    SELECT
        r.TipoIncidencia, r.Concepto, r.ObservacionBase, r.UmbralBase, r.UsaDivisorSancion,
        p.PeriodoTipo,
		s.Sucursal,
        PeriodoValor = @Quincena,
        Rn = ROW_NUMBER() OVER (ORDER BY r.TipoIncidencia, p.PeriodoTipo)
    INTO #Combinaciones
    FROM #Reglas r
    CROSS JOIN (SELECT DISTINCT PeriodoTipo FROM #Periodos WHERE PeriodoTipo = 'Quincenal') p
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

		--SELECT @TipoIncidencia,@Concepto,@ObservacionBase,@UmbralBase,@UsaDivisorSancion,@PeriodoTipo,@PeriodoValor,@Sucursal
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
				 @Mov = CASE @TipoIncidencia WHEN 'Falta'							THEN 'Faltas' 
											 WHEN 'Vacaciones'						THEN 'Vacaciones disfrutad'
											 WHEN 'IncapacidadEnfermedad'			THEN 'Incapacidades'
											 WHEN 'IncapacidadAccidente'			THEN 'Incapacidades'
											 WHEN 'PermisoDefuncionFamDirecto'		THEN 'Incapacidades'
											 WHEN 'PermisoDefuncionFamIndirecto'	THEN 'Incapacidades'
											 WHEN 'PermisoPaternidad'				THEN 'Incapacidades'
											 WHEN 'PermisoHoras'					THEN 'Prestacion'
											 WHEN 'TiempoPorTiempoHoras'			THEN 'Prestacion'	 
											 ELSE 'Prestacion' END
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

        SELECT 'Error al procesar incidencias: ' + ERROR_MESSAGE()		--@Ok = 99999, @OkRef = 'Error al procesar incidencias: ' + ERROR_MESSAGE()		
	END CATCH
    RETURN
END
GO

