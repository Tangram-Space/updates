# AirPlay

Receptor de audio y duplicación de pantalla para **macOS 11 o posterior, Intel x86_64**, basado en UxPlay 1.73.7.

## Versiones y estado

- [channel.json](channel.json) identifica la **última release publicada** y su feed firmado.
- [source/version.env](source/version.env) identifica la revisión de fuentes que se está preparando. La publicación del canal se realiza únicamente después de compilar, firmar y comprobar el paquete correspondiente.
- La release **1.3.2/build 6** activó el canal. El usuario confirmó la instalación inicial en Big Sur y la consulta satisfactoria de actualizaciones desde AirPlay.
- **1.3.3/build 7 está publicada:** la [preparación nativa 39636510520](https://github.com/Tangram-Space/updates/actions/runs/39636510520) pasó. El canal estable apunta a su [paquete firmado](https://github.com/Tangram-Space/updates/releases/tag/airplay-v1.3.3-b7); las verificaciones posteriores se registran en [channel.json](channel.json).
- Los [informes por versión](verification/) distinguen compilación, firmas, disponibilidad pública, pruebas nativas y sus límites. La ejecución en un runner Intel no sustituye la prueba de reposo/reproducción en el iMac.

## Uso del actualizador

**Buscar actualizaciones**, dentro de Preferencias, consulta el canal y abre la interfaz de Sparkle. La versión 1.3.3 añade **Buscar actualizaciones automáticamente**, desactivada inicialmente. La elección se guarda entre aperturas de AirPlay. Al activarla, Sparkle programa consultas con un intervalo de 24 horas; una versión disponible aparece en Preferencias y habilita **Actualización disponible…** en el menú, sin abrir ventanas ni quitar el foco durante la reproducción. Al elegir ese ítem se abre el aviso de Sparkle. La descarga y la instalación siguen dependiendo de una elección del usuario.

Desactivar la opción detiene las siguientes consultas automáticas; la búsqueda manual permanece disponible. Una consulta que ya se haya iniciado puede terminar.

La versión incorpora una [comprobación nativa del actualizador](../../ci/airplay/updater-check/README.md): usa el código de producción en una app aislada para comprobar la opción inicialmente apagada, su persistencia, el aviso silencioso y la apertura manual de la interfaz estándar. Su resultado fue PASS en macOS 15.7.9 Intel, con el código real de producción y Sparkle 2.9.6; el [informe](verification/1.3.3-7/updater-policy.json) conserva las tres fases. Esta comprobación es distinta del [ensayo de instalación y reapertura con Sparkle](../../ci/airplay/update-smoke/README.md).

El feed estable es:

```
https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml
```

Las claves y el feed de AirPlay son independientes de los demás productos de este repositorio.

## Fuentes y mantenimiento

- [source/](source/): código, recursos, scripts, manifiestos y licencias del proyecto.
- [source-snapshot.json](source-snapshot.json): identidad, procedencia y manifiesto de la revisión de fuentes.
- [Instrucciones del proyecto](source/README.md): requisitos y construcción.
- [Actualizaciones](source/docs/UPDATES.md): configuración, comportamiento y preparación/publicación.
- [CI](../../ci/airplay/README.md): construcción y firma con la configuración existente.

Las fuentes correspondientes y sus dependencias se adjuntan a cada release. Los informes conservan hashes, versiones y procedencia, sin incluir la clave privada. El identificador `local.chevy.airplay` se mantiene para preservar preferencias e identidad.

### Publicar la próxima versión

La configuración inicial del canal **ya está hecha**. Las nuevas versiones reutilizan el Actions Secret `AIRPLAY_SPARKLE_PRIVATE_KEY` y la variable pública `AIRPLAY_UPDATE_CONFIG_PLIST`; no requieren generar, exportar ni volver a cargar una clave. El workflow comprueba su correspondencia antes de compilar.

El mantenimiento consiste en publicar las fuentes revisadas con un build creciente, ejecutar la preparación firmada, revisar los informes, publicar el ZIP final y sus fuentes, y actualizar el feed con sus bytes firmados exactos. Después se comprueban las descargas anónimas y la instalación con Sparkle, y se actualizan los informes y el estado del canal. El [procedimiento del repositorio](../../README.md#preparar-y-publicar-airplay) separa estos pasos del alta inicial.

## Licencias

Se conservan [LICENSE](source/LICENSE), [THIRD_PARTY.md](source/THIRD_PARTY.md) y los textos de [licenses/](source/licenses/), además de los avisos originales en las fuentes.
