# AirPlay

Receptor de audio y duplicación de pantalla para **macOS 11 o posterior, Intel x86_64**, basado en UxPlay 1.73.7. La versión de fuentes preparada aquí es **1.3.2, build 6**.

## Fuentes y procedencia

- [source/](source/): los 69 archivos del proyecto de construcción, copiados sin modificaciones y sin historial Git.
- [source-snapshot.json](source-snapshot.json): identificación de la versión, commit de UxPlay y SHA-256 del manifiesto del snapshot.
- [Instrucciones del proyecto](source/README.md): requisitos, construcción, controles nativos e instalación de mantenimiento.
- [Preparación y firma de actualizaciones](source/docs/UPDATES.md): configuración pública del canal y herramientas de firma.

Las referencias del README interno al repositorio de desarrollo y a los prototipos conservan el contexto del proyecto. El snapshot público se encuentra en esta carpeta. Las dependencias y herramientas se obtienen desde las versiones y orígenes fijados por los scripts; no se incluyen sus ejecutables en Git.

## Canal de actualizaciones

[channel.json](channel.json) registra un canal **pendiente de publicación y prueba**. `feeds/airplay/stable/appcast.xml` es la ruta prevista para el feed real; ese archivo se incorpora únicamente cuando se haya generado y verificado su firma. La URL del feed, la clave pública y los datos de la primera release todavía no están configurados en esta descripción.

Después de preparar y publicar una release firmada, se comprueba su disponibilidad desde la carpeta de fuentes:

```bash
xcrun python3 scripts/verify-published-release.py --release-dir "$RELEASE_DIR"
```

Ese control compara las descargas anónimas con los archivos firmados locales. Informa por separado que no realizó una actualización dentro de macOS y no sustituye la validación EdDSA de Sparkle. La candidata no se presenta como una actualización terminada hasta completar también la prueba desde la app.

## Licencias

Se conservan [LICENSE](source/LICENSE), [THIRD_PARTY.md](source/THIRD_PARTY.md) y todos los archivos de [licenses/](source/licenses/), además de los avisos originales en las fuentes. El identificador `local.chevy.airplay` se mantiene para preservar la identidad y las preferencias de las instalaciones existentes.
