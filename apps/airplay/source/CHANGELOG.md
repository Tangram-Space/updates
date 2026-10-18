# Historial de cambios

Las versiones 1.0–1.2 corresponden a prototipos locales. Sus manifiestos están en [manifests/baselines/](manifests/baselines/); no se han reconstruido fechas de publicación ni commits históricos del proyecto a partir de ellos.

## 1.3.2 — build 6 — en preparación, sin release

- Reduce el panel de volumen a 280 × 80 puntos. Dibuja una pista de cápsula de 22 puntos con relleno blanco, conservando el seguimiento, teclado y accesibilidad de NSSlider.
- Reemplaza el botón grande de silencio por un pequeño parlante en la cabecera, junto al porcentaje. Conserva las acciones y la persistencia del volumen y del silencio.
- Añade un modo de compilación sin instalación que exige una configuración de actualizaciones válida y conserva el bundle, ZIP e informes en una carpeta aislada. No reemplaza ni cierra la app instalada.
- Prepara la comprobación de disponibilidad e integridad de una publicación comparando sus descargas con los archivos locales ya firmados.
- Añade una plantilla inactiva para preparar el bundle en un runner Intel de macOS. No habilita Actions ni publica archivos.

La entrega está condicionada a configurar el canal, publicar una actualización firmada y comprobar una transición entre builds en el iMac. El repositorio continúa privado; la propuesta de distribución se describe en [docs/RELEASE_PLAN.md](docs/RELEASE_PLAN.md). Esta entrada no declara una compilación macOS ni una actualización probada.

## 1.3.1 — build 5 — candidata local

- Corrección de empaquetado: incluye un icono vectorial original de aplicación, generado y validado en el Mac antes de firmar. Una instalación normal ya no puede terminar sin `CFBundleIconFile` y `AirPlay.icns`.
- Coloca Buscar actualizaciones en la misma fila que la versión, alineado a la derecha. El estado del canal permanece debajo.
- Después de confirmar la instalación, traslada la distribución identificada de CMake y las copias propias del prototipo a carpetas internas de soporte. Conserva cualquier app sin identificar e informa los resultados de la organización.
- Reconoce CMake conservado fuera de Aplicaciones y reutiliza las dependencias estáticas del prototipo. Los nuevos respaldos quedan en una carpeta oculta junto al destino.
- Registra la app instalada y solicita un único refresco del Dock del usuario identificado. No reinicia la base de Launchpad.

La preparación y revisión de esta corrección se realizaron fuera de macOS. La compilación, los controles nativos y la comprobación visual de 1.3.1 deben ejecutarse en el Mac de destino.

## 1.3 — build 4 — instalada localmente

- Corrige el uso de `setBezeled:` sobre un `NSButton` durante la construcción de Preferencias y utiliza `setBordered:`. La ventana y el popover incompletos se descartan si su construcción produce una excepción.
- Reorganiza Preferencias con el nombre del receptor, Abrir al iniciar sesión, Mostrar registros, versión y estado de las actualizaciones. Las acciones de inicio de sesión y registros pasan del menú a esa ventana.
- Incorpora Sparkle 2.9.6 para consultar e instalar actualizaciones mediante su interfaz estándar. El canal es opcional y se configura mediante el archivo local `updates/UpdateConfig.plist`; una instalación sin canal muestra ese estado explícitamente.
- Añade `--airplay-ui-check`: construye los formularios fuera de pantalla en las diez localizaciones y comprueba sus controles y geometría antes de permitir que el instalador reemplace la app.
- Convierte los avisos de selectores Objective-C no declarados en errores de compilación para el controller y el actualizador.
- Organiza el proyecto con un commit de upstream fijado, fuentes superpuestas verificables, scripts de construcción e instalación, recursos y licencias completas.
- Conserva la recepción, el volumen local, los gestos del acceso de la barra, la ventana GL y las preferencias de geometría de 1.2.

El usuario confirmó la instalación en `/Applications/AirPlay.app` y mostró Preferencias completas en el Mac de destino. La instalación original quedó sin icono de aplicación y con herramientas del prototipo visibles en Launchpad; ambas correcciones se preparan en 1.3.1. No se publicó una release ni se configuró el canal de actualizaciones.

## 1.2 — build 3

- Añade un control de volumen propio de AirPlay al hacer clic izquierdo en la barra de menús cuando hay una fuente activa; el clic derecho y Control-clic abren el menú.
- Incorpora porcentaje, silencio y persistencia del volumen local, independientes del volumen de macOS. El popover se cierra cuando se desconecta la fuente.
- Mantiene la actividad de una fuente durante pausas, vaciados de audio y silencio; el control local se conserva cuando se reconstruyen las canalizaciones de reproducción.
- Añade diez localizaciones de inglés y español, seleccionadas según los idiomas preferidos de macOS.
- Reorganiza el formulario de Preferencias. Se detectó posteriormente una ventana vacía al abrirlo; la corrección de construcción se incluye en 1.3.
- Amplía `--airplay-check` para comprobar los recursos de idioma y los elementos necesarios del control de volumen.

Procedencia: [manifests/baselines/1.2.json](manifests/baselines/1.2.json).

## 1.1 — build 2

- Traslada el acceso de la app a la barra de menús mediante un símbolo del sistema y elimina su presencia en el Dock.
- Mantiene la política de activación de aplicación accesoria cuando GStreamer crea o vuelve a crear una ventana de vídeo.
- Abre Preferencias sólo a petición del usuario y conserva una ventana compacta con el nombre editable del receptor.
- Mantiene el funcionamiento de la ventana GL, la geometría guardada, el inicio de sesión y la salida ordenada del receptor.

Procedencia: [manifests/baselines/1.1.json](manifests/baselines/1.1.json).

## 1.0 — build 1

- Empaqueta el receptor como una app nativa de macOS, con un único proceso y sin Terminal durante el uso normal.
- Añade Preferencias para el nombre anunciado, acceso a registros e inicio opcional al iniciar sesión.
- Integra la ventana GL con título «AirPlay», ajuste al girar la fuente y persistencia de tamaño y posición por orientación.
- Conserva la variante de audio y RTP utilizada por el receptor, sobre UxPlay 1.73.7 en el commit fijado.
- Añade instalación con identidad propia, respaldo de la versión anterior y cierre ordenado de la app.

Procedencia: [manifests/baselines/1.0.json](manifests/baselines/1.0.json).
