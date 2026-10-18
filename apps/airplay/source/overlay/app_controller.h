#ifndef AIRPLAY_APP_CONTROLLER_H
#define AIRPLAY_APP_CONTROLLER_H

#include <gst/gst.h>
#include "app_updater.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Main thread, before gst_macos_main. -1 continues; >=0 is a finished exit code. */
int airplay_app_prepare(int *argc, char ***argv);
/* Worker thread hooks; all AppKit work is dispatched to main. */
void airplay_app_install(void);
void airplay_app_receiver_ready(void);
/* Worker/RAOP threads: publish source presence without invoking AppKit here. */
void airplay_app_source_active(gboolean active);
/* Updater threads: copies the borrowed version and dispatches the UI update. */
void airplay_app_update_state(AirPlayUpdateState state, const char *version);
/* Read by UxPlay's existing reset callback, so shutdown stays on its own loop. */
gboolean airplay_app_should_quit(void);

#ifdef __cplusplus
}
#endif
#endif
