# Sparkle: prueba de actualización real A → B

Esta carpeta agrega una prueba manual aislada al repositorio público. No modifica
las fuentes del receptor, no publica archivos y no recibe claves privadas.
El workflow manual `.github/workflows/airplay-update-smoke.yml` requiere el
helper de dependencias `ci/airplay/prepare-macos-dependencies.sh` ya existente
y `AIRPLAY_PUBLIC_CI_ENABLED=true`. El dispatch recibe la versión/build
y los SHA256 y tamaño **del B final publicado**, no los de un build anterior.

1. Descarga anónimamente el feed RAW y ZIP publicados, compara esos bytes y
   verifica ambas firmas Ed25519 con la clave pública real. No consulta Keychain.
2. Extrae B y verifica identidad, firma de código, flags de Sparkle y SDK 2.9.6.
   Ejecuta los checks nativos de B. El receptor completo no se recompila.
3. Compila una app A de prueba dentro de un directorio nuevo de `RUNNER_TEMP`.
   A conserva el bundle ID/feed/clave de B y usa un build menor, pero tiene un
   ejecutable sintético claramente identificado. Su `SPUUpdater` actualiza su
   propio `mainBundle`; el user driver de prueba acepta descargar e instalar.
4. Un observador independiente espera la terminación normal de A, compara todo
   el árbol instalado con B y exige un PID distinto en ese mismo path, el log de
   arranque de AirPlay y diez segundos vivo. El observador **no abre B**.
5. El helper `NormalQuit.m` revalida PID, nacimiento, propietario, ruta e identidad
   de AppKit de B. Registra un observador del kernel con `NOTE_EXITSTATUS` y luego
   solicita `NSRunningApplication.terminate`. Exige la salida normal con código
   cero y nuevos registros de cierre del receptor, guardado satisfactorio de
   preferencias y parada de RAOP. No envía señales ni fuerza el cierre.

El resultado se guarda en `smoke-result.json` con estados y checks separados.
Sólo puede decir `PASS` después de la instalación, relanzamiento y cierre normal
observados. `real-B-normal-quit.json` conserva el código de salida observado por
el kernel; `real-B-shutdown.log` conserva los marcadores de la app real. B no es
hija del observador, por lo que su desaparición de `ps` no se usa para inferir
un código cero. Las señales quedan reservadas a limpieza posterior a un fallo,
únicamente para procesos del path temporal con PID/nacimiento revalidados.
No se modifican `/Applications`, permisos de App Management ni bases de datos.
El B real puede crear sus registros/preferencias normales en la cuenta efímera
del runner; no se ejecuta en la cuenta ni en el equipo del usuario.

**Alcance:** verifica el motor Sparkle 2.9.6 y el B real en el Mac Intel del
runner. A usa un `SPUUserDriver` automático, por lo que no cubre el botón de
Preferencias, el `SPUStandardUserDriver` ni la salida del receptor A verdadero.
El cierre normal comprobado por este flujo corresponde al receptor **B real**.
Tampoco prueba Big Sur ni transmisión de audio/vídeo. La firma y descarga se
registran por separado de instalación/relanzamiento, sin equiparar sus resultados.

API pública de referencia: los headers Sparkle 2.9.6 distribuidos dentro del ZIP
firmado y [SPUUserDriver](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUserDriver.html).
La observación de la salida utiliza `EVFILT_PROC` y `NOTE_EXITSTATUS`, conforme a
la implementación pública de [XNU](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_event.c).
