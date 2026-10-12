
[Forma]
Clave=nvk_ProcesarNominaQuincenal
Icono=0
Modulos=(Todos)
MovModulo=(Todos)
Nombre=Procesar Nómina Quincenal

ListaCarpetas=Lista
CarpetaPrincipal=Lista
PosicionInicialIzquierda=773
PosicionInicialArriba=467
PosicionInicialAlturaCliente=127
PosicionInicialAncho=290
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
[Acciones.Aceptar]
Nombre=Aceptar
Boton=0
NombreDesplegar=&Aceptar
EnBarraAcciones=S
Activo=S
Visible=S

Multiple=S
ListaAccionesMultiples=(Lista)
Antes=S
GuardarAntes=S
AntesExpresiones=Asigna(Temp.Texto,Info.Empresa)<BR>Asigna(Temp.TextoTemp01,Info.Usuario)<BR>Asigna(Temp.Num,Info.nvk_Quincena)
[Acciones.Cerrar]
Nombre=Cerrar
Boton=0
NombreDesplegar=&Cerrar
EnBarraAcciones=S
TipoAccion=Ventana
ClaveAccion=Cerrar
Activo=S
Visible=S






[Acciones.Aceptar.Generar]
Nombre=Generar
Boton=0
TipoAccion=Expresion
Activo=S
Visible=S

Expresion=ProcesarSQL( <T>EXEC nvk_sp_InsertaIncidencias_Quincenal :tEmp, :tSem, :tQuin, :tUsu<T>, Temp.Texto, NULO, Temp.Num, Temp.TextoTemp01 )
[Acciones.Aceptar.Cerrar]
Nombre=Cerrar
Boton=0
TipoAccion=Ventana
ClaveAccion=Cancelar
Activo=S
Visible=S















[Lista.ListaEnCaptura]
(Inicio)=Info.Empresa
Info.Empresa=Info.nvk_Quincena
Info.nvk_Quincena=(Fin)

[Lista.Info.nvk_Quincena]
Carpeta=Lista
Clave=Info.nvk_Quincena
Editar=S
LineaNueva=S
ValidaNombre=S
3D=S
Tamano=20
ColorFondo=Blanco


[Acciones.Aceptar.ListaAccionesMultiples]
(Inicio)=Generar
Generar=Cerrar
Cerrar=(Fin)















[Forma.ListaAcciones]
(Inicio)=Aceptar
Aceptar=Cerrar
Cerrar=(Fin)
