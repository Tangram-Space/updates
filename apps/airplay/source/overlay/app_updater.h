#ifndef AIRPLAY_APP_UPDATER_H
#define AIRPLAY_APP_UPDATER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum AirPlayUpdateState {
    AIRPLAY_UPDATE_NOT_CONFIGURED,
    AIRPLAY_UPDATE_IDLE,
    AIRPLAY_UPDATE_CHECKING,
    AIRPLAY_UPDATE_AVAILABLE,
    AIRPLAY_UPDATE_UP_TO_DATE,
    AIRPLAY_UPDATE_ERROR,
    AIRPLAY_UPDATE_UNSUPPORTED
} AirPlayUpdateState;

/* Reads public configuration. Starts scheduled checks only after saved opt-in. */
void airplay_app_updater_initialize(void);
/* Explicit user action: checks now or brings an existing update into focus. */
void airplay_app_check_for_updates(void);
/* Main thread only. Also false before initialize and for an unconfigured feed. */
bool airplay_app_updater_can_check(void);
/* Main thread only. Preference reads do not initialize Sparkle or use the network. */
bool airplay_app_updater_configured(void);
bool airplay_app_automatic_updates_enabled(void);
/* Persists opt-in and updates Sparkle's scheduler. False if setup fails. */
bool airplay_app_set_automatic_updates_enabled(bool enabled);

#ifdef __cplusplus
}
#endif
#endif
