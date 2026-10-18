#!/bin/bash
# Run only after a verified AirPlay installation has been committed.
# Cleanup failures are reported separately; this hook never replaces the app.
set -uo pipefail
umask 077

if [ "$#" -ne 3 ]; then
  printf 'Usage: postinstall-cleanup.sh INSTALLED_APP NEW_STATE_DIRECTORY LOG_DIRECTORY\n' >&2
  exit 64
fi
AP_POST_APP="$1"
AP_POST_STATE="$2"
AP_POST_LOG_DIR="$3"
AP_POST_HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
AP_POST_RESULT=0
AP_POST_CLEANUP_CODE=0
AP_POST_REGISTER_CODE=0

ap_post_ours() {
  local AP_POST_MARKER AP_POST_SCHEMA
  case "$AP_POST_APP" in /Applications/AirPlay.app|"$HOME/Applications/AirPlay.app") ;; *) return 1 ;; esac
  [ -d "$AP_POST_APP" ] && [ ! -L "$AP_POST_APP" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$AP_POST_APP/Contents/Info.plist" 2>/dev/null)" = local.chevy.airplay ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$AP_POST_APP/Contents/Info.plist" 2>/dev/null)" = uxplay ] || return 1
  AP_POST_MARKER=""; AP_POST_SCHEMA=""
  { IFS= read -r AP_POST_MARKER && IFS= read -r AP_POST_SCHEMA; } < "$AP_POST_APP/Contents/Resources/installation.txt" 2>/dev/null || return 1
  [ "$AP_POST_MARKER" = local.chevy.airplay ] && [ "$AP_POST_SCHEMA" = 1 ]
}

ap_post_refresh_registration() {
  local AP_REGISTER AP_DOCK_PIDS AP_DOCK_PID AP_DOCK_UID AP_DOCK_EXECUTABLE AP_OWN_UID AP_MATCH_COUNT AP_DOCK_CANDIDATE
  ap_post_ours || return 1
  AP_REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  [ -x "$AP_REGISTER" ] || return 1
  /usr/bin/touch "$AP_POST_APP/Contents/Info.plist" "$AP_POST_APP" || return 1
  "$AP_REGISTER" -f "$AP_POST_APP" || return 1
  AP_OWN_UID="$(/usr/bin/id -u)" || return 1
  AP_DOCK_PIDS="$(/usr/bin/pgrep -u "$AP_OWN_UID" -x Dock 2>/dev/null)" || AP_DOCK_PIDS=""
  AP_MATCH_COUNT=0
  AP_DOCK_PID=""
  for AP_DOCK_CANDIDATE in $AP_DOCK_PIDS; do
    case "$AP_DOCK_CANDIDATE" in ''|*[!0-9]*) continue ;; esac
    AP_DOCK_UID="$(/bin/ps -p "$AP_DOCK_CANDIDATE" -o uid= 2>/dev/null | /usr/bin/tr -d ' ')"
    AP_DOCK_EXECUTABLE="$(/bin/ps -ww -p "$AP_DOCK_CANDIDATE" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ "$AP_DOCK_UID" = "$AP_OWN_UID" ] && [ "$AP_DOCK_EXECUTABLE" = /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock ]; then
      AP_MATCH_COUNT=$((AP_MATCH_COUNT + 1))
      AP_DOCK_PID="$AP_DOCK_CANDIDATE"
    fi
  done
  if [ "$AP_MATCH_COUNT" -ne 1 ]; then
    printf 'AirPlay se registro; queda pendiente el refresco porque no se identifico una unica instancia propia de Dock.\n'
    return 1
  fi
  # Revalidate immediately before the only refresh request. No database reset.
  AP_DOCK_UID="$(/bin/ps -p "$AP_DOCK_PID" -o uid= 2>/dev/null | /usr/bin/tr -d ' ')"
  AP_DOCK_EXECUTABLE="$(/bin/ps -ww -p "$AP_DOCK_PID" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ "$AP_DOCK_UID" = "$AP_OWN_UID" ] && [ "$AP_DOCK_EXECUTABLE" = /System/Library/CoreServices/Dock.app/Contents/MacOS/Dock ] || return 1
  printf 'Actualizando Launchpad: Dock PID=%s UID=%s ruta=%s\n' "$AP_DOCK_PID" "$AP_DOCK_UID" "$AP_DOCK_EXECUTABLE"
  /bin/kill -TERM "$AP_DOCK_PID" || return 1
}

[ -d "$AP_POST_LOG_DIR" ] || { printf 'No se encontro la carpeta de registros.\n' >&2; exit 1; }
ap_post_ours || { printf 'La identidad de la app instalada cambio; no se aplico mantenimiento.\n' >&2; exit 1; }
if [ -e "$AP_POST_STATE" ] || [ -L "$AP_POST_STATE" ]; then
  printf 'El estado de limpieza ya existe; se conserva y no se repite el traslado.\n'
  AP_POST_CLEANUP_CODE=1
else
  /bin/bash "$AP_POST_HELPERS/cleanup-tools.sh" --state-dir "$AP_POST_STATE" --apply \
    > "$AP_POST_LOG_DIR/herramientas.log" 2>&1 || AP_POST_CLEANUP_CODE=$?
fi
if [ "$AP_POST_CLEANUP_CODE" -ne 0 ]; then
  printf 'AirPlay quedo instalada. La limpieza termino con codigo %s; sus detalles estan en el ZIP.\n' "$AP_POST_CLEANUP_CODE"
  AP_POST_RESULT=2
fi

if [ -f "$AP_POST_STATE/plan.json" ]; then
  /bin/cp "$AP_POST_STATE/plan.json" "$AP_POST_LOG_DIR/herramientas-resultado.json" || AP_POST_RESULT=2
  AP_POST_PYTHON="$(/usr/bin/xcrun --find python3 2>/dev/null)" || AP_POST_PYTHON=""
  if [ -x "$AP_POST_PYTHON" ]; then
    "$AP_POST_PYTHON" - "$AP_POST_STATE/plan.json" <<'AIRPLAY_POSTINSTALL_SUMMARY' || AP_POST_RESULT=2
import json, sys
with open(sys.argv[1], encoding='utf-8') as stream:
    plan = json.load(stream)
actions = plan.get('actions', [])
kept = plan.get('kept', [])
completed = sum(item.get('status') == 'completed' for item in actions)
pending = [item for item in actions if item.get('status') != 'completed']
print('Herramientas y pruebas identificadas trasladadas: {}.'.format(completed))
for item in kept:
    print('Se conserva sin modificar: {}. {}'.format(item.get('path', '(sin ruta)'),
        item.get('reason', 'No coincide con una herramienta o prueba identificada.')))
for item in pending:
    print('Traslado pendiente: {}. {}'.format(item.get('path', '(sin ruta)'),
        item.get('error', item.get('status', 'sin estado'))))
if kept or pending:
    print('Los elementos conservados estan detallados en herramientas-resultado.json.')
if not actions and not kept:
    print('No quedan aplicaciones del prototipo identificadas para trasladar.')
sys.exit(2 if kept or pending else 0)
AIRPLAY_POSTINSTALL_SUMMARY
  else
    printf 'No se pudo resumir el resultado; el plan completo queda en el ZIP.\n'
    AP_POST_RESULT=2
  fi
else
  printf 'No se obtuvo un plan de limpieza; la app instalada se conserva.\n'
  AP_POST_RESULT=2
fi
if [ -f "$AP_POST_STATE/lsregister-help.txt" ]; then
  /bin/cp "$AP_POST_STATE/lsregister-help.txt" "$AP_POST_LOG_DIR/registro-ayuda.txt" || AP_POST_RESULT=2
fi

# This call is made once, even if a tool was kept or its move failed.
ap_post_refresh_registration > "$AP_POST_LOG_DIR/registro-launchpad.log" 2>&1 || AP_POST_REGISTER_CODE=$?
if [ "$AP_POST_REGISTER_CODE" -ne 0 ]; then
  printf 'La app esta instalada; queda pendiente revisar el refresco de sus accesos.\n'
  AP_POST_RESULT=2
else
  printf 'Se registro AirPlay con su icono y se solicito el refresco de Launchpad.\n'
fi
printf 'cleanup_exit=%s\nregistration_exit=%s\nstate=%s\n' \
  "$AP_POST_CLEANUP_CODE" "$AP_POST_REGISTER_CODE" "$AP_POST_STATE" \
  > "$AP_POST_LOG_DIR/mantenimiento-estado.txt" || AP_POST_RESULT=2
exit "$AP_POST_RESULT"
