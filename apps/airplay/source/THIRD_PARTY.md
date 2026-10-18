# Componentes de terceros

Este proyecto modifica [UxPlay](https://github.com/FDH2/UxPlay) y conserva su licencia principal en [LICENSE](LICENSE). Las cabeceras de UxPlay identifican el código correspondiente como **GPL-3.0-or-later**. Los archivos de `overlay/` se aplican al commit `df67c212a433cf6dda3676dd40c097900d24e645`, identificado como UxPlay 1.73.7 en [upstream.lock.json](upstream.lock.json).

Los avisos originales permanecen en las fuentes de upstream. Este documento indica los componentes y los textos conservados; los términos completos están en los archivos enlazados.

## Código y bibliotecas de la aplicación

| Componente | Versión o procedencia | Uso en esta compilación | Licencia y avisos conservados |
| --- | --- | --- | --- |
| [UxPlay](https://github.com/FDH2/UxPlay/tree/df67c212a433cf6dda3676dd40c097900d24e645) | 1.73.7, commit fijado | Receptor de audio y duplicación de pantalla; se compila con las modificaciones de `overlay/`. | [GNU GPL, versión 3](LICENSE); las cabeceras pertinentes permiten esa versión o posterior. |
| [llhttp](https://github.com/FDH2/UxPlay/tree/df67c212a433cf6dda3676dd40c097900d24e645/lib/llhttp) | Copia incluida en el commit de UxPlay | Procesamiento HTTP integrado en upstream. | [MIT](licenses/llhttp-MIT.txt). |
| [playfair](https://github.com/FDH2/UxPlay/tree/df67c212a433cf6dda3676dd40c097900d24e645/lib/playfair) | Copia incluida en el commit de UxPlay | Código de compatibilidad del protocolo integrado en upstream. | [GNU GPL, versión 3](licenses/playfair-GPL-3.0.txt). |
| [libplist](https://github.com/libimobiledevice/libplist/tree/2.8.0) | 2.8.0 | `libplist-2.0.a`, aportada por el prefijo local de dependencias y enlazada estáticamente. | [GNU LGPL, versión 2.1](licenses/libplist-2.8.0-LGPL-2.1.txt). |
| [OpenSSL](https://github.com/openssl/openssl/tree/openssl-3.5.0) | 3.5.0 en el SDK de referencia | `libcrypto.a`, aportada por el framework de GStreamer y enlazada estáticamente. | [Apache License 2.0](licenses/OpenSSL-3.5.0-Apache-2.0.txt). |
| [Sparkle](https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6) | 2.9.6 | Framework de actualización incluido en `Contents/Frameworks` del bundle. | [Licencia MIT y avisos adicionales completos](licenses/Sparkle-2.9.6-LICENSE.txt). |

El archivo de licencia de Sparkle también conserva los avisos de `bsdiff`/`bspatch`, `sais-lite`, la implementación portable de Ed25519 y `SUSignatureVerifier.m`. Esos textos forman parte del archivo completo y no se sustituyen por la descripción breve de la tabla.

## Framework externo y herramientas de construcción

[GStreamer](https://gstreamer.freedesktop.org/) **1.28.8** es el runtime y SDK de referencia. La aplicación enlaza con el framework instalado en el Mac y utiliza sus plugins de audio y vídeo. El instalador de este proyecto no copia GStreamer dentro de `AirPlay.app`. Los avisos de GStreamer y de sus componentes y plugins se encuentran en la distribución oficial instalada; este inventario no atribuye una única licencia a todos los plugins externos.

CMake, Python 3 y las herramientas de desarrollo de Apple se utilizan para preparar y compilar la aplicación. No se incluyen como ejecutables en el bundle. Cocoa, SystemConfiguration y las bibliotecas de sistema se obtienen del SDK y de macOS.

## Procedencia y verificación

[licenses/source-lock.json](licenses/source-lock.json) registra la URL de origen y el SHA-256 de cada texto de licencia conservado; incluye el identificador del blob Git cuando está disponible. [upstream.lock.json](upstream.lock.json) y [manifests/upstream.sha256](manifests/upstream.sha256) fijan las fuentes originales que modifica este proyecto.

El archivo oficial utilizado para Sparkle es:

```text
https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
SHA-256: 52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
```

Ese valor también está en [version.env](version.env) y se verifica antes de extraer e incorporar el framework. Las fuentes de UxPlay, las modificaciones, los recursos, los scripts y los avisos se conservan por separado para poder reconstruir la aplicación e identificar qué se cambió respecto de upstream.
