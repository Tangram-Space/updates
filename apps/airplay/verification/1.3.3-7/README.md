# Verificación de AirPlay 1.3.3, build 7

## Resultado

PASS para compilación nativa, firma, comportamiento del actualizador, disponibilidad pública e instalación/reapertura/cierre normal del paquete publicado. El código compilado es `ac0620635e6574e95a37ebbc78310b76891837e3`; el ZIP y el feed permanecieron idénticos durante las comprobaciones.

| Comprobación | Evidencia | Alcance |
| --- | --- | --- |
| Bundle y AppKit | [Build 39636510520](https://github.com/Tangram-Space/updates/actions/runs/39636510520), [preparation.json](preparation.json) | Intel, objetivo mínimo macOS 11, recursos/icono, elementos de GStreamer, firma de código, ida y vuelta del archivo y layouts de Preferencias/volumen en diez idiomas. |
| Opción automática | [updater-policy.json](updater-policy.json) | Updater de producción y Sparkle 2.9.6 reales en una app aislada. Apagada de entrada, opt-in/out persistente, feed firmado, cero ventanas y sin activación durante la consulta programada; aviso estándar accesible manualmente y cierre sin instalar. |
| Firmas | [signing.json](signing.json) | ZIP final y appcast firmados y verificados con la clave existente. |
| Fuentes correspondientes | [sources.json](sources.json) | Fuentes/dependencias/licencias del commit compilado; manifiestos coincidentes. No se afirma reproducibilidad binaria bit por bit. |
| Descarga anónima | [Run 39638593652](https://github.com/Tangram-Space/updates/actions/runs/39638593652), [availability.json](availability.json) | HTTPS sin autenticación; ZIP/feed idénticos a los archivos ya firmados. |
| Instalación y ciclo de vida | [Run 39639398879](https://github.com/Tangram-Space/updates/actions/runs/39639398879), [sparkle-update-smoke.json](sparkle-update-smoke.json) | Sparkle selecciona, verifica, descarga e instala la B real desde una A de prueba. Sparkle reabre B; el observador no la lanza. Después se solicita cierre normal por AppKit y se exige salida 0 observada por el kernel, preferencias sincronizadas y parada RAOP. |

El [manifiesto de verificación](verification.json) fija los hashes de los informes. Las dos pruebas de Cocoa se ejecutaron en macOS 15.7.9 Intel.

## Alcance y límites

La aplicación A del ensayo de instalación es sintética y usa un driver de prueba. La política y el aviso estándar se comprueban por separado con el updater de producción en un bundle aislado. Estos ensayos no reproducen la conexión con un Apple TV o iPhone ni ejecutan el sistema Big Sur del iMac.

El usuario confirmó previamente la instalación de 1.3.2 y la consulta de actualizaciones desde el iMac. La transición de su instalación 1.3.2 a 1.3.3, el inicio de sesión, el reposo y la reproducción/reconexión en ese equipo requieren comprobación allí.

## Corrección acotada del ensayo

El primer run `39638314465` instaló, reabrió y observó un cierre normal de B con salida 0, pero el observador escribió el entero JSON `1` en lugar del booleano `true` para `exited_normally`. El verificador estricto detuvo el ensayo antes de leer el registro de preferencias. El commit `346ddc15a0503dda526afca04768d9f0b1070a2c` corrigió únicamente esa serialización, sin relajar comprobaciones ni modificar la app, sus fuentes de producción, el ZIP o el feed. El run posterior `39639398879` completó todos los requisitos.
