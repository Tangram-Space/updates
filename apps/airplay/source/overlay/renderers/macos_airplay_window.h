/* Cocoa window presentation for the existing GStreamer GL renderer. */
#ifndef UX_MACOS_AIRPLAY_WINDOW_H
#define UX_MACOS_AIRPLAY_WINDOW_H

#include <gst/gst.h>

#ifdef __cplusplus
extern "C" {
#endif

void ux_macos_airplay_window_attach(GstElement *sink);

/* App controller hooks; call only from the AppKit main thread. */
gboolean ux_macos_airplay_window_show(void);
void ux_macos_airplay_window_save(void);

#ifdef __cplusplus
}
#endif

#endif
