
[Forma]
Clave=nvk_ProcesarNominaHumand
Icono=0
Modulos=(Todos)
MovModulo=(Todos)
Nombre=Procesar Nómina Semanal

ListaCarpetas=Lista
CarpetaPrincipal=Lista
PosicionInicialIzquierda=779
PosicionInicialArriba=454
PosicionInicialAlturaCliente=132
PosicionInicialAncho=263
BarraAcciones=S
AccionesTamanoBoton=15x5
ListaAcciones=(Lista)
AccionesCentro=S
VentanaTipoMarco=Normal
VentanaPosicionInicial=Por diseño
VentanaEstadoInicial=Normal
VentanaExclusiva=S
VentanaExclusivaOpcion=0
[Lista]
Estilo=Ficha
Clave=Lista
PermiteEditar=S
AlineacionAutomatica=S
AcomodarTexto=S
MostrarConteoRegistros=S
Zona=A1
Vista=(Variables)
Fuente={Tahoma, 8, Negro, []}
FichaEspacioEntreLineas=6
FichaEspacioNombres=100
FichaEspacioNombresAuto=S
FichaNombres=Izquierda
FichaAlineacion=Izquierda
FichaAlineacionDerecha=S
FichaColorFondo=Plata
CampoColorLetras=Negro
CampoColorFondo=Blanco
ListaEnCaptura=(Lista)

CarpetaVisible=S

[Lista.Info.Empresa]
Carpeta=Lista
Clave=Info.Empresa
Editar=S
LineaNueva=S
ValidaNombre=S
3D=S
Tamano=20
ColorFondo=Blanco


WebEstilo=Parrafo
[Lista.Columnas]
Empresa=71
Nombre=371









[Lista.ListaEnCaptura]
(Inicio)=Info.Empresa
Info.Empresa=Info.Semana
Info.Semana=(Fin)

[Lista.Info.Semana]
Carpeta=Lista
Clave=Info.Semana
Editar=S
LineaNueva=S
ValidaNombre=S
3D=S
Tamano=20
ColorFondo=Blanco

[Acciones.Aceptar]
Nombre=Aceptar
Boton=0
NombreDesplegar=&Aceptar
EnBarraAcciones=S
Activo=S
Visible=S

TipoAccion=Ventana
ClaveAccion=Cerrar
GuardarAntes=S
Multiple=S
ListaAccionesMultiples=(Lista)
Antes=S
AntesExpresiones=Asigna(Temp.Texto,Info.Empresa)<BR>Asigna(Temp.TextoTemp01,Info.Usuario)<BR>Asigna(Temp.Num,Info.Semana)
[Acciones.Cerrar]
Nombre=Cerrar
Boton=0
NombreDesplegar=Ce&rrar
EnBarraAcciones=S
TipoAccion=Ventana
ClaveAccion=Cerrar
Activo=S
Visible=S













































































[Acciones.Aceptar.Ejecuta]
Nombre=Ejecuta
Boton=0
TipoAccion=Expresion
Activo=S
Visible=S

Expresion=ProcesarSQL( <T>EXEC nvk_sp_InsertaIncidencias_Semanal :tEmp, :tSem, :tQuin, :tUsu<T>, Temp.Texto, Temp.Num, NULO, Temp.TextoTemp01 )
[Acciones.Aceptar.Cerrar]
Nombre=Cerrar
Boton=0
TipoAccion=Ventana
ClaveAccion=Cerrar
Activo=S
Visible=S














[Acciones.Aceptar.ListaAccionesMultiples]
(Inicio)=Ejecuta
Ejecuta=Cerrar
Cerrar=(Fin)







































[Forma.ListaAcciones]
(Inicio)=Aceptar
Aceptar=Cerrar
Cerrar=(Fin)
