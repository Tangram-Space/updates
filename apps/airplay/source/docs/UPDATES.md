# Actualizaciones de AirPlay

AirPlay utiliza **Sparkle 2.9.6** y su interfaz estándar para buscar, verificar, descargar e instalar versiones. El canal público de Tangram está activo desde **1.3.2/build 6**. La versión publicada se consulta en [channel.json](../../channel.json); una revisión de fuentes no se considera publicada hasta que el paquete y el feed firmados estén disponibles.

## Comportamiento de la app

**Buscar actualizaciones**, en Preferencias, inicia una consulta manual o trae al frente una actualización ya encontrada. El usuario decide descargar e instalar; la app no se reemplaza durante una reproducción por una decisión automática.

Desde **1.3.3/build 7**, la casilla **Buscar actualizaciones automáticamente** permite activar consultas programadas. Su valor inicial es desactivado. La clave propia `AirPlay.AutomaticUpdateChecks` conserva la elección; un valor antiguo de Sparkle no puede activar la nueva preferencia por sí solo.

Con la opción apagada, el arranque no construye ni inicia `SPUUpdater`. Con la opción activada, se utiliza el planificador de Sparkle, con intervalo de 24 horas y su fecha persistente de última comprobación. No se añade un temporizador paralelo. Desactivar la casilla impide nuevas consultas programadas, incluidas las que aún no habían comenzado. Una consulta manual sigue disponible.

Se deshabilitan siempre las descargas automáticas y el envío del perfil del sistema. El delegado permite consultas manuales y programadas autorizadas, y rechaza sondeos informativos ajenos a esas rutas.

Las consultas automáticas usan [avisos discretos de Sparkle](https://sparkle-project.org/documentation/gentle-reminders/): la app publica **Actualización disponible…** en el menú de la barra y muestra la versión en Preferencias. No abre ventanas ni cambia el foco. Abrir ese aviso llama a `checkForUpdates`, que muestra el diálogo estándar. Cerrar u omitir la actualización retira el aviso de la sesión.

El estado **Al día** exige que Sparkle informe `OnLatestVersion` o `OnNewerThanLatestVersion`. Una configuración ausente, un error de red/firma o una versión incompatible no se presentan como éxito.

## Canal e identidad

Feed fijo:

```
https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml
```

La configuración pública está en `apps/airplay/UpdateConfig.plist` del repositorio compartido y en la variable pública de CI `AIRPLAY_UPDATE_CONFIG_PLIST`. El builder la valida y la incorpora a `Info.plist` antes de firmar. La ruta local del builder es `updates/UpdateConfig.plist`; la clave privada no forma parte de estos archivos.

El módulo exige HTTPS, clave pública Ed25519 válida, `SURequireSignedFeed=true` y `SUVerifyUpdateBeforeExtraction=true`. El delegado conserva la URL del bundle; no acepta un feed histórico alternativo en UserDefaults. La identidad `local.chevy.airplay`, la URL y la clave pública se mantienen entre versiones.

La clave de firma existente se conserva en el secreto de Actions `AIRPLAY_SPARKLE_PRIVATE_KEY`. Sólo los pasos de firma/verificación de correspondencia la reciben. No se solicita, imprime, publica ni rota durante una actualización normal. El procedimiento original de alta y las herramientas de mantenimiento están documentados en [CI](../../../../ci/airplay/README.md).

## Dependencia fijada para Big Sur

- Distribución: [Sparkle-2.9.6.tar.xz](https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz).
- SHA-256: `52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`.
- Fuentes: tag `2.9.6`, commit `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`.

El objetivo de la app permanece en macOS 11 Intel. Sparkle se incorpora al bundle conservando sus helpers y firmas del proveedor; no se vuelve a firmar con `codesign --deep`. GStreamer continúa como framework externo ya instalado en el iMac.

`app_updater.mm` usa ARC y las APIs de [SPUUpdater](https://sparkle-project.org/documentation/api-reference/Classes/SPUUpdater.html) y [SPUStandardUserDriverDelegate](https://sparkle-project.org/documentation/api-reference/Protocols/SPUStandardUserDriverDelegate.html). El controller y el puente de vídeo conservan su gestión de memoria y ciclo de reproducción.

## Preparar y publicar una versión

1. Aumentar la versión visible y el entero creciente de build en `version.env`. Actualizar los manifiestos de las fuentes y las traducciones.
2. Ejecutar las verificaciones de fuentes y la construcción nativa del workflow `airplay-build.yml`. El job verifica el canal existente, compila, comprueba recursos/AppKit y ejecuta las pruebas del actualizador antes de firmar.
3. Reutilizar el último appcast firmado. La preparación exige un build superior y conserva las entradas anteriores; no genera deltas. Firma y verifica tanto el ZIP final como el XML.
4. Publicar primero los archivos finales y las fuentes correspondientes en el tag `airplay-vVERSION-bBUILD`.
5. Publicar en el feed los bytes exactos de `release/appcast.xml`. No editar ni reformatear el XML firmado y no sustituir el ZIP por una copia anterior a la firma.
6. Comprobar las descargas públicas y ejecutar el smoke nativo sobre la release exacta. Registrar resultados y límites antes de comunicar que la versión está disponible.

Los jobs de construcción/verificación mantienen permisos de lectura y no publican por su cuenta. Los artefactos incluyen hashes, versiones, logs acotados y estado de firma. La configuración de otros productos de Tangram permanece separada.

## Comprobaciones y alcance

- `--airplay-check` comprueba recursos e inicialización de los elementos necesarios de GStreamer.
- `--airplay-ui-check` construye Preferencias y volumen fuera de pantalla en diez idiomas, sin iniciar el receptor ni acceder al canal.
- La prueba del actualizador compila su código real con Sparkle y comprueba opt-in, persistencia, avisos discretos y la ruta manual en un bundle aislado.
- El smoke de instalación parte de una app A de prueba y exige que Sparkle instale y reabra el paquete B real. El cierre normal posterior se observa por PID y estado de salida; no se infiere de una señal de limpieza.
- Las pruebas de CI no acreditan reposo físico del iMac, inicio de su sesión, streaming o alternancia de iPhone/Apple TV. Esas comprobaciones se registran por separado cuando el usuario las realiza.

En 1.3.2, el usuario confirmó la instalación inicial en Big Sur y mostró la consulta satisfactoria del canal. Los informes nativos de esa versión están en [verification/1.3.2-6](../../verification/1.3.2-6/). La transición de esa versión a una siguiente mediante Sparkle en el iMac es una comprobación posterior.

## Mantenimiento local

La ruta de construcción sin instalar continúa disponible para quien mantiene el proyecto:

```bash
/bin/bash scripts/build-install.sh --build-only
```

Requiere la configuración pública y las dependencias existentes. Los scripts `configure-updates.sh`, `make-release.sh` y `update_release.py` conservan la ruta de firma local con la cuenta existente del Llavero; no es necesario ejecutarlos para recibir una actualización desde la app.

Una app ya firmada no se modifica para cambiarle el feed. Las siguientes versiones sustituyen el bundle completo y conservan las preferencias fuera de él.
