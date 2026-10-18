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

/* Reads the bundled public configuration and publishes a state; no network. */
void airplay_app_updater_initialize(void);
/* The only entry point that starts Sparkle or initiates an update check. */
void airplay_app_check_for_updates(void);
/* Main thread only. Also false before initialize and for an unconfigured feed. */
bool airplay_app_updater_can_check(void);

#ifdef __cplusplus
}
#endif
#endif
