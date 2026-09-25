USE 
NAVILUX
GO
/* =====================================================================
   Migraci�n para dbo.nvk_sp_InsertaIncidencias
   Ejecutar UNA vez en la base Humand, ANTES de crear el procedimiento.
   Es re-ejecutable: cada cambio verifica si ya existe.
   ===================================================================== */
--USE Humand
--GO
--SET ANSI_NULLS ON
--SET QUOTED_IDENTIFIER ON
--GO

--/* ---------------------------------------------------------------------
--   1) dbo.Humand: columnas de control (Procesado/FechaProceso/UsuarioProceso
--      ya las usa el SP anterior; se agregan solo si faltan) + NominaID
--   --------------------------------------------------------------------- */
--IF COL_LENGTH('dbo.Humand', 'Procesado') IS NULL
--    ALTER TABLE dbo.Humand ADD Procesado bit NOT NULL CONSTRAINT DF_Humand_Procesado DEFAULT (0)
--IF COL_LENGTH('dbo.Humand', 'FechaProceso') IS NULL
--    ALTER TABLE dbo.Humand ADD FechaProceso date NULL
--IF COL_LENGTH('dbo.Humand', 'UsuarioProceso') IS NULL
--    ALTER TABLE dbo.Humand ADD UsuarioProceso varchar(10) NULL
--IF COL_LENGTH('dbo.Humand', 'NominaID') IS NULL
--    ALTER TABLE dbo.Humand ADD NominaID int NULL          -- ID del movimiento de Nomina que lo incluy�
--GO

--IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_Humand_fecha_Procesado' AND object_id = OBJECT_ID('dbo.Humand'))
--    CREATE INDEX IX_Humand_fecha_Procesado ON dbo.Humand (fecha, Procesado)
--        INCLUDE (employeeId, tipoMarcaje, clasificacion, minutosDesviacion, tipoIncidenciaAplicada)
--GO

--/* ---------------------------------------------------------------------
--   2) dbo.IncidenciaHumand: mismas columnas de control que Humand
--   --------------------------------------------------------------------- */
--IF COL_LENGTH('dbo.IncidenciaHumand', 'Procesado') IS NULL
--    ALTER TABLE dbo.IncidenciaHumand ADD Procesado bit NOT NULL CONSTRAINT DF_IncidenciaHumand_Procesado DEFAULT (0)
--IF COL_LENGTH('dbo.IncidenciaHumand', 'FechaProceso') IS NULL
--    ALTER TABLE dbo.IncidenciaHumand ADD FechaProceso date NULL
--IF COL_LENGTH('dbo.IncidenciaHumand', 'UsuarioProceso') IS NULL
--    ALTER TABLE dbo.IncidenciaHumand ADD UsuarioProceso varchar(10) NULL
--GO

--/* ---------------------------------------------------------------------
--   3) Detalle por d�a de incidencias enviadas a N�mina.
--      Una incidencia (ej. vacaciones del mi�rcoles al martes) puede
--      procesarse en dos periodos distintos; la llave �nica evita que un
--      mismo d�a se env�e dos veces.
--   --------------------------------------------------------------------- */
--USE Humand
--GO
--IF OBJECT_ID('dbo.IncidenciaHumandProcesada', 'U') IS NULL
--BEGIN
--    CREATE TABLE dbo.IncidenciaHumandProcesada (
--        id              int IDENTITY(1,1) PRIMARY KEY,
--        IncidenciaId    int          NOT NULL,     -- dbo.IncidenciaHumand.id
--        Fecha           date         NOT NULL,
--        Personal        varchar(50)  NOT NULL,
--        TipoIncidencia  varchar(50)  NULL,
--        PeriodoTipo     varchar(10)  NOT NULL,     -- Semanal | Quincenal
--        Periodo         varchar(5)   NOT NULL,
--        NominaID        int          NULL,         -- movimiento de Nomina (base de la empresa)
--        FechaProceso    datetime2(0) NOT NULL CONSTRAINT DF_IncidenciaHumandProcesada_Fecha DEFAULT (GETDATE()),
--        UsuarioProceso  varchar(10)  NULL,
--        CONSTRAINT UQ_IncidenciaHumandProcesada UNIQUE (IncidenciaId, Fecha)
--    )
--    CREATE INDEX IX_IncidenciaHumandProcesada_Nomina ON dbo.IncidenciaHumandProcesada (NominaID)
--END
--GO
--select * from IncidenciaHumandProcesada
--TRUNCATE TABLE IncidenciaHumandProcesada

/* =====================================================================
   4) OBLIGATORIO antes de la primera corrida: registrar como procesadas
      las incidencias que el SP anterior YA mand� a N�mina.
      El SP anterior no marcaba IncidenciaHumand; sin este paso, el nuevo
      volver�a a generar esas vacaciones/incapacidades.

      Ajusta las dos fechas de corte: el �ltimo d�a del �ltimo periodo
      SEMANAL y QUINCENAL que ya se proces� con el SP anterior.
      Nota: el SP anterior solo tomaba incidencias completas dentro del
      periodo; las que cruzaban periodos NO se enviaron. Revisa esas
      aparte (consulta de la secci�n 5) antes de marcarlas.
   ===================================================================== */
/*
DECLARE @CorteSemanal   date = '2026-09-20',   -- <-- ajustar
        @CorteQuincenal date = '2026-09-10'    -- <-- ajustar

;WITH Dias AS (
    SELECT i.id, i.Personal, i.TipoIncidencia, Fecha = i.FechaInicio, i.FechaFin
      FROM dbo.IncidenciaHumand i
     WHERE i.Estatus = 'APROBADO'
    UNION ALL
    SELECT id, Personal, TipoIncidencia, DATEADD(DAY, 1, Fecha), FechaFin
      FROM Dias
     WHERE Fecha < FechaFin
)
INSERT INTO dbo.IncidenciaHumandProcesada
      (IncidenciaId, Fecha, Personal, TipoIncidencia, PeriodoTipo, Periodo, NominaID, UsuarioProceso)
SELECT d.id, d.Fecha, d.Personal, d.TipoIncidencia, p.PeriodoTipo, 'MIGR', NULL, 'MIGRACION'
  FROM Dias d
  JOIN <BaseEmpresa>.dbo.Personal p ON p.Personal = d.Personal      -- <-- base de Intelisis (ej. NAVILUX)
 WHERE d.Fecha <= CASE p.PeriodoTipo WHEN 'Semanal' THEN @CorteSemanal ELSE @CorteQuincenal END
   AND NOT EXISTS (SELECT 1 FROM dbo.IncidenciaHumandProcesada x WHERE x.IncidenciaId = d.id AND x.Fecha = d.Fecha)
OPTION (MAXRECURSION 0)

UPDATE i
   SET Procesado = CASE WHEN x.Dias >= DATEDIFF(DAY, i.FechaInicio, i.FechaFin) + 1 THEN 1 ELSE 0 END,
       FechaProceso = CAST(GETDATE() AS date), UsuarioProceso = 'MIGRACION'
  FROM dbo.IncidenciaHumand i
  JOIN (SELECT IncidenciaId, Dias = COUNT(*) FROM dbo.IncidenciaHumandProcesada GROUP BY IncidenciaId) x
    ON x.IncidenciaId = i.id
*/

/* =====================================================================
   5) OPCIONAL: liberar checadas que el SP anterior marc� como procesadas
      SIN generar movimiento, para que el nuevo las pueda reprocesar.
        - Retardos menores (entrada y comida): nunca llegaban al umbral.
      NO se liberan FALTA ni RETARDO_MAYOR de comida: esos s� generaron
      movimiento (las faltas incluso dos veces: revisa en Intelisis los
      movimientos 'Falta Justificada' duplicados y canc�lalos).
      Ajusta el rango de fechas a los periodos que quieras recalcular.
   ===================================================================== */
/*
DECLARE @Desde date = '2026-08-01', @Hasta date = '2026-09-20'   -- <-- ajustar

-- Vista previa
SELECT clasificacion, tipoMarcaje, Registros = COUNT(*)
  FROM dbo.Humand
 WHERE Procesado = 1 AND NominaID IS NULL
   AND fecha BETWEEN @Desde AND @Hasta
   AND LEFT(ISNULL(clasificacion, ''), CHARINDEX('|', ISNULL(clasificacion, '') + '|') - 1)
       IN ('RETARDO_MENOR', 'RETRASO_COMIDA_MENOR')
 GROUP BY clasificacion, tipoMarcaje

-- Liberar
UPDATE dbo.Humand
   SET Procesado = 0, FechaProceso = NULL, UsuarioProceso = NULL
 WHERE Procesado = 1 AND NominaID IS NULL
   AND fecha BETWEEN @Desde AND @Hasta
   AND LEFT(ISNULL(clasificacion, ''), CHARINDEX('|', ISNULL(clasificacion, '') + '|') - 1)
       IN ('RETARDO_MENOR', 'RETRASO_COMIDA_MENOR')

-- Incidencias que cruzaban periodos y el SP anterior ignor� (revisar antes del paso 4)
SELECT i.*
  FROM dbo.IncidenciaHumand i
 WHERE i.Estatus = 'APROBADO' AND i.FechaInicio <= @Hasta AND i.FechaFin >= @Desde
   AND DATEDIFF(DAY, i.FechaInicio, i.FechaFin) >= 1
 ORDER BY i.FechaInicio


USE [NAVILUX]
GO
DROP TABLE [dbo].[nvk_tb_IncidenciasQuincenal]
GO
/****** Object:  Table [dbo].[nvk_tb_IncidenciasQuincenal]    Script Date: 09/25/2026 02:27:16 PM ******/
SET ANSI_NULLS OFF
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[nvk_tb_IncidenciasQuincenal](
	[Id] [int] IDENTITY(1,1) NOT NULL,
	[Ejercicio] [int] NOT NULL,
	[Quincena] [varchar](5) NOT NULL,
	[PeriodoDescripcion] [varchar](100) NOT NULL,
	[FechaDCorte] [date] NOT NULL,
	[FechaACorte] [date] NOT NULL,
	[FechaPago] [date] NOT NULL,
	[AplicaSancionEspecial] [bit] NULL,
	[Periodo] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[Id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 90, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[nvk_tb_IncidenciasQuincenal] ADD  DEFAULT ((0)) FOR [AplicaSancionEspecial]
GO

INSERT INTO [NAVILUX].[dbo].[nvk_tb_IncidenciasQuincenal] 
SELECT Ejercicio,
Quincena,
PeriodoDescripcion,
FechaDCorte,
FechaACorte,
FechaPago,
AplicaSancionEspecial,
Periodo
FROM NVTEST.DBO.nvk_tb_IncidenciasQuincenal
*/

SET DATEFIRST 7
SET ANSI_NULLS OFF
SET QUOTED_IDENTIFIER OFF
GO
IF OBJECT_ID('dbo.nvk_sp_InsertaIncidencias', 'P') IS NOT NULL
    DROP PROC dbo.nvk_sp_InsertaIncidencias
GO
CREATE PROC dbo.nvk_sp_InsertaIncidencias
    @Empresa        char(5),
    @PeriodoTipo    varchar(10),            -- 'Semanal' | 'Quincenal'
    @Periodo        varchar(5)  = NULL,     -- NULL/'' = último periodo ya cerrado
    @Usuario        varchar(10),
    @Simular        bit         = 0         -- 1 = solo muestra lo que generaría y hace ROLLBACK
AS
BEGIN
    SET NOCOUNT ON
    SET XACT_ABORT ON

    DECLARE
        @Hoy                date = CAST(GETDATE() AS date),
        @PeriodoSolicitado  varchar(5),
        @FechaD             date,
        @FechaA             date,
        @AplicaSancion      bit,
        @Etiqueta           varchar(20),
        @FechaEmision       date,
        @ToleranciaMin      int = 10,
        @BloqueMin          int = 10,
        @Movimientos        int = 0,
        @EsperadosHumand    int = 0,
        @MarcadosHumand     int = 0,
        @DiasIncidencia     int = 0,
        @IncidenciasCerradas int = 0,
        @Lock               int,
        @Recurso            nvarchar(255),
        @Msg                nvarchar(2048)

    /* -----------------------------------------------------------------
       1) Validación de parámetros y resolución del periodo
       ----------------------------------------------------------------- */
    SET @PeriodoTipo = CASE UPPER(LTRIM(RTRIM(ISNULL(@PeriodoTipo, ''))))
                            WHEN 'SEMANAL'   THEN 'Semanal'
                            WHEN 'QUINCENAL' THEN 'Quincenal'
                       END
    IF @PeriodoTipo IS NULL
    BEGIN
        ;THROW 50001, N'@PeriodoTipo debe ser ''Semanal'' o ''Quincenal''.', 1
    END

    SET @PeriodoSolicitado = NULLIF(LTRIM(RTRIM(@Periodo)), '')

    -- Sin periodo explícito: el último periodo cuyo corte ya pasó.
    -- Con periodo explícito: la ocurrencia más reciente de ese número que ya
    -- inició (las tablas de calendario no tienen columna de año).
    IF @PeriodoTipo = 'Semanal'
        SELECT TOP 1
               @Periodo       = CONVERT(varchar(5), Semana),
               @FechaD        = FechaDCorte,
               @FechaA        = FechaACorte,
               @AplicaSancion = ISNULL(AplicaSancionEspecial, 0)
          FROM nvk_tb_IncidenciasSemanal
         WHERE (@PeriodoSolicitado IS NULL AND FechaACorte < @Hoy)
            OR (@PeriodoSolicitado IS NOT NULL AND Semana = @PeriodoSolicitado AND FechaDCorte <= @Hoy)
         ORDER BY FechaACorte DESC
    ELSE
        SELECT TOP 1
               @Periodo       = CONVERT(varchar(5), Periodo),
               @FechaD        = FechaDCorte,
               @FechaA        = FechaACorte,
               @AplicaSancion = ISNULL(AplicaSancionEspecial, 0)
          FROM nvk_tb_IncidenciasQuincenal
         WHERE (@PeriodoSolicitado IS NULL AND FechaACorte < @Hoy)
            OR (@PeriodoSolicitado IS NOT NULL AND Periodo = @PeriodoSolicitado AND FechaDCorte <= @Hoy)
         ORDER BY FechaACorte DESC

    IF @FechaD IS NULL OR @FechaA IS NULL
    BEGIN
        SET @Msg = N'No se encontró el periodo ' + @PeriodoTipo + N' ' + ISNULL(@PeriodoSolicitado, N'(último cerrado)')
                 + N' en el calendario de incidencias.'
        ;THROW 50002, @Msg, 1
    END

    -- Un periodo abierto marcaría retardos/faltas incompletos como procesados.
    IF @FechaA >= @Hoy
    BEGIN
        SET @Msg = N'El periodo ' + @PeriodoTipo + N' ' + @Periodo + N' todavía no cierra (corte al '
                 + CONVERT(nvarchar(10), @FechaA, 23) + N'). Ejecútalo a partir del día siguiente al corte.'
        ;THROW 50003, @Msg, 1
    END

    SET @Etiqueta = CASE @PeriodoTipo WHEN 'Semanal' THEN 'Semana ' ELSE 'Quincena ' END + @Periodo

    -- Fecha de emisión: semanal = inicio del corte; quincenal = día 1 o 16 del mes de la quincena
    -- (misma regla que el SP quincenal anterior, pero con el año del corte y no el de GETDATE()).
    SET @FechaEmision = CASE @PeriodoTipo
                            WHEN 'Semanal' THEN @FechaD
                            ELSE DATEFROMPARTS(YEAR(@FechaA),
                                               CEILING(CAST(@Periodo AS int) / 2.0),
                                               CASE WHEN CAST(@Periodo AS int) % 2 = 1 THEN 1 ELSE 16 END)
                        END

    BEGIN TRY
        BEGIN TRAN

        -- Evita que dos usuarios procesen la misma empresa/tipo de nómina al mismo tiempo
        SET @Recurso = N'nvk_sp_InsertaIncidencias|' + RTRIM(@Empresa) + N'|' + @PeriodoTipo
        EXEC @Lock = sp_getapplock @Resource = @Recurso, @LockMode = 'Exclusive',
                                   @LockOwner = 'Transaction', @LockTimeout = 0
        IF @Lock < 0
        BEGIN
            ;THROW 50004, N'Ya hay otro proceso de incidencias en ejecución para esta empresa y tipo de nómina.', 1
        END

        /* -------------------------------------------------------------
           2) Días del periodo y empleados elegibles
           ------------------------------------------------------------- */
        ;WITH D AS (
            SELECT Fecha = @FechaD
            UNION ALL
            SELECT DATEADD(DAY, 1, Fecha) FROM D WHERE Fecha < @FechaA
        )
        SELECT Fecha INTO #Dias FROM D OPTION (MAXRECURSION 400)

        SELECT p.Personal,
               p.Categoria,
               p.SucursalTrabajo,
               EsSindicalizado = CASE WHEN UPPER(LTRIM(RTRIM(ISNULL(p.Sindicato, '')))) = 'SINDICALIZADO' THEN 1 ELSE 0 END
          INTO #Emp
          FROM Personal p
          JOIN Sucursal s ON s.Sucursal = p.SucursalTrabajo
                         AND s.Estatus = 'ALTA'
                         AND s.Sucursal NOT IN (99, 999)
         WHERE p.Estatus = 'ALTA'
           AND p.PeriodoTipo = @PeriodoTipo
           AND p.Empresa = @Empresa

        /* -------------------------------------------------------------
           3) Catálogo de reglas de negocio
              Umbral            : mínimo del total del grupo para generar línea
              UsaDivisorSancion : Cantidad = Total / 3 (o / 4 si el periodo
                                  AplicaSancionEspecial); el divisor es el umbral
              AcumulaPeriodo    : 1 = una línea por empleado y periodo
                                  0 = una línea por empleado y día
              SoloCategoria     : si no es NULL, solo aplica a esa categoría
              Activa            : 0 = no genera ni marca nada
           ------------------------------------------------------------- */
        CREATE TABLE #Reglas (
            Regla               varchar(30)  NOT NULL PRIMARY KEY,
            Mov                 varchar(20)  NOT NULL,
            Concepto            varchar(50)  NOT NULL,
            ObservacionBase     varchar(100) NOT NULL,
            Umbral              int          NOT NULL,
            UsaDivisorSancion   bit          NOT NULL,
            AcumulaPeriodo      bit          NOT NULL,
            SoloCategoria       varchar(50)  NULL,
            Activa              bit          NOT NULL
        )
        INSERT INTO #Reglas (Regla, Mov, Concepto, ObservacionBase, Umbral, UsaDivisorSancion, AcumulaPeriodo, SoloCategoria, Activa)
        VALUES
        -- Regla                          Mov                     Concepto                      ObservacionBase                        Umb Div Acu  SoloCategoria  Activa
        ('RetardoMenorEntrada',           'Prestacion',           'Retardos Menores',        'RetardoMenorEntrada',                 3,  1,  1,   NULL,          1),
        ('RetardoMenorComida',            'Prestacion',           'Retardos Menores',           'Retardos Menores Comida Acumulados',  3,  1,  1,   NULL,          1),
        ('RetardoMayorEntrada',           'Prestacion',           'Retardos Mayores',           'Retardos Mayor Entrada',              1,  0,  0,   'Confianza A', 0),  -- inactiva, igual que en la versión anterior
        ('RetardoMayorComida',            'Prestacion',           'Retardos Mayores',           'Retardos Mayor Entrada Comida',       1,  0,  0,   'Confianza A', 1),
        ('Falta',                         'Faltas',               'Falta Injustificada',        'Falta',                               1,  0,  0,   NULL,          1),
        ('PermisoHoras',                  'Prestacion',           'Permiso Horas',              'Permiso Horas',                       1,  0,  0,   NULL,          1),
        ('PermisoDefuncionFamDirecto',    'Incapacidades',        'Permiso Defuncion',          'Permiso Defunción Fam. Directo',      1,  0,  0,   NULL,          1),
        ('PermisoDefuncionFamIndirecto',  'Incapacidades',        'Permiso Defuncion',          'Permiso Defunción Fam. Indirecto',    1,  0,  0,   NULL,          1),
        ('PermisoPaternidad',             'Incapacidades',        'Permiso Nacimiento',         'Permiso Paternidad',                  1,  0,  0,   NULL,          1),
        ('TiempoPorTiempoHoras',          'Prestacion',           'Permiso Horas',              'Tiempo por Tiempo Horas',             1,  0,  0,   NULL,          1),
        ('Vacaciones',                    'Vacaciones disfrutad', '.',                          'Vacaciones',                          1,  0,  0,   NULL,          1),
        ('IncapacidadEnfermedad',         'Incapacidades',        'Enfermedad General Inicial', 'Incapacidad Enfermedad',              1,  0,  0,   NULL,          1),
        ('IncapacidadAccidente',          'Incapacidades',        'Enfermedad General Inicial', 'Incapacidad Accidente',               1,  0,  0,   NULL,          1),
        ('UnidadesSindicalizado',         'Prestacion',           'Permiso Horas',              'Unidades Retardo Sindicalizados',     1,  0,  1,   NULL,          1)

        /* -------------------------------------------------------------
           4) Registros fuente (una fila por unidad a evaluar)
           ------------------------------------------------------------- */
        CREATE TABLE #Fuente (
            Origen          char(1)      NOT NULL,   -- 'H' = Humand, 'I' = IncidenciaHumand
            SourceId        int          NOT NULL,
            Personal        varchar(50)  NOT NULL,
            Fecha           date         NOT NULL,
            Regla           varchar(30)  NOT NULL,
            Valor           int          NOT NULL,
            SucursalTrabajo int          NULL,
            Categoria       varchar(50)  NULL
        )

        -- 4a) Checadas de Humand pendientes del periodo.
        --     La clasificación se toma sin la alerta que agrega el sync
        --     (ej. 'RETRASO_COMIDA_MENOR|OLVIDO_CHECAR_SALIDA' -> 'RETRASO_COMIDA_MENOR').
        INSERT INTO #Fuente (Origen, SourceId, Personal, Fecha, Regla, Valor, SucursalTrabajo, Categoria)
        SELECT 'H', h.id, RTRIM(e.Personal), h.fecha, r.Regla,
               CASE WHEN r.Regla = 'UnidadesSindicalizado'
                    THEN CAST(CEILING((h.minutosDesviacion - @ToleranciaMin) / CAST(@BloqueMin AS decimal(9,2))) AS int)
                    ELSE 1 END,
               e.SucursalTrabajo, e.Categoria
          FROM [Humand].[dbo].[Humand] h WITH (UPDLOCK, ROWLOCK)
          JOIN #Emp e ON e.Personal = h.employeeId
         CROSS APPLY (SELECT Base = LEFT(ISNULL(h.clasificacion, ''), CHARINDEX('|', ISNULL(h.clasificacion, '') + '|') - 1)) c
         CROSS APPLY (SELECT Regla = CASE
                WHEN h.tipoMarcaje = 'FALTA' AND c.Base = 'FALTA'
                    THEN 'Falta'
                WHEN e.EsSindicalizado = 1
                     AND h.tipoMarcaje IN ('ENTRADA', 'REGRESO_COMIDA')
                     AND h.minutosDesviacion > @ToleranciaMin
                     AND c.Base NOT IN ('REVISAR_HORARIO', 'JUSTIFICADO')
                    THEN 'UnidadesSindicalizado'
                WHEN e.EsSindicalizado = 0 AND h.tipoMarcaje = 'ENTRADA'        AND c.Base = 'RETARDO_MENOR'        THEN 'RetardoMenorEntrada'
                WHEN e.EsSindicalizado = 0 AND h.tipoMarcaje = 'REGRESO_COMIDA' AND c.Base = 'RETRASO_COMIDA_MENOR' THEN 'RetardoMenorComida'
                WHEN e.EsSindicalizado = 0 AND h.tipoMarcaje = 'ENTRADA'        AND c.Base = 'RETARDO_MAYOR'        THEN 'RetardoMayorEntrada'
                WHEN e.EsSindicalizado = 0 AND h.tipoMarcaje = 'REGRESO_COMIDA' AND c.Base = 'RETRASO_COMIDA_MAYOR' THEN 'RetardoMayorComida'
                WHEN e.EsSindicalizado = 0 AND h.tipoMarcaje IN ('ENTRADA', 'REGRESO_COMIDA') AND c.Base = 'PERMISO_HORAS' THEN 'PermisoHoras'
            END) r
         WHERE h.fecha BETWEEN @FechaD AND @FechaA
           AND ISNULL(h.Procesado, 0) = 0
           AND ISNULL(h.tipoIncidenciaAplicada, '') = ''
           AND r.Regla IS NOT NULL

        -- 4b) Incidencias aprobadas: cada día que TRASLAPA con el periodo
        --     (antes solo entraban las que caían completas dentro del periodo)
        --     y que todavía no se ha enviado a Nómina.
        INSERT INTO #Fuente (Origen, SourceId, Personal, Fecha, Regla, Valor, SucursalTrabajo, Categoria)
        SELECT 'I', i.id, RTRIM(e.Personal), d.Fecha, m.Regla, 1, e.SucursalTrabajo, e.Categoria
          FROM [Humand].[dbo].[IncidenciaHumand] i WITH (UPDLOCK, ROWLOCK)
          JOIN #Emp e ON e.Personal = i.Personal
          JOIN (VALUES
                ('PERMISO_DEFUNCION_FAM_DIRECTO',   'PermisoDefuncionFamDirecto'),
                ('PERMISO_DEFUNCION_FAM_INDIRECTO', 'PermisoDefuncionFamIndirecto'),
                ('PERMISO_PATERNIDAD',              'PermisoPaternidad'),
                ('TIEMPO_POR_TIEMPO_HORAS',         'TiempoPorTiempoHoras'),
                ('VACACIONES',                      'Vacaciones'),
                ('INCAPACIDAD_ENFERMEDAD',          'IncapacidadEnfermedad'),
                ('INCAPACIDAD_ACCIDENTE',           'IncapacidadAccidente')
               ) m (TipoIncidencia, Regla) ON m.TipoIncidencia = i.TipoIncidencia
          JOIN #Dias d ON d.Fecha BETWEEN i.FechaInicio AND i.FechaFin
         WHERE i.Estatus = 'APROBADO'
           AND NOT EXISTS (SELECT 1
                             FROM [Humand].[dbo].[IncidenciaHumandProcesada] ip
                            WHERE ip.IncidenciaId = i.id
                              AND ip.Fecha = d.Fecha)

        /* -------------------------------------------------------------
           5) Aplicar reglas y agrupar en líneas de NominaD
           ------------------------------------------------------------- */
        SELECT f.Origen, f.SourceId, f.Personal, f.Fecha, f.Regla, f.Valor, f.SucursalTrabajo,
               Referencia = CASE WHEN r.AcumulaPeriodo = 1 THEN @Etiqueta ELSE CONVERT(varchar(50), f.Fecha) END,
               Divisor    = CASE WHEN r.UsaDivisorSancion = 1 THEN CASE WHEN @AplicaSancion = 1 THEN 4 ELSE 3 END END,
               r.Umbral
          INTO #FuenteRegla
          FROM #Fuente f
          JOIN #Reglas r ON r.Regla = f.Regla
         WHERE r.Activa = 1
           AND (r.SoloCategoria IS NULL OR ISNULL(f.Categoria, '') = r.SoloCategoria)

        -- Los retardos menores ahora se acumulan por PERIODO: 3 (o 4) en la
        -- semana/quincena = 1 unidad. Antes se evaluaban por día y nunca llegaban al umbral.
        SELECT Regla, SucursalTrabajo, Personal, Referencia,
               Total    = SUM(Valor),
               Cantidad = CASE WHEN MAX(Divisor) IS NOT NULL THEN SUM(Valor) / MAX(Divisor) ELSE SUM(Valor) END,
               Renglon  = CAST(NULL AS int),
               NominaID = CAST(NULL AS int)
          INTO #Grupos
          FROM #FuenteRegla
         GROUP BY Regla, SucursalTrabajo, Personal, Referencia
        HAVING SUM(Valor) >= ISNULL(MAX(Divisor), MAX(Umbral))

        ;WITH R AS (
            SELECT Renglon, rn = ROW_NUMBER() OVER (PARTITION BY Regla, SucursalTrabajo ORDER BY Personal, Referencia)
              FROM #Grupos
        )
        UPDATE R SET Renglon = rn * 2048

        /* -------------------------------------------------------------
           Modo simulación: muestra lo que se generaría y no guarda nada
           ------------------------------------------------------------- */
        IF @Simular = 1
        BEGIN
            SELECT Periodo = @Etiqueta, FechaD = @FechaD, FechaA = @FechaA, FechaEmision = @FechaEmision,
                   r.Mov, r.Concepto, g.SucursalTrabajo, g.Personal, g.Referencia, g.Total, g.Cantidad, g.Renglon
              FROM #Grupos g
              JOIN #Reglas r ON r.Regla = g.Regla
             ORDER BY r.Mov, r.Concepto, g.SucursalTrabajo, g.Renglon

            -- Registros que quedarían pendientes (bajo umbral, regla inactiva o fuera de categoría)
            SELECT f.Origen, f.Regla, Registros = COUNT(*)
              FROM #Fuente f
             WHERE NOT EXISTS (SELECT 1
                                 FROM #FuenteRegla fr
                                 JOIN #Grupos g ON g.Regla = fr.Regla AND g.SucursalTrabajo = fr.SucursalTrabajo
                                               AND g.Personal = fr.Personal AND g.Referencia = fr.Referencia
                                WHERE fr.Origen = f.Origen AND fr.SourceId = f.SourceId AND fr.Fecha = f.Fecha)
             GROUP BY f.Origen, f.Regla
             ORDER BY f.Origen, f.Regla

            ROLLBACK TRAN
            RETURN 0
        END

        /* -------------------------------------------------------------
           6) Un movimiento de Nómina por Regla x Sucursal con líneas.
              (Ya no se crean encabezados vacíos.)
           ------------------------------------------------------------- */
        DECLARE @Regla varchar(30), @Sucursal int, @Mov varchar(20), @Concepto varchar(50),
                @Observaciones varchar(255), @IDGenera int

        DECLARE cMov CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT Regla, SucursalTrabajo FROM #Grupos ORDER BY Regla, SucursalTrabajo

        OPEN cMov
        FETCH NEXT FROM cMov INTO @Regla, @Sucursal
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SELECT @Mov           = Mov,
                   @Concepto      = Concepto,
                   @Observaciones = ObservacionBase + ' ' + @Etiqueta
              FROM #Reglas
             WHERE Regla = @Regla

            INSERT INTO Nomina
                  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota,
                   OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)
            VALUES
                  (@Empresa, @Mov, NULL, @FechaEmision, @Hoy, @Concepto, NULL, 'Pesos', 1, @Usuario, NULL, NULL, @Observaciones, 'SINAFECTAR', NULL, NULL, NULL, NULL,
                   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, @Sucursal, @Sucursal, NULL, @FechaEmision, 0, @PeriodoTipo, @Periodo)

            SET @IDGenera = SCOPE_IDENTITY()

            INSERT INTO NominaD
                  (ID, Renglon, Modulo, Personal, Horas, Cantidad, Referencia, FechaD, Activo, Sucursal, SucursalOrigen)
            SELECT @IDGenera, Renglon, 'NOM', Personal, '01:00', Cantidad, Referencia, @Hoy, 1, 0, 0
              FROM #Grupos
             WHERE Regla = @Regla AND SucursalTrabajo = @Sucursal

            UPDATE #Grupos SET NominaID = @IDGenera
             WHERE Regla = @Regla AND SucursalTrabajo = @Sucursal

            SET @Movimientos += 1
            FETCH NEXT FROM cMov INTO @Regla, @Sucursal
        END
        CLOSE cMov
        DEALLOCATE cMov

        /* -------------------------------------------------------------
           7) Marcar Humand: solo lo que generó línea en NominaD
           ------------------------------------------------------------- */
        SELECT @EsperadosHumand = COUNT(*)
          FROM #FuenteRegla fr
          JOIN #Grupos g ON g.Regla = fr.Regla AND g.SucursalTrabajo = fr.SucursalTrabajo
                        AND g.Personal = fr.Personal AND g.Referencia = fr.Referencia
         WHERE fr.Origen = 'H'

        UPDATE h
           SET h.Procesado      = 1,
               h.FechaProceso   = @Hoy,
               h.UsuarioProceso = @Usuario--,
               --h.NominaID       = g.NominaID
          FROM [Humand].[dbo].[Humand] h
          JOIN #FuenteRegla fr ON fr.Origen = 'H' AND fr.SourceId = h.id
          JOIN #Grupos g ON g.Regla = fr.Regla AND g.SucursalTrabajo = fr.SucursalTrabajo
                        AND g.Personal = fr.Personal AND g.Referencia = fr.Referencia
         WHERE ISNULL(h.Procesado, 0) = 0

        SET @MarcadosHumand = @@ROWCOUNT

        IF @MarcadosHumand <> @EsperadosHumand
        BEGIN
            SET @Msg = N'Se esperaban marcar ' + CONVERT(nvarchar(10), @EsperadosHumand) + N' registros de Humand y se marcaron '
                     + CONVERT(nvarchar(10), @MarcadosHumand) + N'. Otro proceso los modificó; no se guardó nada.'
            ;THROW 50005, @Msg, 1
        END

        /* -------------------------------------------------------------
           8) Marcar IncidenciaHumand
              - un renglón por día procesado en IncidenciaHumandProcesada
              - Procesado = 1 cuando ya están todos los días de la incidencia
           ------------------------------------------------------------- */
        INSERT INTO [Humand].[dbo].[IncidenciaHumandProcesada]
              (IncidenciaId, Fecha, Personal, TipoIncidencia, PeriodoTipo, Periodo, NominaID, FechaProceso, UsuarioProceso)
        SELECT fr.SourceId, fr.Fecha, fr.Personal, i.TipoIncidencia, @PeriodoTipo, @Periodo, g.NominaID, GETDATE(), @Usuario
          FROM #FuenteRegla fr
          JOIN #Grupos g ON g.Regla = fr.Regla AND g.SucursalTrabajo = fr.SucursalTrabajo
                        AND g.Personal = fr.Personal AND g.Referencia = fr.Referencia
          JOIN [Humand].[dbo].[IncidenciaHumand] i ON i.id = fr.SourceId
         WHERE fr.Origen = 'I'

        SET @DiasIncidencia = @@ROWCOUNT

        UPDATE i
           SET i.Procesado      = CASE WHEN x.Dias >= DATEDIFF(DAY, i.FechaInicio, i.FechaFin) + 1 THEN 1 ELSE 0 END,
               i.FechaProceso   = @Hoy,
               i.UsuarioProceso = @Usuario
          FROM [Humand].[dbo].[IncidenciaHumand] i
          JOIN (SELECT ip.IncidenciaId, Dias = COUNT(*)
                  FROM [Humand].[dbo].[IncidenciaHumandProcesada] ip
                 WHERE ip.IncidenciaId IN (SELECT SourceId FROM #FuenteRegla WHERE Origen = 'I')
                 GROUP BY ip.IncidenciaId) x ON x.IncidenciaId = i.id

        SELECT @IncidenciasCerradas = COUNT(DISTINCT i.id)
          FROM [Humand].[dbo].[IncidenciaHumand] i
         WHERE i.id IN (SELECT SourceId FROM #FuenteRegla WHERE Origen = 'I')
           AND i.Procesado = 1

        COMMIT TRAN

        SELECT Mensaje = 'Se generaron ' + CONVERT(varchar(10), @Movimientos) + ' Movimientos (' + @PeriodoTipo + ' ' + @Periodo + ')'--,
               --Periodo              = @Etiqueta,
               --FechaD               = @FechaD,
               --FechaA               = @FechaA,
               --Movimientos          = @Movimientos,
               --RegistrosHumand      = @MarcadosHumand,
               --DiasIncidencia       = @DiasIncidencia,
               --IncidenciasCompletas = @IncidenciasCerradas
        RETURN 0
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRAN   -- deshace Nomina/NominaD y el marcado de Humand e IncidenciaHumand
        ;THROW              -- el error llega al que invoca (Intelisis / SSIS) como error real
    END CATCH
END
GO

/* =====================================================================
   Envoltorios con la firma anterior (compatibilidad)
   ===================================================================== */
IF OBJECT_ID('dbo.nvk_sp_InsertaIncidencias_Semanal', 'P') IS NOT NULL
    DROP PROC dbo.nvk_sp_InsertaIncidencias_Semanal
GO
CREATE PROC dbo.nvk_sp_InsertaIncidencias_Semanal
    @Empresa    char(5),
    @Semana     varchar(5)  = NULL,
    @Quincena   varchar(5)  = NULL,     -- no se usa; se conserva por compatibilidad
    @Usuario    varchar(10)
AS
    EXEC dbo.nvk_sp_InsertaIncidencias @Empresa = @Empresa, @PeriodoTipo = 'Semanal',
                                       @Periodo = @Semana, @Usuario = @Usuario
GO

IF OBJECT_ID('dbo.nvk_sp_InsertaIncidencias_Quincenal', 'P') IS NOT NULL
    DROP PROC dbo.nvk_sp_InsertaIncidencias_Quincenal
GO
CREATE PROC dbo.nvk_sp_InsertaIncidencias_Quincenal
    @Empresa    char(5),
    @Semana     varchar(5)  = NULL,     -- no se usa; se conserva por compatibilidad
    @Quincena   varchar(5)  = NULL,
    @Usuario    varchar(10)
AS
    EXEC dbo.nvk_sp_InsertaIncidencias @Empresa = @Empresa, @PeriodoTipo = 'Quincenal',
                                       @Periodo = @Quincena, @Usuario = @Usuario
GO
USE Humand
GO
IF OBJECT_ID('dbo.IncidenciaHumandProcesada', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.IncidenciaHumandProcesada (
        id              int IDENTITY(1,1) PRIMARY KEY,
        IncidenciaId    int          NOT NULL,     -- dbo.IncidenciaHumand.id
        Fecha           date         NOT NULL,
        Personal        varchar(50)  NOT NULL,
        TipoIncidencia  varchar(50)  NULL,
        PeriodoTipo     varchar(10)  NOT NULL,     -- Semanal | Quincenal
        Periodo         varchar(5)   NOT NULL,
        NominaID        int          NULL,         -- movimiento de Nomina (base de la empresa)
        FechaProceso    datetime2(0) NOT NULL CONSTRAINT DF_IncidenciaHumandProcesada_Fecha DEFAULT (GETDATE()),
        UsuarioProceso  varchar(10)  NULL,
        CONSTRAINT UQ_IncidenciaHumandProcesada UNIQUE (IncidenciaId, Fecha)
    )
    CREATE INDEX IX_IncidenciaHumandProcesada_Nomina ON dbo.IncidenciaHumandProcesada (NominaID)
END
GO