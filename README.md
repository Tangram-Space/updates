# Tangram Updates

Repositorio público de fuentes y distribución [Tangram-Space/updates](https://github.com/Tangram-Space/updates), compartido por aplicación. AirPlay es la primera incorporación: **1.3.2, build 6**, para macOS 11 o posterior en Intel. La [primera release firmada](https://github.com/Tangram-Space/updates/releases/tag/airplay-v1.3.2-b6) y sus fuentes están publicadas. La [compilación nativa corregida](https://github.com/Tangram-Space/updates/actions/runs/39171983875) pasó las verificaciones del bundle, Preferencias y firmas. La comprobación anónima del canal y la instalación y reapertura reales con Sparkle también pasaron; los [informes de la versión](apps/airplay/verification/1.3.2-6/) conservan la evidencia y el alcance.

## Contenido

| Ruta | Función |
| --- | --- |
| [apps/airplay/source/](apps/airplay/source/) | Los 69 archivos del proyecto preparado: modificaciones de UxPlay, recursos, construcción, verificadores, manifiestos y licencias. La selección de dependencias se aísla de Homebrew para mantener coherentes las cabeceras y bibliotecas del SDK. |
| [apps/airplay/source-snapshot.json](apps/airplay/source-snapshot.json) | Identidad y comprobación del snapshot, sin importar el historial privado de desarrollo. |
| [ci/airplay/](ci/airplay/) | Dependencias fijadas, configuración pública, firma y recolección acotada de artefactos. |
| `.github/workflows/*.yml` | Cuatro workflows **manuales**: configuración pública, compilación firmada, comprobación anónima y prueba real de instalación con Sparkle. No publican Releases ni modifican el feed. |
| [apps/airplay/channel.json](apps/airplay/channel.json) | Identidad de la release publicada, clave pública y estado comprobado del canal. |

## Preparar y publicar versiones

1. **Publicar las fuentes revisadas** en `main` del repositorio público `Tangram-Space/updates`. Las plantillas rechazan otro repositorio, una rama distinta o un destino privado. La construcción usa un runner Intel y no modifica la app instalada en ningún Mac personal.

2. **Preparar la firma una sola vez en el Mac Intel.** Ejecutar [Preparar_Firma_AirPlay.command](ci/airplay/Preparar_Firma_AirPlay.command) con el usuario habitual. Descarga Sparkle 2.9.6 con SHA256 y firmas comprobados; crea o reutiliza la cuenta `local.chevy.airplay` del Llavero y copia su export privado al portapapeles sin mostrarlo. El usuario lo pega personalmente en el Actions Secret `AIRPLAY_SPARKLE_PRIVATE_KEY` de este repositorio y vuelve a Terminal para presionar Enter: se eliminan la copia temporal y el contenido del portapapeles si sigue siendo esa clave. El original permanece en el Llavero. Nunca pegar la privada en el chat, el repositorio o un artefacto. El comando sólo prepara la firma y no instala ni modifica AirPlay. Los helpers de CI no generan ni rotan claves; [su documentación](ci/airplay/README.md) describe la importación temporal y la firma oficial por stdin.

3. **Obtener la configuración pública.** Los workflows `airplay-public-key.yml` y `airplay-build.yml` están activados en este repositorio público revisado y la variable `AIRPLAY_PUBLIC_CI_ENABLED` está en `true`. Ejecutar manualmente el workflow de configuración pública. Su artefacto contiene únicamente `UpdateConfig.plist`, derivado de la clave existente. Guardar el XML completo como variable pública `AIRPLAY_UPDATE_CONFIG_PLIST`; no es un secreto.

4. **Ejecutar manualmente la preparación firmada.** Comprueba que la clave coincide antes de compilar, ejecuta las verificaciones del bundle y de AppKit, y firma y verifica el ZIP y el appcast con Sparkle 2.9.6. El artefacto contiene `release/` con los archivos finales y sus informes. El workflow no crea Releases, no cambia el feed ni instala AirPlay.

5. **Publicar los archivos finales:** primero `release/AirPlay-1.3.2-6.zip` en la release de tag `airplay-v1.3.2-b6`, junto con las fuentes correspondientes; después, los bytes exactos de `release/appcast.xml` en `feeds/airplay/stable/appcast.xml`. No editar el XML firmado ni sustituir el ZIP por el paquete previo a la firma.

La dirección estable del feed es:

```text
https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml
```

Antes de entregar la instalación inicial, ejecutar `apps/airplay/source/scripts/verify-published-release.py --release-dir <carpeta-release>` para comprobar descargas anónimas e integridad. El [smoke de Sparkle](ci/airplay/update-smoke/README.md) comprueba la transición desde una aplicación de prueba A a la release B real y su reapertura. La [prueba 39174335348](https://github.com/Tangram-Space/updates/actions/runs/39174335348) pasó en macOS 15.7.9 Intel. A era una aplicación de prueba aislada y B fue el paquete real publicado. La comprobación de streaming, del diálogo estándar del actualizador y de ejecución en el iMac con Big Sur queda fuera de ese ensayo.

## Licencias

AirPlay se basa en UxPlay bajo **GPL-3.0-or-later**. Conservar la [licencia principal](apps/airplay/source/LICENSE), los [avisos de terceros](apps/airplay/source/THIRD_PARTY.md) y sus [textos completos](apps/airplay/source/licenses/) junto con las fuentes de cada versión distribuida.
