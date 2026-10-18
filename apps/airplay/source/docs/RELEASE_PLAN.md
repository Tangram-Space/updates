# Activación del canal de AirPlay

## Objetivo y estado

La próxima instalación debe incluir un canal real. Después, **Buscar actualizaciones** debe encontrar, descargar, verificar, instalar y volver a abrir una versión superior mediante Sparkle. No alcanza con que el botón exista o que un feed responda «Al día».

La candidata 1.3.2, build 6, incorpora el nuevo control de volumen y conserva el icono y las Preferencias de 1.3.1. Todavía no está compilada ni probada en macOS. No se generó una clave de publicación ni se creó un canal o una release durante esta preparación.

`Tangram-Space/airplay` permanece **privado**, como se acordó. El código preparado se conserva en una rama de trabajo; no se activa ningún servicio ni workflow al guardarlo.

## Trabajo preparado

- `scripts/build-install.sh --build-only` construye y comprueba sin cerrar ni reemplazar AirPlay. Exige una configuración válida del canal; conserva el bundle y los informes dentro de una carpeta aislada.
- `scripts/make-release.sh` usa las herramientas oficiales de Sparkle 2.9.6 para producir y verificar el ZIP y el appcast firmados. La implementación vigente utiliza el Llavero del Mac y no exporta claves.
- `scripts/verify-published-release.py` comprueba que las descargas públicas coincidan con el ZIP y el appcast locales ya firmados. Esta verificación de integridad y disponibilidad no equivale a ejecutar una actualización en Big Sur.
- `ci/build-macos.yml.in` es una plantilla inactiva fuera de `.github/workflows`. Prepara un bundle mediante dependencias fijadas y un runner Intel, con objetivo mínimo macOS 11. No firma una release con EdDSA ni publica archivos. Exige un repositorio público y una variable de habilitación para evitar ejecuciones en el repositorio privado.

## Propuesta de repositorio general de actualizaciones

El usuario propuso compartir un repositorio de actualizaciones entre las apps. El destino propuesto pasa a ser **`Tangram-Space/updates`**, público, como lugar común de distribución. AirPlay sería la primera aplicación incorporada. La creación pública y la configuración de publicación continúan pendientes; este ajuste del diseño no publica archivos ni incorpora otros proyectos.

Cada repositorio de trabajo conserva su privacidad y su historia. El canal público recibe las versiones que se decide distribuir, con sus notas, licencias y fuentes correspondientes. Para AirPlay se incluye la fuente de la versión publicada con nuestros cambios y sus scripts de construcción; no se promete mantener privada esa fuente distribuida.

### Organización del canal común

| Elemento | Convención propuesta |
| --- | --- |
| Feed estable de AirPlay | `airplay/stable/appcast.xml` |
| Futuro canal de pruebas, si se habilita | `airplay/beta/appcast.xml` |
| Release de AirPlay | Tag `airplay-v1.3.2-b6` y siguientes, con prefijo de aplicación |
| Archivo de aplicación | Asset `AirPlay-1.3.2-6.zip` de su release exacta |
| Fuentes de la versión | Archivo separado dentro de esa misma release |
| Otras aplicaciones | Carpeta, versiones, proceso de construcción y clave propios |

La dirección estable propuesta para AirPlay es `https://raw.githubusercontent.com/Tangram-Space/updates/main/airplay/stable/appcast.xml`. El ZIP del ejemplo tendría la dirección `https://github.com/Tangram-Space/updates/releases/download/airplay-v1.3.2-b6/AirPlay-1.3.2-6.zip`. Son direcciones de diseño: todavía no se han creado ni se incluyen en una app firmada.

Cada aplicación consulta su propio feed y verifica con su propia clave pública. Los canales estable y de pruebas de una misma app conservarían la misma identidad de firma. Los números de build son independientes entre apps. Ningún cliente usa el enlace global `releases/latest` del repositorio, porque la última release podría corresponder a otra aplicación. GitHub documenta los [enlaces a releases concretas](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases); [Sparkle](https://sparkle-project.org/documentation/publishing/) permite que cada feed describa los archivos exactos de su app.

La primera fase sólo habilita AirPlay. Compartir el lugar de distribución no agrega un actualizador a otras aplicaciones: cada una necesita integrar y probar su propio cliente antes de incorporarse.

### Producción y firma por aplicación

La compilación y firma se configuran por aplicación, independientemente del directorio de descargas. Para AirPlay está preparada una plantilla Intel de GitHub Actions con dependencias fijadas y objetivo macOS 11. Esa plantilla presupone que el proyecto AirPlay está en la raíz del checkout; antes de activarla en el repositorio compartido debe adaptarse a la ubicación elegida para su fuente pública revisada. No se da acceso automático a repositorios privados.

Los runners estándar de repositorios públicos están incluidos sin cobro de minutos; un repositorio público de descargas no modifica la cuota o facturación de trabajos ejecutados en repositorios privados. El guard de la plantilla impide ejecutarla en el repositorio privado actual. La regla y sus límites se documentan en [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions). No se propone contratar un runner, agregar una forma de pago o modificar presupuestos existentes.

Para firmar automáticamente, el productor necesita la clave EdDSA exclusiva de AirPlay en **GitHub Actions Secrets**, referenciada sólo por su trabajo de firma. Cada aplicación que se añada utilizaría otra clave. Esto cambia el diseño vigente que mantiene la clave sólo en el Llavero del iMac. Debe aprovisionarse directamente desde el Mac hacia GitHub, sin copiarla al chat, al repositorio o a un artefacto de Actions. La clave pública de AirPlay se fija en sus versiones sucesivas. La automatización de esa firma sigue pendiente; la plantilla de construcción no solicita ni utiliza secretos.

La conexión de GitHub disponible permite mantener archivos y commits, pero no expone la creación de repositorios, Releases/assets ni la configuración de Secrets. Completar esas operaciones requiere usar GitHub desde el navegador con autorización del usuario o una operación local equivalente. No se intentó cambiar de herramienta sin esa autorización.

## Secuencia después de configurar el destino

1. Aprovisionar la firma y guardar el feed y la clave pública definitivos.
2. Preparar dos bundles con esa misma identidad de canal y números de build crecientes. La versión inicial incorpora la confianza del canal; la siguiente contiene el control de volumen nuevo.
3. Verificar las firmas de código, recursos, arquitectura, dependencias, controles de AppKit y firma EdDSA. La compilación en un macOS más nuevo no sustituye la ejecución en Big Sur.
4. Publicar primero el ZIP y la fuente correspondiente, después el appcast firmado sin cambiar sus bytes. Descargar ambos y contrastarlos con el resultado local firmado.
5. Instalar una sola vez el bundle inicial de confianza. Desde Preferencias, comprobar una actualización efectiva al build superior, el cierre y reapertura de AirPlay y la conservación de sus ajustes.

La entrega sólo se describe como **actualizaciones probadas** cuando se complete esa transición en el iMac. Una configuración válida, un trabajo de CI exitoso o una descarga íntegra, por separado, no cierran la prueba.
