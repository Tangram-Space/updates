#!/bin/bash
# One-time local provisioning. The signing key is never printed or uploaded.
# Sparkle 2.9.6: official generate_keys reuses this account if it exists.
set +x
set -euo pipefail
umask 077
export LC_ALL=C

AP_ACCOUNT='local.chevy.airplay'
AP_SECRET_NAME='AIRPLAY_SPARKLE_PRIVATE_KEY'
AP_SPARKLE_URL='https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz'
AP_SPARKLE_SHA='52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192'
AP_TEMP=''
AP_PRIVATE_FILE=''
AP_COPIED=0

ap_cleanup() {
    local ap_code=$?
    local ap_cleanup_failed=0
    trap - EXIT HUP INT TERM
    set +e
    # Leave any newer clipboard content alone. No private bytes reach stdout.
    if [ "$AP_COPIED" -eq 1 ] && [ -f "$AP_PRIVATE_FILE" ]; then
        if /usr/bin/pbpaste 2>/dev/null | /usr/bin/cmp -s "$AP_PRIVATE_FILE" - 2>/dev/null; then
            if ! /usr/bin/pbcopy </dev/null >/dev/null 2>&1; then
                printf '\nNo se pudo vaciar el portapapeles. Copiá un texto cualquiera para reemplazarlo.\n' >&2
                ap_cleanup_failed=1
            fi
        fi
    fi
    if [ -n "$AP_TEMP" ] && [ -d "$AP_TEMP" ]; then
        if ! /bin/rm -rf -- "$AP_TEMP" >/dev/null 2>&1; then
            printf '\nNo se pudo eliminar por completo la carpeta temporal protegida.\n' >&2
            ap_cleanup_failed=1
        fi
    fi
    if [ "$ap_code" -eq 0 ] && [ "$ap_cleanup_failed" -ne 0 ]; then ap_code=1; fi
    return "$ap_code"
}
trap ap_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

ap_fail() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

[ "$(/usr/bin/uname -s)" = Darwin ] || ap_fail 'Este comando se ejecuta en el Mac, no en otro sistema.'
[ "$(/usr/bin/uname -m)" = x86_64 ] || ap_fail 'Esta preparación corresponde al Mac Intel.'
[ "$(/usr/bin/id -u)" -ne 0 ] || ap_fail 'Abrilo con tu usuario habitual, sin sudo.'
AP_OS="$(/usr/bin/sw_vers -productVersion)"
AP_MAJOR="${AP_OS%%.*}"
case "$AP_MAJOR" in ''|*[!0-9]*) ap_fail 'No se pudo comprobar la versión de macOS.';; esac
[ "$AP_MAJOR" -ge 11 ] || ap_fail 'Se necesita macOS Big Sur 11 o posterior.'
[ -t 0 ] || ap_fail 'Abrí este archivo .command en Terminal para completar el paso personal en GitHub.'

printf '\nPreparar la firma de AirPlay\n\n'
printf 'La clave se conserva en el Llavero de tu usuario. Si ya existe, se reutiliza.\n'
printf 'macOS puede pedir permiso para acceder al Llavero.\n\n'
printf 'Descargando y comprobando las herramientas oficiales de Sparkle 2.9.6...\n'
AP_TEMP="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/AirPlay-firma.XXXXXXXX")"
/bin/chmod 700 "$AP_TEMP"
AP_ARCHIVE="$AP_TEMP/Sparkle-2.9.6.tar.xz"
if ! /usr/bin/curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    --connect-timeout 20 --max-time 180 --retry 3 --retry-delay 2 \
    --output "$AP_ARCHIVE" "$AP_SPARKLE_URL"; then
    ap_fail 'No se pudo descargar Sparkle. La clave no se copió al portapapeles.'
fi
AP_HASH="$(/usr/bin/shasum -a 256 "$AP_ARCHIVE" | /usr/bin/awk '{print $1}')"
[ "$AP_HASH" = "$AP_SPARKLE_SHA" ] || ap_fail 'La descarga no coincide con el SHA256 oficial fijado.'
/bin/mkdir "$AP_TEMP/tools"
/usr/bin/tar -xf "$AP_ARCHIVE" -C "$AP_TEMP/tools" >/dev/null 2>&1 || ap_fail 'No se pudo abrir el archivo verificado.'
AP_KEYS="$AP_TEMP/tools/bin/generate_keys"
[ -x "$AP_KEYS" ] && [ ! -L "$AP_KEYS" ] || ap_fail 'Falta la herramienta oficial de firma.'
AP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$AP_TEMP/tools/Sparkle.framework/Resources/Info.plist" 2>/dev/null)"
[ "$AP_VERSION" = 2.9.6 ] || ap_fail 'La versión de Sparkle no coincide.'
/usr/bin/codesign --verify --strict "$AP_KEYS" >/dev/null 2>&1 || ap_fail 'La firma de generate_keys no es válida.'
/usr/bin/codesign --verify --deep --strict "$AP_TEMP/tools/Sparkle.framework" >/dev/null 2>&1 || ap_fail 'La firma del framework no es válida.'

# Capture neither the tool's diagnostic streams nor its private data in logs.
"$AP_KEYS" --account "$AP_ACCOUNT" >/dev/null 2>&1 || ap_fail 'Sparkle no pudo crear o acceder a la clave del Llavero. No se reemplazó ninguna clave existente.'
AP_PUBLIC_KEY="$("$AP_KEYS" --account "$AP_ACCOUNT" -p 2>/dev/null)" || ap_fail 'No se pudo leer la clave pública.'
[[ "$AP_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || ap_fail 'La clave pública no tiene el formato esperado.'

AP_PRIVATE_FILE="$AP_TEMP/sparkle-export.txt"
"$AP_KEYS" --account "$AP_ACCOUNT" -x "$AP_PRIVATE_FILE" >/dev/null 2>&1 || ap_fail 'No se pudo exportar temporalmente la clave para GitHub.'
[ -f "$AP_PRIVATE_FILE" ] && [ ! -L "$AP_PRIVATE_FILE" ] || ap_fail 'El export temporal no es un archivo regular.'
/bin/chmod 600 "$AP_PRIVATE_FILE"
[ "$(/usr/bin/stat -f '%Lp' "$AP_PRIVATE_FILE")" = 600 ] || ap_fail 'No se pudieron proteger los permisos del export temporal.'
AP_EXPORT_BYTES="$(/usr/bin/wc -c < "$AP_PRIVATE_FILE")"
case "$AP_EXPORT_BYTES" in *[!0-9[:space:]]*) ap_fail 'El export tiene un tamaño inválido.';; esac
{ [ "$AP_EXPORT_BYTES" -eq 44 ] || [ "$AP_EXPORT_BYTES" -eq 128 ]; } || ap_fail 'El export no tiene el tamaño de una clave Sparkle compatible.'
/usr/bin/grep -Eq '^[A-Za-z0-9+/]+={0,2}$' "$AP_PRIVATE_FILE" 2>/dev/null || ap_fail 'El export tiene un formato inválido.'
AP_DECODED_BYTES="$(/usr/bin/base64 -D < "$AP_PRIVATE_FILE" 2>/dev/null | /usr/bin/wc -c)" || ap_fail 'El export no es Base64 válido.'
{ [ "$AP_DECODED_BYTES" -eq 32 ] || [ "$AP_DECODED_BYTES" -eq 96 ]; } || ap_fail 'El export no contiene una clave Sparkle compatible.'
if ! /usr/bin/base64 -D < "$AP_PRIVATE_FILE" 2>/dev/null | /usr/bin/base64 | /usr/bin/tr -d '\n' | /usr/bin/cmp -s "$AP_PRIVATE_FILE" - 2>/dev/null; then
    ap_fail 'El export no está en el formato canónico de Sparkle.'
fi

AP_COPIED=1
/usr/bin/pbcopy < "$AP_PRIVATE_FILE" >/dev/null 2>&1 || ap_fail 'No se pudo copiar la clave al portapapeles.'
if ! /usr/bin/pbpaste 2>/dev/null | /usr/bin/cmp -s "$AP_PRIVATE_FILE" - 2>/dev/null; then
    ap_fail 'No se pudo comprobar el contenido copiado al portapapeles.'
fi

printf '\nLa clave PRIVADA está en el portapapeles; no se muestra en Terminal.\n'
printf 'No la pegues en el chat ni la incluyas en una captura.\n\n'
printf '1. Abrí GitHub: https://github.com/Tangram-Space/updates/settings/secrets/actions\n'
printf '2. Elegí New repository secret. En Name, escribí a mano: %s\n' "$AP_SECRET_NAME"
printf '3. En Secret, pegá con Cmd+V y pulsá Add secret.\n'
printf '4. Volvé a esta Terminal y presioná Enter. No copies otro texto entre los pasos 2 y 3.\n\n'
printf 'Clave PÚBLICA (se puede compartir; no es el secreto):\n%s\n\n' "$AP_PUBLIC_KEY"
printf 'Después de guardar el secreto en GitHub, presioná Enter aquí para limpiar la copia temporal: '
IFS= read -r -s AP_FINISHED || exit 1
AP_FINISHED=''
if ! ap_cleanup; then exit 1; fi
AP_TEMP=''
AP_PRIVATE_FILE=''
AP_COPIED=0
printf '\nLa copia temporal se eliminó. La clave original permanece en tu Llavero.\n'
