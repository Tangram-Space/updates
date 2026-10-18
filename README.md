# Tangram Updates

Repositorio público de fuentes y distribución [Tangram-Space/updates](https://github.com/Tangram-Space/updates), compartido por aplicación. AirPlay es la primera incorporación: **1.3.2, build 6**, para macOS 11 o posterior en Intel. La clave de firma está provisionada y los workflows manuales están activos. La compilación de CI, la primera release firmada y la validación del canal de actualizaciones están pendientes.

## Contenido

| Ruta | Función |
| --- | --- |
| [apps/airplay/source/](apps/airplay/source/) | Los 69 archivos del proyecto preparado: modificaciones de UxPlay, recursos, construcción, verificadores, manifiestos y licencias. La selección de dependencias se aísla de Homebrew para mantener coherentes las cabeceras y bibliotecas del SDK. |
| [apps/airplay/source-snapshot.json](apps/airplay/source-snapshot.json) | Identidad y comprobación del snapshot, sin importar el historial privado de desarrollo. |
| [ci/airplay/](ci/airplay/) | Dependencias fijadas, configuración pública, firma y recolección acotada de artefactos. |
| `.github/workflows/*.yml` | Dos workflows **manuales** activos después de provisionar la firma; no publican Releases ni modifican el feed. |
| [apps/airplay/channel.json](apps/airplay/channel.json) | Estado del canal; los valores pendientes deben completarse con resultados reales. |

## Preparar y publicar la primera versión

1. **Publicar las fuentes revisadas** en `main` del repositorio público `Tangram-Space/updates`. Las plantillas rechazan otro repositorio, una rama distinta o un destino privado. La construcción usa un runner Intel y no modifica la app instalada en ningún Mac personal.

2. **Preparar la firma una sola vez en el Mac Intel.** Ejecutar [Preparar_Firma_AirPlay.command](ci/airplay/Preparar_Firma_AirPlay.command) con el usuario habitual. Descarga Sparkle 2.9.6 con SHA256 y firmas comprobados; crea o reutiliza la cuenta `local.chevy.airplay` del Llavero y copia su export privado al portapapeles sin mostrarlo. El usuario lo pega personalmente en el Actions Secret `AIRPLAY_SPARKLE_PRIVATE_KEY` de este repositorio y vuelve a Terminal para presionar Enter: se eliminan la copia temporal y el contenido del portapapeles si sigue siendo esa clave. El original permanece en el Llavero. Nunca pegar la privada en el chat, el repositorio o un artefacto. El comando sólo prepara la firma y no instala ni modifica AirPlay. Los helpers de CI no generan ni rotan claves; [su documentación](ci/airplay/README.md) describe la importación temporal y la firma oficial por stdin.

3. **Obtener la configuración pública.** Los workflows `airplay-public-key.yml` y `airplay-build.yml` están activados en este repositorio público revisado y la variable `AIRPLAY_PUBLIC_CI_ENABLED` está en `true`. Ejecutar manualmente el workflow de configuración pública. Su artefacto contiene únicamente `UpdateConfig.plist`, derivado de la clave existente. Guardar el XML completo como variable pública `AIRPLAY_UPDATE_CONFIG_PLIST`; no es un secreto.

4. **Ejecutar manualmente la preparación firmada.** Comprueba que la clave coincide antes de compilar, ejecuta las verificaciones del bundle y de AppKit, y firma y verifica el ZIP y el appcast con Sparkle 2.9.6. El artefacto contiene `release/` con los archivos finales y sus informes. El workflow no crea Releases, no cambia el feed ni instala AirPlay.

5. **Publicar los archivos finales:** primero `release/AirPlay-1.3.2-6.zip` en la release de tag `airplay-v1.3.2-b6`, junto con las fuentes correspondientes; después, los bytes exactos de `release/appcast.xml` en `feeds/airplay/stable/appcast.xml`. No editar el XML firmado ni sustituir el ZIP por el paquete previo a la firma.

La dirección prevista del feed es:

```text
https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml
```

Antes de entregar la instalación inicial, ejecutar `apps/airplay/source/scripts/verify-published-release.py --release-dir <carpeta-release>` para comprobar descargas anónimas e integridad. La ejecución en Big Sur y la transición real a un build superior desde AirPlay siguen pendientes: una compilación de CI y firmas válidas, por sí solas, no prueban esa actualización.

## Licencias

AirPlay se basa en UxPlay bajo **GPL-3.0-or-later**. Conservar la [licencia principal](apps/airplay/source/LICENSE), los [avisos de terceros](apps/airplay/source/THIRD_PARTY.md) y sus [textos completos](apps/airplay/source/licenses/) junto con las fuentes de cada versión distribuida.
