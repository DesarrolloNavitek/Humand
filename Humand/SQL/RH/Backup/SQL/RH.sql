SET DATEFIRST 7
SET ANSI_NULLS OFF
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED
SET LOCK_TIMEOUT -1
SET QUOTED_IDENTIFIER OFF
GO
/*
--select * from #Base where RetardoMenorEntrada >= 3
--select Personal,PeriodoTipo,SancionEspecalQuincenal,SancionEspecalSemanal,Empresa, Periodo AS Quincena,Semana,RetardoMenorComida from #Base where RetardoMenorComida >= 3
--select Personal,PeriodoTipo,SancionEspecalQuincenal,SancionEspecalSemanal,Empresa, Periodo AS Quincena,Semana,RetardoMayorEntrada from #Base where RetardoMayorEntrada >= 1
select Personal,PeriodoTipo,SancionEspecalQuincenal,SancionEspecalSemanal,Empresa, Periodo AS Quincena,Semana,RetardoMayorComida from #Base where RetardoMayorComida >= 1

   select * from Humand where employeeId = 001784
--SELECT * FROM vw_DescuentosPorRetardo
--SELECT * FROM PeriodosNomina
select * from nvk_tb_IncidenciasQuincenal
select * from nvk_tb_IncidenciasSemanal

select * from vw_AcumuladoRetardosQuincenal
*/
/******************************** Funciones ********************************/
--Calcula periodos de semanas y quincenas
IF EXISTS (SELECT 1 FROM SYS.objects WHERE name ='fn_Quincena' AND type ='FN')
DROP FUNCTION dbo.fn_Quincena
GO
CREATE FUNCTION dbo.fn_Quincena (@fecha DATE)
RETURNS INT
AS
BEGIN
    RETURN (MONTH(@fecha) - 1) * 2 
           + CASE WHEN DAY(@fecha) <= 15 THEN 1 ELSE 2 END;
END
GO

/******************************** Agregar Periodo ********************************/
--EXEC spALTER_TABLE 'nvk_tb_IncidenciasQuincenal', 'Periodo',            'Int'


/******************************** nvk_sp_InsertaIncidencias ********************************/
--11,14
--23,30
--nvk_sp_InsertaIncidencias 'NVK',NULL,NULL,NULL,NULL
IF EXISTS (SELECT 1 FROM SYS.objects WHERE name = 'nvk_sp_InsertaIncidencias' AND type = 'P')
DROP PROC dbo.nvk_sp_InsertaIncidencias
GO 
CREATE PROC dbo.nvk_sp_InsertaIncidencias
@Empresa						char(5),
@Semana							varchar(5) NULL,
@Quincena						varchar(5)	NULL,
@Ok								int		NULL OUTPUT,
@OkRef							varchar (255) NULL OUTPUT
AS
BEGIN
DECLARE 
@Fecha							DATE = GETDATE(),
--@Semana							varchar(5),
@Ejercicio						int,
--@Quincena						varchar(5),
@Cuantos						int = 0,
@Fila							int,
@Procesado						int,
@SancionEspecialQuincenal		int,
@SancionEspecialSemanal			int,
@IDGenera						int,
@Personal						varchar(10),
@PeriodoTipo					varchar(20),
@Cantidad						money


SELECT 
    @Ejercicio = YEAR(@Fecha),
    @Semana = CASE WHEN ISNULL(@Semana,'') = '' THEN DATEPART(ISO_WEEK, @Fecha) ELSE @Semana END,
	@Quincena = CASE WHEN ISNULL(@Quincena,'') = '' THEN 
														(MONTH(@Fecha) - 1) * 2 + CASE WHEN DAY(@Fecha) <= 15 THEN 1 ELSE 2 END
															ELSE @Quincena END


IF NOT EXISTS (SELECT 1 FROM nvk_tb_IncidenciasQuincenal WHERE Periodo = @Quincena)
SELECT @Ok = 10051, @OkRef = 'El periodo Quincenal no existe por favor revisar'
 ELSE
	IF NOT EXISTS (SELECT 1 FROM nvk_tb_IncidenciasSemanal WHERE Semana = @Semana)
		SELECT @Ok = 10051, @OkRef = 'El periodo Semanal no existe por favor revisar'


IF ISNULL(@Ok, '') <> ''
RETURN


/*Tabla Quincenal*/
SELECT  b.Personal,
		b.PeriodoTipo,
		b.Empresa,
		a.Fecha
		,SUM(CASE WHEN a.tipoMarcaje = 'ENTRADA' AND a.clasificacion = 'RETARDO_MENOR' THEN 1 ELSE 0 END) AS RetardoMenorEntrada
		,SUM(CASE WHEN a.tipoMarcaje = 'REGRESO_COMIDA' AND a.clasificacion = 'RETRASO_COMIDA_MENOR' THEN 1 ELSE 0 END) AS RetardoMenorComida
		--,COUNT(DISTINCT CASE WHEN a.clasificacion = 'JUSTIFICADO' THEN a.fecha END)  AS Justificaciones
		,SUM(CASE WHEN a.tipoMarcaje = 'ENTRADA' AND a.clasificacion = 'RETARDO_MAYOR' THEN 1 ELSE 0 END) AS RetardoMayorEntrada
		,SUM(CASE WHEN a.tipoMarcaje = 'REGRESO_COMIDA' AND a.clasificacion = 'RETRASO_COMIDA_MAYOR' THEN 1 ELSE 0 END) AS RetardoMayorComida
		,SUM(CASE WHEN a.tipoMarcaje = 'SALIDA' AND a.clasificacion = 'SALIDA_ANTICIPADA' THEN 1 ELSE 0 END ) AS SalidasAnticipadas
  INTO #Quincenal
  FROM Humand	a
  LEFT JOIN			Personal	b					ON a.employeeId=b.Personal
 WHERE ISNULL(clasificacion, '') IN ('RETARDO_MAYOR','RETRASO_COMIDA_MAYOR','RETRASO_COMIDA_MENOR','SALIDA_ANTICIPADA','RETARDO_MENOR')
   AND ISNULL(tipoIncidenciaAplicada, '') = ''
   AND b.Estatus IN ('ALTA')
   AND b.PeriodoTipo = 'Quincenal'
GROUP BY b.personal,A.nombreColaborador,b.PeriodoTipo,b.Empresa,a.Fecha


/*Tabla Semanal*/
SELECT  b.Personal,
		b.PeriodoTipo,
		b.Empresa, 
		a.Fecha
		,SUM(CASE WHEN a.tipoMarcaje = 'ENTRADA' AND a.clasificacion = 'RETARDO_MENOR' THEN 1 ELSE 0 END) AS RetardoMenorEntrada
		,SUM(CASE WHEN a.tipoMarcaje = 'REGRESO_COMIDA' AND a.clasificacion = 'RETRASO_COMIDA_MENOR' THEN 1 ELSE 0 END) AS RetardoMenorComida
		--,COUNT(DISTINCT CASE WHEN a.clasificacion = 'JUSTIFICADO' THEN a.fecha END)  AS Justificaciones
		,SUM(CASE WHEN a.tipoMarcaje = 'ENTRADA' AND a.clasificacion = 'RETARDO_MAYOR' THEN 1 ELSE 0 END) AS RetardoMayorEntrada
		,SUM(CASE WHEN a.tipoMarcaje = 'REGRESO_COMIDA' AND a.clasificacion = 'RETRASO_COMIDA_MAYOR' THEN 1 ELSE 0 END) AS RetardoMayorComida
		,SUM(CASE WHEN a.tipoMarcaje = 'SALIDA' AND a.clasificacion = 'SALIDA_ANTICIPADA' THEN 1 ELSE 0 END ) AS SalidasAnticipadas
  INTO #Semanal
  FROM Humand	a
  LEFT JOIN			Personal	b					ON a.employeeId=b.Personal
 WHERE ISNULL(clasificacion, '') IN ('RETARDO_MAYOR','RETRASO_COMIDA_MAYOR','RETRASO_COMIDA_MENOR','SALIDA_ANTICIPADA','RETARDO_MENOR')
   AND ISNULL(tipoIncidenciaAplicada, '') = ''
   AND b.Estatus IN ('ALTA')
   AND b.PeriodoTipo = 'Semanal'
GROUP BY b.personal,A.nombreColaborador,b.PeriodoTipo,b.Empresa,a.Fecha
ORDER BY b.PeriodoTipo

--Semanal
--DECLARE crSemanal CURSOR FOR

	--SELECT Personal,PeriodoTipo,Empresa,Semana
	--  FROM #Semanal

 --OPEN crSemanal
 --FETCH NEXT FROM crSemanal INTO @Personal,@PeriodoTipo,@Empresa, @Semana
 --WHILE @@FETCH_STATUS <> -1
	 --BEGIN

	 --Retardos Mayores Entrada directos Semanales
	 IF EXISTS (SELECT 1 from #Semanal a JOIN nvk_tb_IncidenciasSemanal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte WHERE b.Semana = ISNULL(@Semana,b.Semana) AND RetardoMayorEntrada >= 1)
	 BEGIN
		
		INSERT INTO Nomina
		  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota, 
		  OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)

		VALUES

		  (@Empresa,'Prestacion',NULL,@Fecha,@Fecha,	'Retardos Mayores',NULL,'Pesos',	1,		'JRIVERA4',	NULL,		NULL,'Retardos Mayor Entrada Semana '+@Semana,'SINAFECTAR',NULL,		NULL,			NULL,			NULL,
		  NULL,		NULL,		NULL,	NULL,		NULL,		NULL,		NULL,				NULL,			NULL,		NULL,		NULL,	NULL,	NULL,	NULL,		0,			0,			NULL,@Fecha,	0,		'Semanal',@Semana)

		SELECT @IDGenera = SCOPE_IDENTITY()


		INSERT INTO NominaD
			  (		ID,				Renglon,							Modulo, Personal,		Horas, Cantidad,		Referencia, FechaD,
			   Activo, Sucursal, SucursalOrigen)

			SELECT @IDGenera, ROW_NUMBER() OVER(order BY Personal)*2048,'NOM',	Personal,	'01:00',SUM(RetardoMayorEntrada),	CONVERT(varchar(50), a.fecha)	,@Fecha,
				1,		0,			0
			  FROM #Semanal a 
			  JOIN nvk_tb_IncidenciasSemanal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte
			 WHERE RetardoMayorEntrada >= 1
			   AND Personal IS NOT NULL
			   AND b.Semana IN (ISNULL(@Semana, b.Semana))
			 GROUP BY Personal,a.fecha
		
		SELECT @Cuantos = @Cuantos + 1
	 END

	 --Retardos Mayores Entrada directos Quincenales
	 IF EXISTS (SELECT 1 from #Quincenal a JOIN nvk_tb_IncidenciasQuincenal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte WHERE b.Periodo = ISNULL(@Quincena, b.Periodo) AND RetardoMayorEntrada >= 1)
	 BEGIN
		INSERT INTO Nomina
		  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota, 
		  OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)

		VALUES

		  (@Empresa,'Prestacion',NULL,@Fecha,@Fecha,	'Retardos Mayores',NULL,'Pesos',	1,		'JRIVERA4',	NULL,		NULL,'Retardos Mayor Entrada Quincena '+@Quincena,'SINAFECTAR',NULL,		NULL,			NULL,			NULL,
		  NULL,		NULL,		NULL,	NULL,		NULL,		NULL,		NULL,				NULL,			NULL,		NULL,		NULL,	NULL,	NULL,	NULL,		0,			0,			NULL,@Fecha,	0,		'Quincenal',@Quincena)

		SELECT @IDGenera = SCOPE_IDENTITY()


		INSERT INTO NominaD
			  (		ID,				Renglon,							Modulo, Personal,		Horas, Cantidad,					Referencia,				FechaD,
			   Activo, Sucursal, SucursalOrigen)

			SELECT @IDGenera, ROW_NUMBER() OVER(order BY Personal)*2048,'NOM',	Personal,	'01:00',SUM(RetardoMayorEntrada),CONVERT(varchar(50), a.fecha)	,@Fecha,
				1,		0,			0
			  FROM #Quincenal a 
			  JOIN nvk_tb_IncidenciasQuincenal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte 
			 WHERE RetardoMayorEntrada >= 1
			   AND Personal IS NOT NULL
			   AND b.Periodo IN (ISNULL(@Quincena, b.Periodo))
			 GROUP BY Personal,a.fecha

		SELECT @Cuantos = @Cuantos + 1
	 END

	 -- Retardos menores Comida semanal
	 IF EXISTS (SELECT 1 from #Semanal a JOIN nvk_tb_IncidenciasSemanal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte WHERE b.Semana = ISNULL(@Semana, b.Semana) AND RetardoMenorComida >= 3)
	 BEGIN
		
		INSERT INTO Nomina
		  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota, 
		  OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)

		VALUES

		  (@Empresa,'Prestacion',NULL,@Fecha,@Fecha,	'Retardos Menores',NULL,'Pesos',	1,		'JRIVERA4',	NULL,		NULL,'Retardos Menores Comida Acumulados Semana '+@Semana,'SINAFECTAR',NULL,		NULL,			NULL,			NULL,
		  NULL,		NULL,		NULL,	NULL,		NULL,		NULL,		NULL,				NULL,			NULL,		NULL,		NULL,	NULL,	NULL,	NULL,		0,			0,			NULL,@Fecha,	0,		'Semanal',@Semana)

		SELECT @IDGenera = SCOPE_IDENTITY()


		INSERT INTO NominaD
			  (		ID,				Renglon,							Modulo, Personal,		Horas, Cantidad,																Referencia,							FechaD,
			   Activo, Sucursal, SucursalOrigen)

			SELECT @IDGenera, ROW_NUMBER() OVER(order BY Personal)*2048,'NOM',	Personal,	'01:00',SUM(RetardoMenorComida/ CASE WHEN  b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END),CONVERT(varchar(50), a.fecha)	,@Fecha,
				1,		0,			0
			  FROM #Semanal a 
			  JOIN nvk_tb_IncidenciasSemanal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte
			 WHERE RetardoMenorComida >= CASE WHEN b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END
			   AND Personal IS NOT NULL
			   AND b.Semana IN (ISNULL( @Semana, b.Semana))
			 GROUP BY Personal,a.fecha
		
		SELECT @Cuantos = @Cuantos + 1
	 END

	 -- Retardo menor comida quincenal
	 IF EXISTS (SELECT 1 from #Quincenal a JOIN nvk_tb_IncidenciasQuincenal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte WHERE b.Periodo = ISNULL(@Quincena, b.Periodo) AND RetardoMenorComida >= 3)
	 BEGIN
		INSERT INTO Nomina
		  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota, 
		  OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)

		VALUES

		  (@Empresa,'Prestacion',NULL,@Fecha,@Fecha,	'Retardos Mayores',NULL,'Pesos',	1,		'JRIVERA4',	NULL,		NULL,'Retardos Meores Comida Acumulados Quincena '+@Quincena,'SINAFECTAR',NULL,		NULL,			NULL,			NULL,
		  NULL,		NULL,		NULL,	NULL,		NULL,		NULL,		NULL,				NULL,			NULL,		NULL,		NULL,	NULL,	NULL,	NULL,		0,			0,			NULL,@Fecha,	0,		'Quincenal',@Quincena)

		SELECT @IDGenera = SCOPE_IDENTITY()


		INSERT INTO NominaD
			  (		ID,				Renglon,							Modulo, Personal,		Horas, Cantidad,																	Referencia,						FechaD,
			   Activo, Sucursal, SucursalOrigen)

			SELECT @IDGenera, ROW_NUMBER() OVER(order BY Personal)*2048,'NOM',	Personal,	'01:00',SUM(RetardoMenorComida/ CASE WHEN  b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END),CONVERT(varchar(50), a.fecha)	,@Fecha,
				1,		0,			0
			  FROM #Quincenal a 
			  JOIN nvk_tb_IncidenciasQuincenal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte
			 WHERE RetardoMenorComida >= CASE WHEN b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END
			   AND Personal IS NOT NULL
			   AND b.Periodo IN (ISNULL( @Quincena, b.Periodo))
			 GROUP BY Personal,a.fecha

		SELECT @Cuantos = @Cuantos + 1
	 END


	--Retardos Menores Entrada Semanal

	 IF EXISTS (SELECT 1 from #Semanal a JOIN nvk_tb_IncidenciasSemanal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte WHERE b.Semana = ISNULL(@Semana, b.Semana) AND RetardoMenorEntrada >= 3)
	 BEGIN
		
		INSERT INTO Nomina
		  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota, 
		  OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)

		VALUES

		  (@Empresa,'Prestacion',NULL,@Fecha,@Fecha,	'Retardos Menores',NULL,'Pesos',	1,		'JRIVERA4',	NULL,		NULL,'Retardos Menores Acumulados Entrada Semana '+@Semana,'SINAFECTAR',NULL,		NULL,			NULL,			NULL,
		  NULL,		NULL,		NULL,	NULL,		NULL,		NULL,		NULL,				NULL,			NULL,		NULL,		NULL,	NULL,	NULL,	NULL,		0,			0,			NULL,@Fecha,	0,		'Semanal',@Semana)

		SELECT @IDGenera = SCOPE_IDENTITY()


		INSERT INTO NominaD
			  (		ID,				Renglon,							Modulo, Personal,		Horas, Cantidad,																		Referencia,						FechaD,
			   Activo, Sucursal, SucursalOrigen)

			SELECT @IDGenera, ROW_NUMBER() OVER(order BY Personal)*2048,'NOM',	Personal,	'01:00',SUM(RetardoMenorEntrada/ CASE WHEN  b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END),CONVERT(varchar(50), a.fecha)	,@Fecha,
				1,		0,			0
			  FROM #Semanal a 
			  JOIN nvk_tb_IncidenciasSemanal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte
			 WHERE RetardoMenorEntrada >= CASE WHEN b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END
			   AND Personal IS NOT NULL
			   AND b.Semana IN (ISNULL( @Semana, b.Semana))
			 GROUP BY Personal,a.fecha
		SELECT @Cuantos = @Cuantos + 1
	 END


	 --Retardo menor entrada quincenal
	 IF EXISTS (SELECT 1 from #Quincenal a JOIN nvk_tb_IncidenciasQuincenal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte WHERE b.Periodo = ISNULL(@Quincena, b.Periodo) AND RetardoMenorEntrada >= 3)
	 BEGIN
		INSERT INTO Nomina
		  (Empresa, Mov, MovID, FechaEmision, UltimoCambio, Concepto, Proyecto, Moneda, TipoCambio, Usuario, Autorizacion, DocFuente, Observaciones, Estatus, Situacion, SituacionFecha, SituacionUsuario, SituacionNota, 
		  OrigenTipo, Origen, OrigenID, Ejercicio, Periodo, FechaRegistro, FechaConclusion, FechaCancelacion, Condicion, PeriodoTipo, FechaD, FechaA, Poliza, PolizaID, Sucursal, SucursalOrigen, UEN, FechaOrigen, NOI, TipoPeriodo, NoPeriodo)

		VALUES

		  (@Empresa,'Prestacion',NULL,@Fecha,@Fecha,	'Retardos Mayores',NULL,'Pesos',	1,		'JRIVERA4',	NULL,		NULL,'Retardos Meores Comida Acumulados Quincena '+@Quincena,'SINAFECTAR',NULL,		NULL,			NULL,			NULL,
		  NULL,		NULL,		NULL,	NULL,		NULL,		NULL,		NULL,				NULL,			NULL,		NULL,		NULL,	NULL,	NULL,	NULL,		0,			0,			NULL,@Fecha,	0,		'Quincenal',@Quincena)

		SELECT @IDGenera = SCOPE_IDENTITY()


		INSERT INTO NominaD
			  (		ID,				Renglon,							Modulo, Personal,		Horas, Cantidad,																		Referencia,		 FechaD,
			   Activo, Sucursal, SucursalOrigen)

			SELECT @IDGenera, ROW_NUMBER() OVER(order BY Personal)*2048,'NOM',	Personal,	'01:00',SUM(RetardoMenorEntrada/ CASE WHEN  b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END),CONVERT(varchar(50), a.fecha),@Fecha,
				1,		0,			0
			  FROM #Quincenal a 
			  JOIN nvk_tb_IncidenciasQuincenal b ON a.fecha>= FechaDCorte and a.fecha <= FechaACorte
			 WHERE RetardoMenorEntrada >= CASE WHEN b.AplicaSancionEspecial = 1 THEN 4 ELSE 3 END
			   AND Personal IS NOT NULL
			   AND b.Periodo IN (ISNULL( @Quincena, b.Periodo))
			 GROUP BY Personal,a.fecha
		SELECT @Cuantos = @Cuantos + 1
	 END

		--FETCH NEXT FROM crSemanal INTO @Personal,@PeriodoTipo,@Empresa, @Semana
	 --END
 --CLOSE crSemanal
 --DEALLOCATE crSemanal

	SELECT @Ok = 20515, @OkRef = 'Se generaron '+TRIM(CONVERT(char, @Cuantos))+' Movimientos'

RETURN
END
