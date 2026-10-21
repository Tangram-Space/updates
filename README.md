# Tangram Updates

Repositorio público de fuentes y distribución [Tangram-Space/updates](https://github.com/Tangram-Space/updates), compartido por aplicación. AirPlay para macOS 11 o posterior en Intel tiene publicada la **1.3.3, build 7**, con su [paquete firmado y fuentes correspondientes](https://github.com/Tangram-Space/updates/releases/tag/airplay-v1.3.3-b7).

Esta versión añade la búsqueda automática opcional, inicialmente desactivada, y un aviso discreto en el menú. La [compilación nativa 39636510520](https://github.com/Tangram-Space/updates/actions/runs/39636510520) pasó, incluidas las diez variantes de idioma, las firmas y la prueba del actualizador real: persistencia de la preferencia, consulta programada sin ventana ni activación y apertura manual del aviso estándar. Las comprobaciones de disponibilidad y de instalación del paquete publicado se registran por separado en los [informes de la versión](apps/airplay/verification/1.3.3-7/). [Uso y estado de AirPlay](apps/airplay/README.md).

## Contenido

| Ruta | Función |
| --- | --- |
| [apps/airplay/source/](apps/airplay/source/) | Modificaciones de UxPlay, recursos, construcción, verificadores, manifiestos y licencias. La selección de dependencias se aísla de Homebrew para mantener coherentes las cabeceras y bibliotecas del SDK. |
| [apps/airplay/source-snapshot.json](apps/airplay/source-snapshot.json) | Identidad y comprobación del snapshot, sin importar el historial privado de desarrollo. |
| [ci/airplay/](ci/airplay/) | Dependencias fijadas, configuración pública, comprobación nativa del actualizador, firma y recolección acotada de artefactos. |
| `.github/workflows/airplay-*.yml` | Cuatro workflows **manuales** de AirPlay: configuración pública, compilación firmada, comprobación anónima y prueba real de instalación con Sparkle. No publican Releases ni modifican el feed. |
| [apps/airplay/channel.json](apps/airplay/channel.json) | Identidad de la release publicada, clave pública y estado comprobado del canal. |
| [apps/turner/](apps/turner/) | Canal de Turner y solicitud de versión con el commit exacto del repositorio público de fuentes. |
| [.github/workflows/turner-build.yml](.github/workflows/turner-build.yml) | Pruebas, compilación Intel y publicación de Turner; avanza sólo su propio feed cuando los archivos están completos. |
| [feeds/turner/stable/release.json](feeds/turner/stable/release.json) | Puntero estable de Turner, idéntico al manifiesto de su release. |

## Preparar y publicar AirPlay

### Configuración inicial del canal, ya realizada

AirPlay ya tiene una clave de firma y un canal estable. Las siguientes entradas se conservan entre versiones:

| Entrada | Uso |
| --- | --- |
| Actions Secret `AIRPLAY_SPARKLE_PRIVATE_KEY` | Clave existente con la que se firman el paquete y el feed. |
| Variable `AIRPLAY_UPDATE_CONFIG_PLIST` | Configuración pública del mismo feed y clave, derivada de ese Secret. |
| Variable `AIRPLAY_PUBLIC_CI_ENABLED=true` | Habilita los workflows revisados de AirPlay en este repositorio público. |

**Publicar una versión nueva no requiere preparar otra clave ni volver a configurar estas entradas.** [Preparar_Firma_AirPlay.command](ci/airplay/Preparar_Firma_AirPlay.command) y el workflow de configuración pública corresponden al alta inicial o a una recuperación revisada que preserve la misma identidad de firma. La clave privada no debe incluirse en el repositorio, el chat ni los artefactos. Los helpers de CI verifican la correspondencia con la configuración pública y no generan ni rotan claves; [su documentación](ci/airplay/README.md) explica el manejo temporal de la firma.

### Mantenimiento de cada versión

1. **Publicar las fuentes revisadas** en `main`, con la versión, el build creciente y los manifiestos correspondientes. La construcción toma ese commit público en un runner Intel y no modifica la app instalada en ningún Mac personal.

2. **Ejecutar el workflow de preparación firmada** (`airplay-build.yml`) con la configuración existente. Antes de compilar comprueba que el Secret coincide con la clave pública. Después verifica el bundle y AppKit, ejecuta la [comprobación nativa del actualizador](ci/airplay/updater-check/README.md), y firma y verifica el ZIP y el appcast con Sparkle 2.9.6. También valida la firma del feed anterior y que el build avance. El workflow no crea Releases ni cambia el feed.

3. **Revisar los informes y reunir las fuentes correspondientes.** El artefacto aprobado contiene `release/` con el ZIP final, `appcast.xml` y `release.json`. Conservar la identidad del commit, hashes, tamaños y resultados, y preparar las fuentes y licencias que corresponden exactamente a ese paquete.

4. **Publicar los archivos finales.** Usar el tag `airplay-v<VERSION>-b<BUILD>`: primero el ZIP firmado y las fuentes correspondientes; después, los bytes exactos de `release/appcast.xml` en `feeds/airplay/stable/appcast.xml`. No editar el XML firmado ni sustituir el ZIP por el paquete previo a la firma.

5. **Comprobar el canal publicado y conservar la evidencia.** Ejecutar los workflows de disponibilidad anónima y de instalación real con Sparkle contra ese paquete, feed y clave. Registrar los informes por versión y actualizar [channel.json](apps/airplay/channel.json) y la documentación con los resultados reales antes de dar la entrega por comprobada.

La dirección estable del feed es:

```text
https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml
```

El verificador `apps/airplay/source/scripts/verify-published-release.py --release-dir <carpeta-release>` comprueba descargas anónimas e integridad. El [smoke de Sparkle](ci/airplay/update-smoke/README.md) comprueba la transición desde una aplicación de prueba A a la release B real y su reapertura. La [prueba 39174335348 de 1.3.2](https://github.com/Tangram-Space/updates/actions/runs/39174335348) pasó en macOS 15.7.9 Intel; no acredita por sí sola una versión posterior. La nueva comprobación del actualizador cubre por separado la persistencia del consentimiento, el aviso silencioso y la apertura manual de la interfaz estándar. Ninguno de esos ensayos sustituye la reproducción ni la ejecución en el iMac con Big Sur.

## Preparar y publicar Turner

Turner es el afinador antes llamado Tuner Compact. Sus fuentes permanecen en
[Chevosky/tuner-compact](https://github.com/Chevosky/tuner-compact), rama
`compact-intel`. Comparte este repositorio de distribución con AirPlay y usa
su propio canal:

```text
https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/turner/stable/release.json
```

Para preparar una versión, publicar primero el código y aumentar su revisión.
Después actualizar [apps/turner/release.json](apps/turner/release.json) con el
SHA completo del commit público, su versión y revisión. El workflow de Turner
valida la solicitud, prueba y compila ese commit en un runner macOS Intel
estándar, con permisos de sólo lectura durante la construcción. Un job
separado publica el ZIP, su SHA-256 y `turner-update.json` en un tag
`turner-vVERSION-rREVISION`. Sólo después de verificar los archivos completos
publica los mismos bytes del manifiesto en el feed. Las releases existentes
no se sobrescriben y las de Turner no cambian la selección global de latest.

El cliente consulta el feed de Turner y la release indicada por su tag exacto;
rechaza otros identificadores de aplicación, canales y paquetes. El código
de construcción y su plantilla de workflow están en el commit de fuentes
fijado por la solicitud. [Detalles del canal y de la migración desde r3](apps/turner/README.md).

Turner conserva un actualizador propio con comprobaciones de identidad,
integridad y compatibilidad. No usa las claves ni la configuración de Sparkle
de AirPlay. Su comprobación HTTPS/SHA-256 confía en este repositorio; no es una
firma independiente del editor ni notarización de Apple.

## Licencias

AirPlay se basa en UxPlay bajo **GPL-3.0-or-later**. Conservar la [licencia principal](apps/airplay/source/LICENSE), los [avisos de terceros](apps/airplay/source/THIRD_PARTY.md) y sus [textos completos](apps/airplay/source/licenses/) junto con las fuentes de cada versión distribuida.

Turner se basa en [themoretheless/tuner](https://github.com/themoretheless/tuner)
bajo **MIT** y conserva CPAL bajo **Apache-2.0**. Ambos textos se incluyen en
el bundle distribuido; las fuentes y el backport acotado de CPAL permanecen
en su repositorio público y commit de versión.
