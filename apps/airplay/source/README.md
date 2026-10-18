# AirPlay para macOS

AirPlay es una aplicación de barra de menús para recibir audio y duplicación de pantalla mediante [UxPlay](https://github.com/FDH2/UxPlay). Añade una interfaz nativa de AppKit, una ventana de vídeo que recuerda su geometría y un control de volumen propio. El receptor se ejecuta en el mismo proceso que la aplicación; después de instalarla, se abre desde Aplicaciones y no necesita una Terminal abierta.

La versión preparada en este árbol es **1.3.2, build 6**, destinada a **macOS 11 Big Sur en Intel x86_64**. Se basa en UxPlay **1.73.7**, commit `df67c212a433cf6dda3676dd40c097900d24e645`. El repositorio del proyecto es [Tangram-Space/airplay](https://github.com/Tangram-Space/airplay), privado y con `main` como rama principal. Esta candidata todavía no tiene una release ni un canal de actualizaciones operativo. Su entrega queda pendiente de completar la publicación firmada y probar una actualización desde la app; el trabajo se detalla en [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md).

## Uso

Al abrir AirPlay aparece un acceso en la barra de menús. El nombre anunciado al emisor es el nombre del equipo, salvo que se haya guardado otro en Preferencias.

- **Clic izquierdo, con una fuente conectada:** abre el panel compacto de volumen de AirPlay, con pista de cápsula, porcentaje y un pequeño parlante de silencio en la cabecera. Este control es independiente del volumen de macOS y conserva su ajuste entre aperturas. Moverlo a un valor positivo desactiva el silencio.
- **Clic derecho o Control-clic:** abre el menú con el estado del receptor, Mostrar ventana, Preferencias y Salir.
- **Preferencias:** permite cambiar el nombre anunciado, elegir Abrir al iniciar sesión, abrir los registros y consultar el estado de las actualizaciones. Buscar actualizaciones aparece a la derecha de la versión, con el estado debajo. El cambio de nombre se aplica al volver a abrir la app.

Preferencias sólo se abre al solicitarlo. Mostrar ventana recupera una ventana de vídeo existente. El vídeo utiliza `glimagesink`; conserva el ajuste al girar la fuente, permite redimensionar la ventana manualmente y guarda geometría separada para las orientaciones vertical y horizontal.

La interfaz sigue los idiomas preferidos de macOS. Se incluyen `en`, `en-US`, `en-GB`, `en-CA`, `en-AU`, `es`, `es-ES`, `es-MX`, `es-AR` y `es-419`, con los idiomas base como alternativa. El acceso de la barra usa un símbolo de macOS. El icono de la aplicación es un dibujo original: pantalla blanca cerrada, barras azules y fondo grafito. AppKit genera sus diez resoluciones en el Mac y `iconutil` las incorpora a `AirPlay.icns` antes de firmar el bundle.

## Requisitos para compilar

El flujo de este proyecto **requiere las dependencias ya instaladas**. No instala un gestor de paquetes ni modifica el SDK seleccionado del sistema.

| Dependencia | Configuración de referencia y uso |
| --- | --- |
| macOS y arquitectura | Big Sur 11, Intel `x86_64`; la compilación fija el objetivo mínimo en `11.0`. |
| Herramientas de Apple | Un entorno de desarrollo seleccionado que permita a `xcrun` encontrar `clang`, `clang++`, el SDK de macOS, `otool`, `lipo` y Python 3. |
| CMake | La configuración de referencia utiliza **3.31.12**; indicar su ejecutable en `AIRPLAY_CMAKE`. |
| GStreamer | Runtime y SDK oficiales **1.28.8**, con `pkg-config`, cabeceras, plugins y `libcrypto.a`. Ruta habitual: `/Library/Frameworks/GStreamer.framework/Versions/1.0`. |
| libplist | **2.8.0**, instalada como biblioteca estática. `AIRPLAY_DEPS_PREFIX` debe contener `lib/libplist-2.0.a` y sus archivos de desarrollo. |
| Sparkle | Archivo oficial **2.9.6**. El instalador verifica su SHA-256 y extrae el framework; puede descargar el archivo fijado o utilizar uno local. |

Python 3 se usa durante la preparación del instalador y de los archivos plist; no es un requisito de ejecución de AirPlay. GStreamer sigue instalado como framework externo: la app no incluye otra copia del runtime o del SDK. Sparkle sí se incorpora al bundle.

## Preparar sin instalar

Con una configuración pública de canal válida en `updates/UpdateConfig.plist`, el modo de preparación permite construir y comprobar la próxima app sin cerrar ni reemplazar la que está funcionando:

```bash
/bin/bash scripts/build-install.sh --build-only
```

El resultado queda en una carpeta aislada de construcción. El ZIP de preparación aún necesita la firma EdDSA y la publicación descritas en [docs/UPDATES.md](docs/UPDATES.md); no es por sí mismo una actualización distribuida. Si falta el canal, la preparación se detiene antes de compilar.

La plantilla `ci/build-macos.yml.in` está fuera de la carpeta de workflows y no se ejecuta en GitHub. Contiene una propuesta de compilación para un repositorio público de distribución y exige una habilitación explícita. La privacidad del repositorio actual continúa vigente.

## Compilar e instalar — ruta de mantenimiento

Los comandos de esta sección conservan la ruta de instalación anterior para el responsable del proyecto. **No se entrega esta candidata al usuario mientras las actualizaciones sigan pendientes.**

En el iMac del prototipo, el instalador detecta las rutas conocidas de CMake, libplist y las fuentes. Para indicar otras rutas, prepará opcionalmente una configuración local desde la raíz del proyecto:

```bash
cp config/local.env.example config/local.env
```

Si creaste `config/local.env`, completá sólo las rutas que quieras seleccionar explícitamente:

| Variable | Qué debe indicar |
| --- | --- |
| `AIRPLAY_CMAKE` | Ruta absoluta al ejecutable de CMake. Si se omite, se busca primero la herramienta conservada en el soporte interno de AirPlay, luego la instalación del prototipo y después el `PATH`. |
| `AIRPLAY_DEPS_PREFIX` | Prefijo de instalación de libplist y sus archivos de desarrollo. Si se omite, se reutiliza el prefijo del prototipo cuando existe; en otro caso se utiliza `/usr/local`. |
| `AIRPLAY_GSTREAMER_ROOT` | Directorio de la versión instalada del framework de GStreamer. |
| `AIRPLAY_SPARKLE_ARCHIVE` | Opcional: archivo oficial `Sparkle-2.9.6.tar.xz`. Vacío permite descargar la URL fijada en `version.env`. |
| `AIRPLAY_UPSTREAM_REPO` | Opcional: checkout Git de UxPlay que contenga el commit fijado. Si se omite, se reutiliza el checkout del prototipo cuando contiene ese commit; en otro caso se obtiene desde upstream. |
| `AIRPLAY_ICON_FILE` | Opcional: otro icono `.icns` proporcionado por el responsable del proyecto. Vacío utiliza el icono original incluido en el generador. |

`config/local.env` es configuración propia del equipo y queda fuera de Git. Las versiones, el commit y la suma del archivo de Sparkle se conservan en [version.env](version.env) y [upstream.lock.json](upstream.lock.json).

Cerrá el receptor desde **Salir AirPlay**, y cerrá cualquier otra instancia de UxPlay o AirServer que esté abierta. Ejecutá:

```bash
/bin/bash scripts/build-install.sh
```

El script utiliza Bash compatible con macOS, localiza Python 3 mediante `xcrun` y genera el instalador a partir de [scripts/package-bootstrap.py](scripts/package-bootstrap.py) y [scripts/bootstrap.command.in](scripts/bootstrap.command.in). Prepara una copia aislada del commit de upstream, verifica los archivos originales, aplica `overlay/` y comprueba los archivos resultantes con los manifiestos del proyecto.

La instalación compila el ejecutable y prepara el bundle con su icono, sus diez localizaciones y Sparkle. Antes de reemplazar una app existente, comprueba la arquitectura, los enlaces a bibliotecas, el icono, la firma y los dos controles nativos descritos abajo. Los respaldos nuevos quedan en una carpeta oculta de respaldo junto al destino para conservar los renombrados dentro del mismo volumen.

Si encuentra una única instalación propia, actualiza **esa misma ubicación** y conserva la anterior como respaldo. Para una instalación nueva, utiliza `/Applications` si tiene permiso de escritura, o `~/Applications`. No usa `sudo` ni reemplaza una app ajena que tenga el mismo nombre. Si encuentra dos instalaciones propias, se detiene para evitar actualizar la equivocada. Si falla el reemplazo, intenta restaurar el respaldo y registra el resultado.

La compilación local utiliza firma ad hoc. El canal de distribución y firma de actualizaciones se configura por separado en [docs/UPDATES.md](docs/UPDATES.md).

## Corrección del icono y los accesos de herramientas

La instalación 1.3.1 incluye el icono y, una vez confirmado el bundle nuevo, organiza únicamente los bundles reconocidos bajo `~/Applications/UxPlay-Prueba-1.73.7`. Conserva la distribución completa de CMake 3.31.12 en `~/Library/Application Support/AirPlay/BuildTools.noindex` y archiva las copias propias de prueba en `LegacyApps.noindex`. Las fuentes y bibliotecas estáticas permanecen en sus rutas existentes; una aplicación no identificada se conserva y se informa.

Los helpers comprueban identidad, propietario, procesos y rutas antes de cada traslado. Si una acción falla, intentan devolver ese elemento a su ubicación anterior. Una limpieza parcial conserva la aplicación nueva ya instalada y queda indicada en los registros. El refresco posterior registra la app y reinicia una sola vez el Dock identificado del usuario, sin borrar ni reconstruir su base de Launchpad.

Para generar un único instalador desde las fuentes:

```bash
python3 scripts/package-bootstrap.py --output dist/Actualizar_AirPlay.command
```

Ese archivo incorpora las fuentes, traducciones, generador de icono y organización de herramientas. Se ejecuta en el Mac con `/bin/bash`, después de cerrar AirPlay y cualquier receptor anterior. Utiliza las dependencias existentes y conserva los controles nativos antes del reemplazo.

## Controles antes de instalar

El instalador ejecuta estos modos sobre el bundle preparado, con un entorno limpio y **antes de mover la versión anterior**:

| Modo | Qué comprueba |
| --- | --- |
| `--airplay-check` | Configuración del receptor, recursos de los diez idiomas e inicialización de GStreamer con los elementos de audio y vídeo necesarios, incluido `volume`. No inicia un receptor. |
| `--airplay-ui-check` | Construcción oculta de Preferencias y del control de volumen en los diez idiomas, presencia de controles, restricciones y geometría del formulario. Captura excepciones de AppKit. No inicia el receptor, consulta actualizaciones ni modifica preferencias. |

Ambos deben terminar con código `0`. Un fallo impide reemplazar la app y queda en los registros de instalación. El control de selectores Objective-C también forma parte de la compilación de la interfaz y del actualizador mediante `-Werror=objc-method-access`.

**Estado de validación:** el usuario confirmó la instalación y las Preferencias funcionales de 1.3. Las verificaciones de fuentes y empaquetado de esta candidata se ejecutan fuera de macOS; su compilación, los controles nativos y el resultado visual todavía deben comprobarse en el Mac de destino. Las referencias a 1.0–1.2 en `manifests/baselines/` conservan la procedencia de los prototipos anteriores y no sustituyen esa comprobación.

## Actualizaciones

El receptor funciona sin un canal configurado. En ese caso, Preferencias muestra **«Actualizaciones todavía no configuradas»** y no presenta el estado como si ya se hubiera comprobado una versión remota.

La entrada local para habilitar el canal es `updates/UpdateConfig.plist`, con la URL del feed y la clave pública que se incorporarán al bundle. Ese archivo no se incluye en el repositorio. La inicialización valida la configuración local; la consulta se inicia mediante **Buscar actualizaciones** en Preferencias.

Los pasos para configurar el feed, firmar versiones y preparar una publicación están en [docs/UPDATES.md](docs/UPDATES.md). Los scripts relacionados son `scripts/configure-updates.sh`, `scripts/make-release.sh` y `scripts/update_release.py`.

## Registros y estructura del proyecto

**Mostrar registros**, dentro de Preferencias, abre `~/Library/Logs/AirPlay`. El instalador también informa dónde guardó su ZIP de diagnóstico, la app resultante y el respaldo de la versión anterior. Conservá ese ZIP si una compilación o un control nativo falla: incluye la etapa y el motivo del fallo.

| Ruta | Contenido |
| --- | --- |
| `overlay/` | Archivos modificados o añadidos sobre el commit exacto de UxPlay. |
| `resources/` | Plantilla del bundle, configuración del receptor y traducciones. |
| `scripts/` | Preparación de fuentes, construcción, instalación y preparación de versiones. |
| `manifests/` | Sumas de verificación y referencias de los prototipos anteriores. |
| `licenses/` | Textos completos de las licencias adicionales y su procedencia. |

El identificador `local.chevy.airplay` se conserva para que las instalaciones sucesivas compartan las preferencias y la identidad de la app. El historial funcional está en [CHANGELOG.md](CHANGELOG.md); las dependencias y sus avisos, en [THIRD_PARTY.md](THIRD_PARTY.md). La licencia principal se conserva en [LICENSE](LICENSE).
