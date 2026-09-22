-- =========================================================
-- Tabla Humand - almacena fichajes de Humand ya clasificados
-- según el Reglamento de Asistencia
-- Base de datos destino: NVTEST (misma base donde vive Personal)
-- =========================================================

USE NVTEST;
GO

IF OBJECT_ID('dbo.Humand', 'U') IS NOT NULL
BEGIN
    PRINT 'La tabla Humand ya existe, no se creó de nuevo.';
END
ELSE
BEGIN
    CREATE TABLE dbo.Humand (
        id                  INT IDENTITY(1,1) PRIMARY KEY,

        -- Identificación del colaborador
        employeeId          VARCHAR(50)   NOT NULL,   -- employeeInternalId de Humand (= Personal en Intelisis)
        nombreColaborador   VARCHAR(200)  NOT NULL,

        -- Datos del fichaje
        fecha               DATE          NOT NULL,   -- referenceDate: jornada a la que pertenece
        horaFichaje         DATETIME2     NOT NULL,   -- date/time exacto del marcaje (hora local)
        tipoMarcaje         VARCHAR(20)   NOT NULL,   -- ENTRADA | SALIDA_COMIDA | REGRESO_COMIDA | SALIDA
        secuenciaDia        TINYINT       NOT NULL,   -- 1,2,3,4... orden del marcaje en el día

        -- Horario asignado (para trazabilidad de por qué se clasificó así)
        horarioAsignadoIn   TIME          NULL,       -- hora de entrada esperada
        horarioAsignadoOut  TIME          NULL,       -- hora de salida esperada

        -- Resultado de la clasificación
        minutosDesviacion   INT           NULL,       -- +tarde / -temprano vs horario asignado
        clasificacion       VARCHAR(20)   NULL,       -- A_TIEMPO | RETARDO_MENOR | RETARDO_MAYOR | SALIDA_ANTICIPADA

        -- Datos complementarios de nómina / origen
        tipoNomina          VARCHAR(20)   NULL,       -- QUINCENAL | SEMANAL (de Personal.PeriodoTipo)
        origenMarcaje       VARCHAR(20)   NULL,       -- source de Humand: INTEGRATION, KIOSK, APP, etc.
        pairId              VARCHAR(50)   NULL,       -- relaciona entrada/salida del mismo turno

        -- Control de deduplicación
        entryIdHumand       BIGINT        NOT NULL,   -- id del fichaje en Humand (único por marcaje)

        fechaProcesado      DATETIME2     DEFAULT GETDATE(),

        CONSTRAINT UQ_Humand_entryIdHumand UNIQUE (entryIdHumand)
    );

    -- Índices para acelerar las consultas más comunes (por colaborador y por fecha,
    -- útiles luego para el reporte de acumulación de retardos)
    CREATE INDEX IX_Humand_employeeId_fecha ON dbo.Humand (employeeId, fecha);
    CREATE INDEX IX_Humand_fecha ON dbo.Humand (fecha);
    CREATE INDEX IX_Humand_clasificacion ON dbo.Humand (clasificacion);

    PRINT 'Tabla Humand creada correctamente.';
END
GO

-- =========================================================
-- Tabla de control: guarda la marca de tiempo de la última
-- sincronización exitosa, para saber desde dónde traer la
-- siguiente vez (sync incremental cada 30 min).
-- =========================================================
IF OBJECT_ID('dbo.HumandSyncControl', 'U') IS NOT NULL
BEGIN
    PRINT 'La tabla HumandSyncControl ya existe, no se creó de nuevo.';
END
ELSE
BEGIN
    CREATE TABLE dbo.HumandSyncControl (
        id                  INT IDENTITY(1,1) PRIMARY KEY,
        ultimaEjecucionUtc  DATETIME2     NOT NULL,
        registrosProcesados INT           NULL,
        fechaRegistro       DATETIME2     DEFAULT GETDATE()
    );

    -- Fila inicial: primera corrida trae desde "ahora - 1 día" por defecto.
    INSERT INTO dbo.HumandSyncControl (ultimaEjecucionUtc, registrosProcesados)
    VALUES (DATEADD(DAY, -1, GETUTCDATE()), 0);

    PRINT 'Tabla HumandSyncControl creada correctamente.';
END
GO
