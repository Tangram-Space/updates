# AirPlay

Receptor de audio y duplicación de pantalla para **macOS 11 o posterior, Intel x86_64**, basado en UxPlay 1.73.7.

## Versiones y estado

- [channel.json](channel.json) identifica la **última release publicada** y su feed firmado.
- [source/version.env](source/version.env) identifica la revisión de fuentes que se está preparando. La publicación del canal se realiza únicamente después de compilar, firmar y comprobar el paquete correspondiente.
- La release **1.3.2/build 6** activó el canal. El usuario confirmó la instalación inicial en Big Sur y la consulta satisfactoria de actualizaciones desde AirPlay.
- Los [informes por versión](verification/) distinguen compilación, firmas, disponibilidad pública, pruebas nativas y sus límites. La ejecución en un runner Intel no sustituye la prueba de reposo/reproducción en el iMac.

## Uso del actualizador

**Buscar actualizaciones**, dentro de Preferencias, consulta el canal y abre la interfaz de Sparkle. En 1.3.3 se añade **Buscar actualizaciones automáticamente**, desactivada inicialmente. Al activarla, Sparkle programa consultas cada 24 horas; las versiones disponibles aparecen en el menú y en Preferencias sin abrir avisos sobre la reproducción. La descarga y la instalación siguen dependiendo de una elección del usuario.

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

## Licencias

Se conservan [LICENSE](source/LICENSE), [THIRD_PARTY.md](source/THIRD_PARTY.md) y los textos de [licenses/](source/licenses/), además de los avisos originales en las fuentes.
