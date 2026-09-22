

/****** Object:  Table [dbo].[RotativoEmpleados]    Script Date: 09/09/2026 03:41:43 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[RotativoEmpleados](
	[Hoja] [varchar](50) NULL,
	[Clave] [varchar](10) NOT NULL,
	[Nombre] [varchar](200) NULL,
	[Departamento] [varchar](100) NULL,
	[TurnoAsignado] [varchar](100) NULL,
	[Categoria] [varchar](50) NULL,
PRIMARY KEY CLUSTERED 
(
	[Clave] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO


/****** Object:  Table [dbo].[RotativoTurnoCatalogo]    Script Date: 09/09/2026 03:42:05 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[RotativoTurnoCatalogo](
	[Hoja] [varchar](50) NULL,
	[BloqueId] [int] NULL,
	[Area] [varchar](100) NULL,
	[DiaSemana] [int] NULL,
	[NombreTurno] [varchar](100) NULL,
	[HoraEntrada] [varchar](5) NULL,
	[HoraSalida] [varchar](5) NULL
) ON [PRIMARY]
GO



/****** Object:  Table [dbo].[DiasEspeciales]    Script Date: 09/09/2026 03:42:33 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[DiasEspeciales](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[fecha] [date] NOT NULL,
	[tipo] [varchar](50) NOT NULL,
	[employeeId] [varchar](50) NULL,
	[comentario] [varchar](255) NULL,
	[capturadoEn] [datetime2](7) NULL,
	[capturadoPor] [varchar](100) NULL,
PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[DiasEspeciales] ADD  DEFAULT (getdate()) FOR [capturadoEn]
GO



/****** Object:  Table [dbo].[HumandRawDaySummary]    Script Date: 09/09/2026 03:43:03 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[HumandRawDaySummary](
	[employeeId] [varchar](50) NOT NULL,
	[fecha] [date] NOT NULL,
	[isWorkday] [bit] NULL,
	[hasSchedule] [bit] NULL,
	[totalEntries] [int] NOT NULL,
	[rawJson] [nvarchar](max) NOT NULL,
	[capturadoEn] [datetime2](7) NULL,
 CONSTRAINT [PK_HumandRawDaySummary] PRIMARY KEY CLUSTERED 
(
	[employeeId] ASC,
	[fecha] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]
GO

ALTER TABLE [dbo].[HumandRawDaySummary] ADD  DEFAULT ((0)) FOR [totalEntries]
GO

ALTER TABLE [dbo].[HumandRawDaySummary] ADD  DEFAULT (getdate()) FOR [capturadoEn]
GO



/****** Object:  Table [dbo].[HorarioHistorico]    Script Date: 09/09/2026 03:43:52 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[HorarioHistorico](
	[employeeId] [varchar](50) NOT NULL,
	[diaSemana] [tinyint] NOT NULL,
	[horaEntrada] [varchar](5) NULL,
	[horaSalida] [varchar](5) NULL,
 CONSTRAINT [PK_HorarioHistorico] PRIMARY KEY CLUSTERED 
(
	[employeeId] ASC,
	[diaSemana] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO



/****** Object:  Table [dbo].[IncidenciaHumand]    Script Date: 09/09/2026 03:44:23 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[IncidenciaHumand](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[Personal] [varchar](50) NOT NULL,
	[TipoIncidencia] [varchar](100) NOT NULL,
	[FechaInicio] [date] NOT NULL,
	[FechaFin] [date] NOT NULL,
	[Estatus] [varchar](20) NOT NULL,
	[Comentario] [varchar](500) NULL,
	[CapturadoPor] [varchar](100) NULL,
	[FechaCaptura] [datetime2](7) NULL,
	[HumandRequestId] [int] NULL,
PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[IncidenciaHumand] ADD  DEFAULT ('APROBADO') FOR [Estatus]
GO

ALTER TABLE [dbo].[IncidenciaHumand] ADD  DEFAULT (getdate()) FOR [FechaCaptura]
GO



/****** Object:  Table [dbo].[HumandSyncControl]    Script Date: 09/09/2026 03:44:51 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[HumandSyncControl](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[ultimaEjecucionUtc] [datetime2](7) NOT NULL,
	[registrosProcesados] [int] NULL,
	[fechaRegistro] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[HumandSyncControl] ADD  DEFAULT (getdate()) FOR [fechaRegistro]
GO



/****** Object:  Table [dbo].[Humand]    Script Date: 09/09/2026 03:45:14 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[Humand](
	[id] [int] IDENTITY(1,1) NOT NULL,
	[employeeId] [varchar](50) NOT NULL,
	[nombreColaborador] [varchar](200) NOT NULL,
	[fecha] [date] NOT NULL,
	[horaFichaje] [datetime2](7) NOT NULL,
	[tipoMarcaje] [varchar](20) NOT NULL,
	[secuenciaDia] [tinyint] NOT NULL,
	[horarioAsignadoIn] [time](7) NULL,
	[horarioAsignadoOut] [time](7) NULL,
	[minutosDesviacion] [int] NULL,
	[clasificacion] [varchar](100) NULL,
	[tipoNomina] [varchar](20) NULL,
	[origenMarcaje] [varchar](20) NULL,
	[pairId] [varchar](50) NULL,
	[entryIdHumand] [bigint] NOT NULL,
	[fechaProcesado] [datetime2](7) NULL,
	[tipoIncidenciaAplicada] [varchar](100) NULL,
	[Procesado] [bit] NOT NULL,
	[FechaProceso] [datetime] NULL,
	[UsuarioProceso] [varchar](10) NULL,
PRIMARY KEY CLUSTERED 
(
	[id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY],
 CONSTRAINT [UQ_Humand_entryIdHumand] UNIQUE NONCLUSTERED 
(
	[entryIdHumand] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[Humand] ADD  DEFAULT (getdate()) FOR [fechaProcesado]
GO

ALTER TABLE [dbo].[Humand] ADD  CONSTRAINT [DF_Humand_Procesado]  DEFAULT ((0)) FOR [Procesado]
GO



/****** Object:  Table [dbo].[HumandBajasPendientes]    Script Date: 09/09/2026 03:57:55 p. m. ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[HumandBajasPendientes](
	[employeeInternalId] [varchar](50) NOT NULL,
	[nombreColaborador] [varchar](200) NULL,
	[fechaDeshabilitado] [date] NOT NULL,
	[fechaEliminacionProgramada] [date] NOT NULL,
	[eliminado] [bit] NOT NULL,
	[fechaEliminado] [datetime2](7) NULL,
	[capturadoEn] [datetime2](7) NULL,
PRIMARY KEY CLUSTERED 
(
	[employeeInternalId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, FILLFACTOR = 80, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]
GO

ALTER TABLE [dbo].[HumandBajasPendientes] ADD  DEFAULT ((0)) FOR [eliminado]
GO

ALTER TABLE [dbo].[HumandBajasPendientes] ADD  DEFAULT (getdate()) FOR [capturadoEn]
GO

select * from IncidenciaHumand order by FechaInicio
INSERT INTO IncidenciaHumand
select Personal,
TipoIncidencia,
FechaInicio,
FechaFin,
Estatus,
Comentario,
CapturadoPor,
FechaCaptura,
HumandRequestId 

from 	NVTEST..IncidenciaHumand  --


INSERT INTO HumandSyncControl
select ultimaEjecucionUtc,
registrosProcesados,
fechaRegistro from 	NVTEST.DBO.HumandSyncControl --

INSERT INTO Humand
select employeeId,
nombreColaborador,
fecha,
horaFichaje,
tipoMarcaje,
secuenciaDia,
horarioAsignadoIn,
horarioAsignadoOut,
minutosDesviacion,
clasificacion,
tipoNomina,
origenMarcaje,
pairId,
entryIdHumand,
fechaProcesado,
tipoIncidenciaAplicada,
Procesado,
FechaProceso,
UsuarioProceso

from 	NVTEST.DBO.Humand --


INSERT INTO HumandRawDaySummary
select * 
from 	NVTEST.DBO.HumandRawDaySummary --


INSERT INTO HorarioHistorico
select * from 	NVTEST.DBO.HorarioHistorico  --

INSERT INTO DiasEspeciales
select fecha,
tipo,
employeeId,
comentario,
capturadoEn,
capturadoPor from 	NVTEST.DBO.DiasEspeciales  --


INSERT INTO RotativoEmpleados
select * from 	NVTEST.DBO.RotativoEmpleados  --

INSERT INTO RotativoTurnoCatalogo
select * from 	NVTEST.DBO.RotativoTurnoCatalogo  --

INSERT INTO HumandBajasPendientes
select * from 	NVTEST.DBO.HumandBajasPendientes  --


select * from 	Humand where employeeId = '002729' and fecha = '09/09/2026'