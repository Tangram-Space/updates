# Actualizaciones de AirPlay

AirPlay incorpora Sparkle 2.9.6 y su interfaz estándar para buscar, descargar, verificar e instalar actualizaciones. La primera compilación lleva el actualizador integrado y muestra **«Las actualizaciones todavía no están configuradas»** mientras no exista un canal real con su URL y clave pública. Crear el repositorio de código no activa ese canal por sí solo.

La candidata 1.3.2 está en preparación y no debe entregarse como una actualización operativa. El [plan de activación](RELEASE_PLAN.md) distingue el trabajo local preparado, la configuración externa pendiente y la prueba final en el iMac. `scripts/build-install.sh --build-only` permite preparar el bundle sin cerrar ni reemplazar la app instalada, pero exige una configuración de canal válida.

La configuración de reproducción, el audio, los decodificadores y la ventana de vídeo mantienen sus implementaciones probadas. Las futuras actualizaciones reemplazan `AirPlay.app`; el framework GStreamer instalado en el Mac continúa siendo una dependencia externa de esta versión.

## Estado de esta entrega

| Componente | Estado |
| --- | --- |
| Módulo Sparkle, CMake y botón de Preferencias | Implementados; integración preparada para el compilador del Mac |
| Framework y herramientas oficiales Sparkle 2.9.6 | Descarga verificada por SHA256; Mach-O Intel y mínimos de macOS inspeccionados |
| Clave privada del canal | Se crea o reutiliza únicamente en el Llavero del Mac cuando se ejecuta la configuración |
| URL de distribución y clave pública incluidas en la app | Pendientes de definir; la compilación inicial las omite |
| Repositorio remoto, release y appcast publicados | Estos scripts no crean ni publican ninguno |
| Compilación y actualización completa en el iMac | Requieren ejecutar el builder y, tras activar el canal, una actualización real firmada |

## Versión fijada para Big Sur

Se utiliza la distribución oficial:

- URL: <https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz>
- Tamaño: **15 554 568 bytes**.
- SHA256: **`52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`**.
- Tag `2.9.6`, commit `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`.

La inspección del archivo recibido encuentra slices `x86_64` con mínimo macOS 10.13 en el framework, Autoupdate, Updater.app, servicios XPC y herramientas de firma. Los binarios Intel se pueden cargar en Big Sur según sus metadatos; esto no sustituye una ejecución real en el Mac. El código fuente del módulo usa APIs disponibles en macOS 11. Sparkle 2.10 elevó el requisito a macOS 12, por lo que no es una actualización apropiada de esta dependencia para este iMac. La fuente de versión y digest es la [release oficial 2.9.6](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) y su [registro de GitHub](https://api.github.com/repos/sparkle-project/Sparkle/releases/tags/2.9.6); el cambio de mínimo está en la [release 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0).

El compilador Apple Clang 13 usa ARC sólo para `app_updater.mm`. El controlador y el puente Cocoa siguen con su gestión de memoria existente. Las definiciones locales de `NS_SWIFT_UI_ACTOR`, `NS_SWIFT_SENDABLE` y `NS_SWIFT_ASYNC`, sólo cuando el SDK no las define, omiten anotaciones para el importador Swift; no cambian la interfaz binaria de Objective-C ni los headers del proveedor. Ambos archivos del controlador y actualizador se compilan con `-Werror=objc-method-access`.

## Funcionamiento dentro de la app

`airplay_app_updater_initialize()` lee únicamente `Info.plist`, valida el canal y publica el estado de Preferencias. No construye `SPUUpdater`, no inicia su planificador y no accede a la red.

La acción explícita **Buscar actualizaciones** crea `SPUStandardUserDriver` y `SPUUpdater`, llama a `startUpdater:` y, en ese mismo turno de main, a `checkForUpdates`. Se deshabilitan las comprobaciones y descargas automáticas, el permiso para programarlas y el envío del perfil del sistema. El delegado rechaza además los tipos de comprobación no iniciados por esa acción. Sparkle conserva sus controles estándar de descarga, cancelación, instalación y reapertura. La documentación oficial describe tanto esta [configuración programática](https://sparkle-project.org/documentation/programmatic-setup/) como los [requisitos de integración](https://sparkle-project.org/documentation/).

La URL es HTTPS pública, sin credenciales, parámetros de consulta ni fragmentos. La clave pública es una codificación Base64 canónica de exactamente 32 bytes. El módulo exige `SURequireSignedFeed = true` y `SUVerifyUpdateBeforeExtraction = true`. La URL proviene del bundle: el delegado no acepta un cambio histórico de feed guardado en UserDefaults.

El estado **Al día** sólo se muestra si Sparkle devuelve `OnLatestVersion` o `OnNewerThanLatestVersion`. Una URL sin configurar, un feed vacío, un fallo de red o firma y una actualización incompatible no se presentan como éxito. Los motivos están definidos en [`SUErrors.h` de 2.9.6](https://github.com/sparkle-project/Sparkle/blob/2.9.6/Sparkle/SUErrors.h).

Para instalar, el agente de Sparkle envía un evento Apple Quit mediante `NSRunningApplication terminate` y espera la terminación del proceso. El override existente de `AirPlayApplication terminate:` guarda la ventana y preferencias, marca el cierre y permite que el worker de UxPlay termine normalmente. El actualizador conserva el delegado de GStreamer. La ruta está en [`InstallerProgressAppController.m`](https://github.com/sparkle-project/Sparkle/blob/2.9.6/Sparkle/InstallerProgress/InstallerProgressAppController.m#L399-L408).

## Configuración de compilación

`AIRPLAY_SPARKLE_ROOT` es el directorio extraído que **contiene** `Sparkle.framework`. CMake enlaza ese framework y añade `@loader_path/../Frameworks` conservando el runpath de GStreamer. El packager copia íntegramente Sparkle.framework a `AirPlay.app/Contents/Frameworks/` mediante `ditto`, manteniendo los enlaces y helpers firmados. Verifica las firmas del proveedor y firma después el bundle externo. No se debe usar `codesign --deep` para volver a firmar los componentes del proveedor.

La compilación inicial omite `SUFeedURL` y `SUPublicEDKey`. Todas las compilaciones mantienen estas opciones:

```xml
<key>SURequireSignedFeed</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SUEnableAutomaticChecks</key><false/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
```

La entrada pública opcional del builder es **`updates/UpdateConfig.plist`**. Sus únicas claves son `SUFeedURL`, `SUPublicEDKey` y `SparkleKeychainAccount`. El builder copia las dos primeras a `Info.plist` **antes** de firmar. La tercera identifica una cuenta del Llavero para las herramientas locales; no es una credencial ni se incorpora a la app. El script puede validar ese archivo sin red ni acceso al Llavero:

```bash
xcrun python3 scripts/update_release.py validate-config \
  --config updates/UpdateConfig.plist
```

## Crear el canal y su clave en el Mac

Primero se debe decidir el lugar público donde se servirán el XML y los ZIP. El repositorio de código puede ser privado. Para ese caso se necesita un lugar de distribución público separado si se quiere utilizar esta integración tal como está; no se añaden tokens compartidos de GitHub al bundle. Una URL privada que exige iniciar sesión no constituye un canal usable por este actualizador. No se elige automáticamente un servicio de pago ni se cambia la visibilidad del repositorio.

Una opción, cuando su visibilidad esté autorizada, es un appcast HTTPS estable y ZIPs de GitHub Releases. La URL del feed debe mantenerse entre versiones; la de cada ZIP debe identificar una release concreta. Los comandos siguientes usan variables deliberadamente sin valores de ejemplo ejecutables: `FEED_URL_REAL` y `DOWNLOAD_PREFIX_REAL` deben ser las direcciones aprobadas del canal.

Con el archivo oficial `Sparkle-2.9.6.tar.xz` disponible localmente, ejecutar desde el proyecto:

```bash
scripts/configure-updates.sh \
  --sparkle-archive "$SPARKLE_ARCHIVE" \
  --feed-url "$FEED_URL_REAL" \
  --output updates/UpdateConfig.plist
```

El script comprueba el hash íntegro del tar.xz, extrae una copia temporal y verifica las firmas de sus herramientas antes de ejecutarlas. Utiliza exclusivamente estos modos oficiales:

```bash
generate_keys --account local.chevy.airplay
generate_keys --account local.chevy.airplay -p
```

El primero reutiliza la clave existente o crea una nueva directamente en el Llavero del usuario. `-p` obtiene exclusivamente la clave pública. La clave privada nunca se exporta a un archivo, variable de entorno, repositorio, registro o chat. El código de esos modos está en [`generate_keys/main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.9.6/generate_keys/main.swift). Una segunda ejecución con la misma configuración verifica que cuenta, feed y clave pública sigan coincidiendo; no rota la clave ni sobrescribe otro canal.

Conservar el Llavero de ese Mac: las próximas releases deben estar firmadas con la misma clave. Si se pierde, hace falta planificar la recuperación o transición de firma; generar una clave nueva arbitrariamente no actualiza las apps que confían en la anterior.

Después se recompila el bundle con el archivo público generado. No se modifica `Info.plist` de una app ya firmada ni se escribe configuración de actualización en sus preferencias.

## Preparar una release sin publicar

Incrementar la versión visible y **CFBundleVersion**, que en este proyecto es un entero creciente. Construir AirPlay.app, ejecutar los controles del builder y usar un directorio nuevo para cada release. La preparación verifica la identidad del bundle, marca de instalación, arquitectura Intel, mínimo macOS 11, configuración pública, firmas de código y correspondencia con la clave del Llavero.

```bash
scripts/make-release.sh \
  --sparkle-archive "$SPARKLE_ARCHIVE" \
  --config updates/UpdateConfig.plist \
  --app "$AIRPLAY_APP_BUILT" \
  --download-url-prefix "$DOWNLOAD_PREFIX_REAL" \
  --output "$RELEASE_OUTPUT_NEW"
```

Desde la segunda publicación, incluir el último appcast publicado, guardado localmente sin editar:

```bash
  --previous-appcast "$PREVIOUS_SIGNED_APPCAST"
```

El script verifica su firma y exige que el nuevo número de build sea mayor. `generate_appcast` conserva las entradas existentes mediante `--maximum-versions 0`. No genera deltas (`--maximum-deltas 0`), por lo que la primera ruta de actualización consiste en descargar el bundle completo. El ZIP se crea con `ditto -c -k --sequesterRsrc --keepParent`, el comando recomendado en la [guía oficial de publicación](https://sparkle-project.org/documentation/publishing/).

Sparkle firma tanto el ZIP como el appcast. El script vuelve a verificar ambos con `sign_update --verify`, comprueba el enlace exacto, tamaño, versión y mínimo de sistema del nuevo item, y sólo entonces entrega un directorio con:

- `AirPlay-VERSION-BUILD.zip`: bundle completo firmado para esa release.
- `appcast.xml`: feed firmado, listo para servir **sin modificar sus bytes**.
- `release.json`: hashes SHA256, tamaños, URLs y `published: false` para revisar la entrega.

Las opciones utilizadas están definidas en las fuentes oficiales [`generate_appcast/main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.9.6/generate_appcast/main.swift) y [`sign_update/main.swift`](https://github.com/sparkle-project/Sparkle/blob/2.9.6/sign_update/main.swift).

## Publicación y primera activación

Los scripts anteriores terminan con archivos locales. Publicar el ZIP en su URL exacta, comprobar que sea accesible, y después publicar el appcast firmado en la URL estable son pasos separados. El XML firmado no debe ser reformateado, minificado, reescrito por una plantilla ni editado tras la firma. Cualquier corrección exige generar/verificar otra firma antes de publicarlo.

Tras publicar, el control de disponibilidad compara las descargas sin credenciales con los archivos locales ya firmados:

```bash
python3 scripts/verify-published-release.py --release-dir "$RELEASE_OUTPUT_NEW"
```

El informe distingue disponibilidad e integridad verificadas de una actualización nativa realmente ejecutada. No publica archivos, no cambia `release.json` y no reemplaza la verificación EdDSA de Sparkle. La plantilla `ci/build-macos.yml.in` tampoco constituye un canal activado: está fuera de `.github/workflows` y sólo prepara un artefacto de compilación.

La primera app con feed y clave públicos debe instalarse una vez mediante el builder de confianza: una versión inicial sin canal no puede descubrir por sí sola cuál es el canal correcto. A partir de esa activación, el botón de Preferencias invoca el flujo real de Sparkle. Se debe verificar una transición a un build superior en el Mac antes de describir las actualizaciones completas como probadas.

Este flujo no requiere compartir credenciales ni exportar claves. Una distribución personal con firma ad hoc exterior es diferente de distribuir una app ampliamente con Developer ID y notarización: no se garantiza que el primer arranque en otros Macs pase Gatekeeper sin intervención. La integración conserva las firmas originales de Sparkle; la decisión sobre una distribución más amplia permanece separada de esta entrega personal.
