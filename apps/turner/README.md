# Turner: canal estable para Mac Intel

El código fuente permanece en [Chevosky/tuner-compact](https://github.com/Chevosky/tuner-compact),
rama `compact-intel`. Este directorio registra la solicitud de versión;
los paquetes y su feed se publican en `Tangram-Space/updates`.

## Identidad y protocolo

| Dato | Valor |
| --- | --- |
| Aplicación / canal | `turner` / `stable` |
| Feed | `https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/turner/stable/release.json` |
| Tag | `turner-vVERSION-rREVISION` |
| Paquete | `Turner-vVERSION-rREVISION-macos-x86_64.app.zip` |
| Manifiesto en la release | `turner-update.json` |
| Raíz del ZIP | `Turner.app` |
| Plataforma | macOS Intel (`x86_64`), mínimo 11.0 |
| Identidad del bundle | `com.tuner.guitar.compact` (se conserva) |
| Ejecutable | `guitar-tuner-egui` (se conserva) |
| Identidad de preferencias | `Guitar Tuner` (se conserva) |

El feed contiene el manifiesto completo de la release, con su SHA-256. El
cliente valida la identidad y consulta esa release por el tag exacto.
Nunca usa `/releases/latest`, porque este repositorio contiene otras apps.
Un feed 404 significa que no hay versión publicada; un feed presente que
apunta a una release o archivo ausente produce un error visible.

## Solicitar una versión

1. Publicar las fuentes e incrementar `COMPACT_REVISION` en `egui/src/version.rs`.
2. Actualizar `release.json` con `schema_version: 1`, `app_id: "turner"`,
   `channel: "stable"`, `source_repo: "Chevosky/tuner-compact"`, un
   `source_sha` completo de 40 caracteres hexadecimales en minúsculas,
   `version` y `revision`.
3. El workflow central valida que el commit y la revisión coincidan, ejecuta
   las pruebas y compila con el runner estándar `macos-15-intel`.
4. Un publicador separado completa el ZIP, su `.sha256` y `turner-update.json`
   antes de avanzar `feeds/turner/stable/release.json` con los mismos bytes.

Las releases existentes no se sustituyen y la publicación no cambia latest
global. No se requieren PAT ni secretos nuevos. No se usan ni modifican
las claves y configuración de AirPlay. El publicador protege el avance del
feed frente a cambios concurrentes del repositorio.

## Migración desde Tuner Compact r3

La r3 consulta `Chevosky/tuner-compact`. Después de verificar la release
canónica se publica allí un puente explícito, con el mismo ejecutable y
recursos, pero los nombres y raíz del ZIP que entiende ese cliente. Su
actualizador reemplaza la app en la misma ruta; no agrega una segunda copia.
Desde r4, las consultas ya usan este canal central.

La ruta instalada puede seguir llamándose `Tuner Compact.app`; con la app
cerrada puede renombrarse a `Turner.app`. El ZIP canónico nuevo ya contiene
`Turner.app`. El icono de la app, la identidad y las preferencias se conservan.

## Alcance

El cliente comprueba HTTPS, SHA-256, identidad, arquitectura y compatibilidad.
Estas comprobaciones confían en este repositorio; no equivalen a una firma
independiente del editor ni a notarización de Apple. Las pruebas del instalador
usan utilidades simuladas: una transición completa de la app en ejecución y
las pruebas de micrófono BRIO en el iMac con Big Sur siguen siendo comprobaciones
que deben hacerse en macOS real.
